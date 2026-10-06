# macOS candidate application inventory

> Status: **Candidate inventory for unresolved macOS applications**
>
> The macOS platform itself is active under `platforms/macos`. This directory now keeps only choices that have not yet been adopted into canonical desired state.

The purpose of this directory is to keep unresolved GUI/creative/audio candidates separate from the observed active macOS baseline. Installing an application for evaluation does not by itself promote it into desired state.

Long-lived policy: [ADR-0005](../../docs/adr/ADR-0005.md).

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

These remain candidate application choices until actual continued use justifies promotion into the active macOS package graph.

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

As the actual Mac is used, reconcile this list with what remains genuinely required. Accepted entries move into the active mise configuration; rejected entries are deleted.

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

## Promotion of candidate applications

Before promoting candidate applications into active desired state, collect current machine evidence.

At minimum:

```bash
sw_vers
uname -m
mise bootstrap packages status --json
brew list --formula --versions 2>/dev/null || true
brew list --cask --versions 2>/dev/null || true
mas list 2>/dev/null || true
```

Also inspect `/Applications` and vendor-managed products.

Then:

1. Compare observed state with `mise.candidate.toml`.
2. Remove rejected candidates.
3. Add real missing daily tools.
4. Capture relevant non-secret system settings.
5. Add real verification.
6. Move accepted application declarations into the active machine configuration.
7. Keep rejected or still-undecided entries out of canonical desired state.

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
