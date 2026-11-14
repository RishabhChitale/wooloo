# Peer pairing (Mac side, M3)

"Pair Device…" in the Connections window lets one of the user's own computers (the Windows
wooloo client first) open Herdr bridges on this Mac over SSH, and lets this Mac save an SSH
profile for that computer's own Herdr server. Each machine keeps running its own Herdr server;
both apps are clients. The network is expected to be Tailscale: never expose SSH or Herdr
sockets to the open internet.

## Prerequisites

- Remote Login on: System Settings > General > Sharing > Remote Login (sshd).
- Tailscale on both machines, signed in to the same tailnet. Use the MagicDNS name
  (`mac-name.tailnet-name.ts.net`) or the `100.x` address as the pairing target.
- Herdr installed on this Mac before pairing (the dispatcher runs the Herdr path found at pairing
  time; it never installs or updates Herdr for a peer).

## Pairing code

Both sides show and accept the same text code:

```
wooloo-pair-v1:<base64url(JSON)>
```

The JSON object (keys sorted, no padding in the base64url) has:

| key | meaning | validation |
| --- | --- | --- |
| `target` | how the other side reaches this machine: `user@host[:port]`, `[ipv6]:port` | `[A-Za-z0-9._@:[]-]`, 1–255, no leading `-`, at most one `@`, port 1–65535 |
| `publicKey` | this machine's device key, `type blob` | ed25519, rsa or ecdsa, structure checked by `MobileSSHPublicKey` |
| `hostKey` | this machine's SSH host key, `type blob` | same check |
| `herdrVersion` | Herdr version on this machine | `[0-9A-Za-z.+-]`, 1–32 |
| `session` | Herdr session to offer | `[A-Za-z0-9_-]`, 1–64 |
| `label` | display name | ≤64, no control characters |

Decoding always validates, so a code can be pasted from anywhere. The peer id is the label
lowercased to `[a-z0-9-]` (≤32, fallback `device`); pairing the same label again replaces that
peer's files.

This Mac's code uses:

- device key `~/.ssh/wooloo_peer_ed25519`, made with `ssh-keygen -t ed25519 -N ""` when missing.
  It has no passphrase because Herdr and wooloo connect with `BatchMode`. Only the `.pub` is ever
  read by wooloo; the private key stays in `~/.ssh`.
- host key `/etc/ssh/ssh_host_ed25519_key.pub`;
- Herdr version from `herdr --version`;
- target typed by the user, defaulting to `<user>@<host name>`.

## What pairing changes on this Mac

Only after the user reviews the peer's label, target and both fingerprints:

1. Installs the dispatcher `~/.local/share/wooloo/peer-bridge` (mode 700, written atomically). It
   holds the Herdr path and version found at pairing time; the path must match
   `^/[A-Za-z0-9._/-]+$`.
2. Adds the peer's public key to `~/.ssh/authorized_keys` through `MobileSSHAccess`'s locked,
   atomic script, with the options
   `command="<home>/.local/share/wooloo/peer-bridge --peer <id>",restrict`. If the key is already
   in the file the entry is left exactly as it was (it may be unrestricted) and the sheet says so.
3. Writes `~/.ssh/wooloo_peers/<id>.known_hosts` (`wooloo-peer-<id> <type> <blob>`) and
   `~/.ssh/wooloo_peers/<id>.conf`:

   ```
   Host wooloo-peer-<id>
       HostName <host>
       User <user>
       Port <port>
       IdentityFile ~/.ssh/wooloo_peer_ed25519
       IdentitiesOnly yes
       HostKeyAlias wooloo-peer-<id>
       UserKnownHostsFile ~/.ssh/wooloo_peers/<id>.known_hosts
       StrictHostKeyChecking yes
   ```

4. With a separate checkbox the user ticks, adds `Include ~/.ssh/wooloo_peers/*.conf` as the first
   line of `~/.ssh/config` (idempotent, atomic, mode 600). A symlinked config is refused with a
   message to add the line by hand.
5. Runs `herdr machine add wooloo-peer-<id> --remote-session <session> --label <label>`. A failure
   there is reported ("profile written; Herdr couldn't add it: …") without undoing steps 1–4.

## Dispatcher grammar

sshd runs the dispatcher for every connection with the peer's key and puts the requested command
in `SSH_ORIGINAL_COMMAND`. None of that text is executed; it is matched against fixed forms and
the dispatcher then runs `exec <herdr> [--session S] <verb> [flag]` itself.

