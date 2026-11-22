# herdr-t3 stable component

Managed install of [rebuildup/herdr-t3](https://github.com/rebuildup/herdr-t3)
for macOS and Windows 11 (Issue #220, herdr-t3 ADR-0004).

## Layout

```
$STATE_DIR/                      # ~/.local/share/herdr-t3 or %LOCALAPPDATA%\herdr-t3
  releases/<ref>/                # one self-contained checkout+build per ref
  current                        # text file naming the selected release
  previous                       # release superseded by the last update
  run/bridge.pid  logs/          # runtime state
```

Only `v*` tags or full commit SHAs are install targets; dev branches and
unreleased release candidates are never selected implicitly. Linux is out
of scope — the herdr TUI keeps its existing operation there.

## Commands

| Action | macOS/POSIX | Windows 11 |
| --- | --- | --- |
| install | `install.sh [ref]` | `install.ps1 [-Ref <ref>]` |
| update | `update.sh [ref]` | `update.ps1 [-Ref <ref>]` |
| launch | `launch.sh` | `launch.ps1` |
| verify | `verify.sh [--live]` | `verify.ps1 [-Live]` |
| rollback | `rollback.sh` | `rollback.ps1` |

`launch` is idempotent: a healthy bridge on `127.0.0.1:4737` is reused and
the browser just opens; a foreign listener on the port is reported rather
than hijacked. Builds happen at install/update/rollback-prep time only —
never at launch. A failed update or install leaves `current` (and the
running bridge) untouched; `rollback` flips the pointer back to the
previous release dir, which is kept on disk.

`verify --live` additionally checks `GET /api/health` reports `ok`,
`herdr.reachable`, and exposes the installed version/commit.

## Integration notes

- Requires `git`, `mise` (herdr-t3 pins bun+node via `mise.toml`), `bun`,
  `curl` (POSIX) / `Invoke-RestMethod` (Windows).
- The dev profile (`scripts/dev.sh` in herdr-t3) uses port 4738 and never
  collides with the stable 4737.
- Windows herdr connectivity goes through the named-pipe endpoint
  (`\\.\pipe\<herdr.sock path>`); the bridge handles that transparently
  once herdr-t3#6 lands — until then `verify --live` on Windows may report
  `herdr.reachable=false`.
