# herdr-t3 stable component

Managed install of [rebuildup/herdr-t3](https://github.com/rebuildup/herdr-t3)
as a native Electron desktop app for macOS and Windows 11
(Issue #220, herdr-t3 ADR-0004, pc-setup ADR-0028). The earlier browser/PWA
bridge design is superseded and must not be revived.

## Layout

```
$STATE_DIR/                      # ~/.local/share/herdr-t3 or %LOCALAPPDATA%\herdr-t3
  releases/<ref>/                # one self-contained checkout+build per ref
  current                        # text file naming the selected release
  previous                       # release superseded by the last update
  current_app                    # path to the staged .app / built .exe
  installed                      # selected release name + commit
  logs/                          # build logs
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

macOS stages the built `.app` into `~/Applications` so it behaves like a
normal app (Finder, Spotlight, Launch Services, Dock). Windows keeps the
built `win-unpacked` tree under the release dir and registers a Start Menu
shortcut (`%APPDATA%\Microsoft\Windows\Start Menu\Programs\herdr-t3.lnk`)
that tracks the selected executable.

`launch` is idempotent: it activates the already-running app. Builds happen
at install/update time only — never at launch. A failed install or update
leaves `current` (and the installed app / shortcut) untouched; `rollback`
flips the pointer back to the previous release dir, which is kept on disk,
and re-stages it.

`verify --live` additionally checks that the app process is running, the
herdr endpoint is reachable (macOS: `~/.config/herdr/herdr.sock`; Windows:
the named-pipe endpoint `\\.\pipe\<herdr.sock path>`), and — on macOS —
that the app's own `bridge-status.json` reports a fresh successful herdr
snapshot.

## Integration notes

- Requires `git`, `mise` (herdr-t3 pins bun+node via `mise.toml`), `bun`,
  `curl` (POSIX) / `Invoke-RestMethod` (Windows).
- Windows herdr connectivity goes through the named-pipe endpoint; the app
  handles that transparently once herdr-t3#6 lands — until then
  `verify.ps1 -Live` on Windows may report `herdr.reachable=false`.
