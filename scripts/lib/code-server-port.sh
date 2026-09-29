#!/usr/bin/env bash
# Listener identity is the managed LaunchAgent PID or one of its descendants.
code_server_owns_listener() {
    local service_pid service_info listeners pid parent depth
    service_info="$(launchctl print "gui/$(id -u)/${CODE_SERVER_LABEL}" 2>/dev/null)" || return 1
    service_pid="$(awk '$1 == "pid" && $2 == "=" {print $3; exit}' <<< "$service_info")"
    [[ "$service_pid" =~ ^[0-9]+$ ]] || return 1
    listeners="$(lsof -nP -t -iTCP:"$CODE_SERVER_PORT" -sTCP:LISTEN 2>/dev/null)" || return 1
    [[ -n "$listeners" ]] || return 1
    for pid in $listeners; do
        depth=0
        while [[ "$pid" != "$service_pid" ]]; do
            [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 && "$depth" -lt 32 ]] || return 1
            parent="$(ps -p "$pid" -o ppid= 2>/dev/null)" || return 1
            pid="${parent//[[:space:]]/}"
            depth=$((depth + 1))
        done
    done
}

code_server_allocate_port() {
    command -v lsof >/dev/null 2>&1 || { echo 'code-server: lsof is required to verify listener ownership' >&2; return 1; }
    code_server_owns_listener && return 0
    command -v python3 >/dev/null 2>&1 || { echo 'code-server: python3 is required to allocate a free loopback port' >&2; return 1; }
    local chosen
    chosen="$(python3 - "$CODE_SERVER_CONFIG_FILE" "$CODE_SERVER_PORT" <<'PYPORT'
import errno, os, re, shutil, socket, sys, tempfile
path, requested = sys.argv[1:]
port = int(requested)
if not 1024 <= port <= 65535:
    raise SystemExit('code-server: port must be between 1024 and 65535')
for candidate in range(port, min(port + 100, 65536)):
    with socket.socket() as sock:
        try:
            sock.bind(('127.0.0.1', candidate))
        except OSError as error:
            if error.errno == errno.EADDRINUSE:
                continue
            raise
    break
else:
    raise SystemExit('code-server: no free port in the next 100 ports')
if candidate != port:
    with open(path) as source:
        original = source.read()
    updated, count = re.subn(r'^([ \t]*)bind-addr:[ \t]*127\.0\.0\.1:' + str(port) + r'[ \t]*$',
                             r'\g<1>bind-addr: 127.0.0.1:' + str(candidate), original, flags=re.M)
    if count != 1:
        raise SystemExit('code-server: expected exactly one loopback bind-addr; config unchanged')
    fd, backup = tempfile.mkstemp(prefix='config.yaml.bak-port-', dir=os.path.dirname(path))
    os.close(fd)
    shutil.copyfile(path, backup)
    fd, staging = tempfile.mkstemp(prefix='.config-port-', dir=os.path.dirname(path))
    try:
        with os.fdopen(fd, 'w') as target:
            target.write(updated)
        os.replace(staging, path)
    finally:
        if os.path.exists(staging):
            os.unlink(staging)
print(candidate)
PYPORT
)" || return 1
    if [[ "$chosen" != "$CODE_SERVER_PORT" ]]; then
        info "code-server: port $CODE_SERVER_PORT is occupied; selected $chosen and saved it in $CODE_SERVER_CONFIG_FILE"
    fi
    CODE_SERVER_PORT="$chosen"
}

# Only migrate the dedicated default HTTPS endpoint, never an unrelated route.
code_server_managed_serve_matches() {
    TS_STATUS_JSON="$1" python3 -I - "$2" <<'PYSERVE'
import json, os, sys
try:
    data = json.loads(os.environ['TS_STATUS_JSON'])
    assert isinstance(data, dict)
    assert not (set(data) - {'TCP', 'Web', 'AllowFunnel'})
    assert data.get('TCP') == {'443': {'HTTPS': True}}
    web = data.get('Web')
    assert isinstance(web, dict) and len(web) == 1
    host, config = next(iter(web.items()))
    assert host.endswith(':443')
    assert config == {'Handlers': {'/': {'Proxy': 'http://127.0.0.1:' + sys.argv[1]}}}
    assert not any(data.get('AllowFunnel', {}).values())
except (AssertionError, ValueError, TypeError, AttributeError):
    sys.exit(1)
PYSERVE
}
