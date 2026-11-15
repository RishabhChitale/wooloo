#!/bin/bash
# Integration test: wooloo's forced-command dispatcher (PeerPairing.swift) behind a REAL OpenSSH sshd.
#
# Everything is throwaway and under one temp dir: a private non-root sshd on 127.0.0.1 (random port,
# runs as the current user), its own host/client keys, a fake HOME for the dispatcher, and a throwaway
# Herdr session (`herdr --session wooloo-sshd-test`, HOME pointed at the temp dir). It never touches
# ~/.ssh, the system sshd, Remote Login, or any real Herdr session. The trap on EXIT kills the sshd,
# stops the throwaway Herdr server and deletes the temp dir.
#
# The dispatcher and the authorized_keys options come from the REAL code (wooloo/PeerPairing.swift,
# compiled with swiftc against small stubs by scripts/peer-sshd/): PeerPairing.installDispatcher and
# PeerPairing.authorizedKeyOptions. Only one test-only deviation: the key line also carries
# environment="HOME=<temp home>" (sshd_config PermitUserEnvironment yes), so the dispatcher's
# $HOME-relative state (presence files, ~/.local/bin/wooloo-sync) stays inside the temp dir.
#
# Optional inputs (the sync test is skipped with a message when WOOLOO_SYNC_BIN is not set / not executable):
#   WOOLOO_SYNC_BIN   path to a built `wooloo-sync` (cargo build -p wooloo-sync --release; CI only)
#   HERDR_BIN         herdr binary (default: `command -v herdr`); Herdr tests are skipped without it
set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
SESSION=wooloo-sshd-test
PEER=sshdtest
PASS=0; FAIL=0; SKIP=0