- `wooloo-peer hello` → prints `wooloo-peer-bridge-v1 <herdr version>`.
- `wooloo-peer api S`, `wooloo-peer client S`, `wooloo-peer check S` → `remote-api-bridge`,
  `remote-client-bridge`, `remote-api-bridge --check` on session S.
- Herdr's own bridge scripts: the request must contain exactly one line
  `exec <path> [--session S] (remote-api-bridge|remote-client-bridge) [--idle-timeout-v1|--check] [</dev/null]`
  (a trailing `'` is allowed). The path in the request is ignored; the paired path is used. If the
  request contains `herdr-remote-output-ready:1`, the marker is echoed before the exec.
- Anything else, a bad peer name, a session outside `[A-Za-z0-9_-]{1,64}`, a request over 16 KiB
  or a missing Herdr binary exits 64 with `wooloo-peer-bridge: <reason>` on stderr.

`restrict` also turns off port, agent and X11 forwarding and PTY allocation for that key.

## Presence

For bridge requests without `--check` the dispatcher writes
`~/.local/state/wooloo/peer-presence/<id>.<pid>` (via a temp file and `mv`, skipped if the
directory is a symlink) with `peer=`, `session=`, `verb=`, `started=` lines. The pid stays the
same through `exec`, so the file names the running bridge. wooloo scans the folder every 5 s,
deletes files whose pid is gone or no longer a `herdr*` executable (`kill(pid, 0)` and
the `sysctl` process name), and shows "Attached: <peers>" on that local session's row.

## Caveats

- The forced command blocks everything except bridges, so for a paired peer key these do not work:
  `herdr --machine`, `herdr machine add`'s preparation, Herdr install/live handoff, wooloo's
  `remoteSnapshot`, `HerdrRemoteConfig`, `WorkspaceFiles` git/file/HostStats over SSH and the
  `MobileSSHAccess` identity probe.
- Herdr's preparation probes (`/bin/sh -s` with `uname -s`/`uname -m`, `command -v herdr`, the
  candidate script, `test -x … status client --json`) are refused. So `herdr machine add` and a
  saved-profile connect fail against a bridge-only peer. In the Mac→PC direction, step 5 works only
  if the PC's entry for this Mac's key is unrestricted or the Windows dispatcher answers those
  probes; the PC→Mac client must use the `wooloo-peer api|client|check S` forms or Herdr's bridge
  script line.
- A key already present in `authorized_keys` keeps its existing (possibly unrestricted) entry.
- Herdr paths with spaces or other characters outside `[A-Za-z0-9._/-]` are refused, as are home
  directories outside that set (the forced command would need quoting sshd does not apply).
- The device key has no passphrase; protect `~/.ssh` accordingly. Removing a peer means deleting
  its `authorized_keys` line and `~/.ssh/wooloo_peers/<id>.*`.
- The peer's host key comes from the pairing code, which is only as trustworthy as the channel it
  was copied over; compare the fingerprints shown on both screens.

## Tests (CI, `woolooTests/PeerPairingTests`)

- Code round trip, every rejection rule, target parsing (`user@host`, `:port`, `[v6]:port`, bare v6).
- `installationScript` with options writes `command=…,restrict ssh-ed25519 …` into a temp home.
- Dispatcher run by `/bin/sh` with `SSH_ORIGINAL_COMMAND`, `HOME` in a temp dir and a fake Herdr:
  hello, the three short forms, Herdr's script line with and without the marker, `</dev/null`,
  idle flag; rejections for `;`, `$(…)`, backticks, two exec lines, `/bin/sh -s`, an empty request,
  a bad session, a bad peer name (all exit 64); the presence file and its absence for `--check`.
- Device key creation with `ssh-keygen` in the temp home, `Include` idempotency and symlink refusal,
  peer files, and the presence scan with an injected liveness check.
- Nothing touches the real `~/.ssh`, Herdr sessions or config.

## Unverified

- The Swift has not been compiled (only CI can build it).
- sshd's `SSH_ORIGINAL_COMMAND` with Herdr's multi-line bridge scripts, and whether `restrict`
  (no PTY) disturbs the bridges, have only been tested by running the dispatcher directly.
- Herdr's request strings are from 0.9.5 and may change.
- `herdr machine add`/connect against a bridge-only peer (expected to fail, see Caveats).
- Whether Herdr's own `ssh` calls pick up `~/.ssh/config`'s `Include` (they would not with `-F`).
- The Windows dispatcher; pid reuse between scans.
