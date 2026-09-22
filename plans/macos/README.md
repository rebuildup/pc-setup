# macOS candidate profile

> Status: **Candidate / planning only**
>
> This is not yet an active `pc-setup` platform. The actual Mac environment has not been observed.

The purpose of this directory is to avoid starting from memory when a Mac is configured while still preserving the repository rule that desired state must represent a real environment.

Long-lived policy: [ADR-0005](../../docs/adr/ADR-0005.md).

## High-confidence candidates

### Ghostty

Primary terminal candidate.

Homebrew Cask:

```bash
brew install --cask ghostty
```

### Amphetamine

Keep-awake utility candidate.

Amphetamine is distributed through the Mac App Store. The candidate Brewfile uses `mas`:

```bash
mas install 937984704
```

### Development baseline

Likely cross-machine development requirements are represented in the candidate Brewfile:

- Git / Git LFS / GitHub CLI
- ripgrep / fd / fzf / jq / bat / tree
- ShellCheck
- Bun
- rustup
- Claude Code
- OpenCode
- Worktrunk
- kanata
- `mas`

These are still reconciled against the real Mac before promotion.

## Cross-platform GUI candidates

The following applications are available for macOS and are worth evaluating because they overlap with the current Windows workflow:

- Vivaldi
- ChatGPT app
- Discord
- Linear
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

## Candidate Brewfile

Review:

```text
plans/macos/Brewfile.candidate
```

Inspect what it would install before applying it.

A future test Mac can use:

```bash
brew bundle --file ./plans/macos/Brewfile.candidate
```

Do not run that command merely to make the candidate list true. First remove candidates that do not match the intended Mac workflow.

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

## Promotion to active platform

After configuring the actual Mac, collect evidence before moving this directory to `platforms/macos`.

At minimum:

```bash
sw_vers
uname -m
brew bundle dump --describe --force --file /tmp/Brewfile.observed
brew list --formula --versions
brew list --cask --versions
mas list
```

Also inspect `/Applications` and vendor-managed products.

Then:

1. Compare observed state with `Brewfile.candidate`.
2. Remove rejected candidates.
3. Add real missing daily tools.
4. Capture relevant non-secret system settings.
5. Add real verification.
6. Promote to `platforms/macos`.
7. Replace/supersede ADR-0005 as needed.

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

- Homebrew: https://brew.sh/
- Homebrew Bundle: https://github.com/Homebrew/homebrew-bundle
- Ghostty: https://ghostty.org/
- Amphetamine: https://apps.apple.com/app/amphetamine/id937984704
- mas: https://github.com/mas-cli/mas