T=$(mktemp -d /tmp/wooloo-peer-sshd.XXXXXX) || exit 2
H=$T/home
SSHD_PID=
cleanup() {
    [ -n "$SSHD_PID" ] && kill "$SSHD_PID" 2>/dev/null
    if [ -n "${HERDR:-}" ] && [ -x "$HERDR" ]; then HOME=$H "$HERDR" --session "$SESSION" server stop >/dev/null 2>&1; fi
    sleep 0.3
    pkill -f "$T/sshd_config" 2>/dev/null
    rm -rf "$T"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

ok()   { PASS=$((PASS+1)); echo "  ok    $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }
skip() { SKIP=$((SKIP+1)); echo "  skip  $1"; }

mkdir -p "$H/.local/bin" "$H/.local/share/wooloo" "$H/.local/state" "$H/bin" "$T/ssh" || exit 2
chmod 700 "$T/ssh"

# --- herdr (throwaway session) -------------------------------------------------------------------
HERDR=
REAL_HERDR=${HERDR_BIN:-$(command -v herdr 2>/dev/null || true)}
if [ -n "$REAL_HERDR" ] && [ -x "$REAL_HERDR" ]; then
    ln -s "$REAL_HERDR" "$H/bin/herdr"     # space-free path: the forced command rejects others
    HERDR=$H/bin/herdr
    VERSION=$(HOME=$H "$HERDR" --version 2>/dev/null | grep -Eo '[0-9]+(\.[0-9]+)+' | head -1)
fi
VERSION=${VERSION:-0.0.0}

# --- real dispatcher + authorized_keys options from PeerPairing.swift -----------------------------
GEN=$T/peer-gen
if ! command -v swiftc >/dev/null 2>&1; then echo "swiftc not found; this test needs it to compile the real PeerPairing code" >&2; exit 2; fi
swiftc -o "$GEN" "$REPO/wooloo/PeerPairing.swift" "$REPO/scripts/peer-sshd/stubs.swift" \
    "$REPO/scripts/peer-sshd/main.swift" 2>"$T/swiftc.log" || { cat "$T/swiftc.log" >&2; echo "could not build peer-gen" >&2; exit 2; }
OPTIONS=$("$GEN" "$H" "${HERDR:-$H/bin/herdr}" "$VERSION" "$PEER") || { echo "peer-gen failed" >&2; exit 2; }
echo "authorized_keys options come from: PeerPairing.authorizedKeyOptions (real code path)"
echo "  $OPTIONS"

# --- keys, sshd ----------------------------------------------------------------------------------
ssh-keygen -q -t ed25519 -N '' -f "$T/ssh/host" || exit 2
ssh-keygen -q -t ed25519 -N '' -f "$T/ssh/client" || exit 2
printf 'environment="HOME=%s",%s %s\n' "$H" "$OPTIONS" "$(cut -d' ' -f1,2 "$T/ssh/client.pub")" > "$T/ssh/authorized_keys"
chmod 600 "$T/ssh/authorized_keys"

PORT=$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
cat > "$T/sshd_config" <<EOF
ListenAddress 127.0.0.1
Port $PORT
HostKey $T/ssh/host
AuthorizedKeysFile $T/ssh/authorized_keys
PidFile $T/sshd.pid
UsePAM no
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitUserEnvironment yes
AcceptEnv *
LogLevel DEBUG1
EOF
SSHD=$(command -v sshd || echo /usr/sbin/sshd)
"$SSHD" -D -e -f "$T/sshd_config" >"$T/sshd.log" 2>&1 &
SSHD_PID=$!
for _ in $(seq 1 50); do grep -q "Server listening" "$T/sshd.log" 2>/dev/null && break; sleep 0.1; done
grep -q "Server listening" "$T/sshd.log" || { cat "$T/sshd.log" >&2; echo "private sshd did not start" >&2; exit 2; }
ssh-keyscan -p "$PORT" -t ed25519 127.0.0.1 > "$T/kh" 2>/dev/null
[ -s "$T/kh" ] || { echo "ssh-keyscan failed" >&2; exit 2; }
echo "private sshd: pid $SSHD_PID on 127.0.0.1:$PORT ($("$SSHD" -V 2>&1 | head -1 | tr -d '\n'))"

SSH_BASE=(ssh -p "$PORT" -i "$T/ssh/client" -o IdentitiesOnly=yes -o UserKnownHostsFile="$T/kh"
    -o StrictHostKeyChecking=yes -o BatchMode=yes -o ConnectTimeout=10 -o LogLevel=ERROR)
rs() { "${SSH_BASE[@]}" "$@"; }             # run ssh, args as given
USER_AT=$(id -un)@127.0.0.1

# run <stdin-file|-> <expected-exit> <expected-stdout-regex|-> <label> <ssh args...>
check() {
    local label=$1 want=$2 re=$3; shift 3
    local out err rc
    out=$("$@" 2>"$T/err" </dev/null); rc=$?
    err=$(cat "$T/err")
    if [ "$rc" != "$want" ]; then bad "$label" "exit $rc, wanted $want; stdout=[$(printf %s "$out" | head -c 200)] stderr=[$(printf %s "$err" | head -c 300)]"; return; fi
    if [ "$re" != - ] && ! printf '%s' "$out" | grep -Eq "$re"; then bad "$label" "stdout [$(printf %s "$out" | head -c 200)] does not match $re"; return; fi
    ok "$label"
}
# denied: ssh refusal (255) or dispatcher refusal (64/65); never exit 0 and never running the payload
denied() {
    local label=$1; shift
    local out rc
    out=$("$@" 2>"$T/err" </dev/null); rc=$?
    case $rc in
        64|65|255) ;;
        *) bad "$label" "exit $rc (wanted 64/65/255); stdout=[$(printf %s "$out" | head -c 200)] stderr=[$(head -c 200 "$T/err")]"; return;;
    esac
    if printf '%s' "$out" | grep -Eq 'uid=|PWNED'; then bad "$label" "payload ran: $out"; return; fi
    ok "$label (exit $rc)"
}

echo "== allowed =="
check "hello" 0 '^wooloo-peer-bridge-v1 ' rs "$USER_AT" 'wooloo-peer hello'

if [ -n "$HERDR" ]; then
    HOME=$H nohup "$HERDR" --session "$SESSION" server >"$T/herdr.log" 2>&1 &
    for _ in $(seq 1 100); do
        HOME=$H "$HERDR" --session "$SESSION" status server --json 2>/dev/null | grep -q running && break; sleep 0.1
    done
    check "check <session>" 0 '^herdr-api-bridge-v1$' rs "$USER_AT" "wooloo-peer check $SESSION"
    # api: the bridge speaks JSON lines; a ping must round-trip. Framing is learned from the bridge itself.
    API_OUT=$( { printf '{"id":"1","method":"ping","params":{}}\n'; sleep 2; } | rs "$USER_AT" "wooloo-peer api $SESSION" 2>"$T/err" | head -c 2000)
    if printf '%s' "$API_OUT" | grep -q 'pong\|"result"'; then ok "api <session> JSON ping round trip"
    else bad "api <session> JSON ping round trip" "stdout=[$API_OUT] stderr=[$(head -c 300 "$T/err")]"; fi
    # The client bridge waits for the client's hello before it sends anything, so silence is expected
    # (finding: no bytes on an idle stream). The dispatcher must still exec it: no refusal, no error.
    { sleep 2; } | rs "$USER_AT" "wooloo-peer client $SESSION" >"$T/cout" 2>"$T/err"; crc=$?
    if [ $crc -ne 64 ] && [ $crc -ne 65 ] && [ $crc -ne 255 ] && ! grep -q 'wooloo-peer-bridge:' "$T/err"; then
        ok "client <session> bridge starts and is not refused (exit $crc)"
    else bad "client <session> bridge starts and is not refused" "exit $crc stderr=[$(head -c 300 "$T/err")]"; fi
    # presence must have landed in the temp HOME, not the real one
    ls "$H/.local/state/wooloo/peer-presence" >/dev/null 2>&1 && ok "presence files written under the temp HOME" || bad "presence files written under the temp HOME"
