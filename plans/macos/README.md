# macOS remaining candidates

> Status: **Planning state for capabilities not yet adopted**
>
> The actual Mac now has an active baseline under `platforms/macos/`. Files in this directory are only unresolved application/workflow candidates and are not loaded by the active bootstrap.

Long-lived policy: [ADR-0012](../../docs/adr/ADR-0012.md).

## High-confidence candidates

### Ghostty

Primary terminal candidate.

Candidate package declaration:

```toml
"brew-cask:ghostty" = { os = "macos" }
```

Homebrew is used through mise's built-in package backend; it is not the setup entrypoint.

### Amphetamine

Keep-awake utility candidate.

Amphetamine is distributed through the Mac App Store. The candidate mise config records its App Store ID:

```toml
"mas:937984704" = { os = "macos" }
```

### Development baseline

Cross-machine developer CLI/runtime requirements are inherited from root `mise.toml`:

- GitHub CLI / Infisical
- Node.js / Python / pnpm / Bun / Rust
- Claude Code / Codex / OpenCode / Worktrunk / Herdr
- Open Code Review / npkill / cargo-clean-all
- Google Cloud CLI / AWS CLI / Supabase CLI / Vercel CLI
- ripgrep / fd / fzf / jq / bat / gdu / ShellCheck / Neovim

macOS-specific application candidates are recorded separately in `mise.candidate.toml`.

These candidates are reconciled against actual use before being promoted into active desired state.

## Cross-platform GUI candidates

The following applications are available for macOS and are worth evaluating because they overlap with the current Windows workflow:

- Vivaldi
- ChatGPT app
- Discord
- Linear
- Notion
- Slack
- Microsoft Teams
- Cursor
- Visual Studio Code
- Warp
- Android Studio
- Google 日本語入力
- Logitech G HUB
- Adobe Creative Cloud
- Steinberg Download Assistant

They are candidates, not automatic requirements.

In particular, Ghostty may make Warp unnecessary, and the final editor mix may not need both Cursor and VS Code.

## Candidate mise additions

Review:

```text
plans/macos/mise.candidate.toml
```

This file is planning state and is not loaded by the active root bootstrap yet.

When the actual Mac is configured, reconcile the candidate list with what is really used. Accepted entries then move into the active mise configuration; rejected entries are deleted.

Do not run a Homebrew/Brewfile path merely to make the candidate list true. The intended active entrypoint is the root pc-setup bootstrap, with Homebrew acting only as a mise backend.

## Creative / audio

See [`manual-apps.md`](./manual-apps.md).

Current candidates:

- Creative Cloud -> After Effects / Illustrator
- Steinberg Download Assistant -> Cubase

The child applications remain explicit even though their vendor manager performs installation.

## What is intentionally unresolved

The following should be decided from actual use:

- Ghostty only vs Ghostty + Warp
- Cursor vs VS Code vs both
- Logitech G HUB vs Logi Options+ vs neither
- kanata service/permissions/config
- Google 日本語入力 vs Apple Japanese input
- Android Studio local development need
- Adobe applications on Mac
- Cubase/audio workflow on Mac
- machine-wide Node strategy beyond Bun
- macOS defaults / Dock / Finder / keyboard settings
- package-manager ownership for app-specific plugins
- backup/migration of non-secret app preferences

## Promotion of a candidate

A candidate moves into active macOS desired state only after it is actually used and intentionally adopted on the real Mac. Record the executable setup/verification under `platforms/macos/` or the shared root mise configuration as appropriate. Unresolved candidates remain here rather than being installed merely to match this list.

## Authentication / permissions

Do not store:

- Apple Account credentials
- GitHub tokens
- ChatGPT/Claude/OpenCode credentials
- Slack/Teams/Discord/Linear sessions
- Adobe/Steinberg credentials or license state
- SSH private keys
- macOS Keychain data

Some applications, especially keyboard/input tooling, may require Accessibility or Input Monitoring permission. That permission state must be verified on the real Mac rather than assumed from package installation.

## References

- mise bootstrap packages: https://mise.jdx.dev/bootstrap/packages/
- Homebrew backend: https://mise.jdx.dev/bootstrap/packages/brew.html
- Ghostty: https://ghostty.org/
- Amphetamine: https://apps.apple.com/app/amphetamine/id937984704
- mas: https://github.com/mas-cli/mas