else
    skip "herdr probes: no herdr binary (set HERDR_BIN)"
fi

# Herdr probes from docs/peer-allowlist.json: exact commands, expanded from the shared table.
if [ -n "$HERDR" ]; then
    python3 -I - "$REPO/docs/peer-allowlist.json" "$H/bin/herdr" "$VERSION" "$SESSION" "$T" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1])); herdr, version, session, out = sys.argv[2:6]
pre = "printf '\n%s\n' 'herdr-remote-output-ready:1'\n"
for e in doc["entries"]:
    t = e["template"].replace("{herdr}", herdr).replace("{version}", version).replace("{session}", session)
    t = t.replace("{sessionArgs}", "--session %s " % session)
    if e["transport"] == "stdin": t = pre + t
    open("%s/probe.%s" % (out, e["name"]), "w").write(t)
PY
    for name in herdr-path-probe herdr-api-check sh-uname sh-path-probe sh-exists sh-client-status sh-server-status sh-session-list sh-candidates herdr-api-discovery herdr-cached-api; do
        f=$T/probe.$name
        [ -f "$f" ] || { skip "probe $name (not in table)"; continue; }
        if grep -q "^printf '\\\\n%s" "$f" 2>/dev/null; then :; fi
        case $name in sh-*) out=$(rs "$USER_AT" '/bin/sh -s' 2>"$T/err" <"$f"); rc=$?;;
                       *) out=$(rs "$USER_AT" "$(cat "$f")" 2>"$T/err" </dev/null); rc=$?;; esac
        if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q .; then ok "probe $name"; else bad "probe $name" "exit $rc stdout=[$(printf %s "$out" | head -c 150)] stderr=[$(head -c 200 "$T/err")]"; fi
    done
fi

# sync ping-pong (real wooloo-sync): CI only.
if [ -n "${WOOLOO_SYNC_BIN:-}" ] && [ -x "${WOOLOO_SYNC_BIN:-}" ]; then
    cp "$WOOLOO_SYNC_BIN" "$H/.local/bin/wooloo-sync"
    export WOOLOO_SYNC_STATE=$T/local-state.json WOOLOO_SYNC_UNITCAT=$T/local-unitcat.json
    printf '{}' > "$WOOLOO_SYNC_UNITCAT"
    "$WOOLOO_SYNC_BIN" edit "space:00000000-0000-4000-8000-000000000001" name "sshd-test-space" >/dev/null 2>&1
    REMOTE="ssh -p $PORT -i $T/ssh/client -o IdentitiesOnly=yes -o UserKnownHostsFile=$T/kh -o StrictHostKeyChecking=yes -o BatchMode=yes -o LogLevel=ERROR $USER_AT wooloo-peer sync"
    out=$("$WOOLOO_SYNC_BIN" sync --loopback --remote-cmd "$REMOTE" 2>&1); rc=$?
    [ $rc -eq 0 ] && ok "sync ping-pong through sshd + dispatcher" || bad "sync ping-pong through sshd + dispatcher" "exit $rc: $(printf %s "$out" | head -c 300)"
    unset WOOLOO_SYNC_STATE WOOLOO_SYNC_UNITCAT
else
    skip "sync ping-pong: WOOLOO_SYNC_BIN not set (no cargo locally; runs in CI)"
fi

echo "== denied =="
denied "arbitrary shell command (id)" rs "$USER_AT" 'id'
denied "arbitrary shell command (echo PWNED)" rs "$USER_AT" 'echo PWNED'
denied "interactive shell (no command, no pty)" rs "$USER_AT"
denied "pty requested (-tt) with allowed command shape" rs -tt "$USER_AT" 'wooloo-peer hello; id'
denied "port forward (-N -L)" rs -N -L 0:127.0.0.1:1 "$USER_AT"
denied "dynamic forward (-N -D)" rs -N -D 0 "$USER_AT"
denied "sftp subsystem" rs -s "$USER_AT" sftp
denied "scp upload" scp -P "$PORT" -i "$T/ssh/client" -o IdentitiesOnly=yes -o UserKnownHostsFile="$T/kh" -o StrictHostKeyChecking=yes -o BatchMode=yes "$0" "$USER_AT:$T/uploaded"
[ -e "$T/uploaded" ] && bad "scp wrote a file" || ok "scp wrote nothing"
denied "env injection (SendEnv)" env WOOLOO_X=1 "${SSH_BASE[@]}" -o SendEnv=WOOLOO_X "$USER_AT" 'wooloo-peer hello; id'
denied "env injection (SetEnv)" rs -o SetEnv=SSH_ORIGINAL_COMMAND=wooloo-peer\ hello "$USER_AT" 'id'
denied "injection: api x; id" rs "$USER_AT" 'wooloo-peer api x; id'
denied "injection: backticks" rs "$USER_AT" 'wooloo-peer api `id`'
denied "injection: \$(..)" rs "$USER_AT" 'wooloo-peer api $(id)'
denied "injection: pipe" rs "$USER_AT" 'wooloo-peer hello | id'
denied "injection: newline" rs "$USER_AT" $'wooloo-peer hello\nid'
denied "injection: session with space" rs "$USER_AT" 'wooloo-peer check a b'
denied "injection: path traversal session" rs "$USER_AT" 'wooloo-peer check ../x'
denied "empty session" rs "$USER_AT" 'wooloo-peer check '
denied "65-char session" rs "$USER_AT" "wooloo-peer check $(printf 'a%.0s' $(seq 1 65))"
denied "request over 16384 bytes" rs "$USER_AT" "wooloo-peer check $(head -c 17000 /dev/zero | tr '\0' a)"
denied "stdin script not in table (/bin/sh -s)" bash -c "printf 'id\n' | $(printf '%q ' "${SSH_BASE[@]}") $USER_AT '/bin/sh -s'"
denied "stdin script with marker + extra command" bash -c "printf \"printf '\\\\n%%s\\\\n' 'herdr-remote-output-ready:1'\\nuname -s\\nid\\n\" | $(printf '%q ' "${SSH_BASE[@]}") $USER_AT '/bin/sh -s'"

# oversize sync line: needs the sync responder entry; the awk cap fires before wooloo-sync runs, so a
# stub responder is enough when the real binary is absent.
if [ ! -x "$H/.local/bin/wooloo-sync" ]; then printf '#!/bin/sh\ncat >/dev/null\n' > "$H/.local/bin/wooloo-sync"; chmod 700 "$H/.local/bin/wooloo-sync"; fi
head -c 1048577 /dev/zero | tr '\0' a > "$T/bigline"; printf '\n' >> "$T/bigline"
out=$("${SSH_BASE[@]}" "$USER_AT" 'wooloo-peer sync' < "$T/bigline" 2>"$T/err"); rc=$?
[ $rc -eq 65 ] && ok "oversize sync line (1 MiB + 1) -> exit 65" || bad "oversize sync line (1 MiB + 1) -> exit 65" "exit $rc stderr=[$(head -c 200 "$T/err")]"
# a line exactly at the cap must pass the cap (the real wooloo-sync rejects the garbage payload with its own
# exit status, e.g. 1; only the cap's 65 / a refusal would be wrong)
head -c 1048576 /dev/zero | tr '\0' a > "$T/okline"; printf '\n' >> "$T/okline"
"${SSH_BASE[@]}" "$USER_AT" 'wooloo-peer sync' < "$T/okline" >/dev/null 2>"$T/err"; rc=$?
! grep -q "size limit" "$T/err" && [ $rc -ne 65 ] && [ $rc -ne 64 ] && ok "sync line at the cap (1 MiB) passes the cap (exit $rc)" || bad "sync line at the cap (1 MiB) passes the cap" "exit $rc stderr=[$(head -c 200 "$T/err")]"

echo
echo "peer-sshd-integration: $PASS passed, $FAIL failed, $SKIP skipped"
[ $FAIL -eq 0 ]
