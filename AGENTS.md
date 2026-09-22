# AGENTS.md — pc-setup root agent contract

This is the always-on contract for AI agents working on `pc-setup`.

The repository follows the current `rebuildup/project-init` release-driven operating model. Keep this root contract project-specific; do not copy the complete upstream initialization prompt here.

## 1. Project identity

- `pc-setup` is the personal source of truth for reproducing the maintainer's actual development environments.
- It is not a generic recommendation catalog.
- Canonical remote: `https://github.com/rebuildup/pc-setup.git`.
- `main` is released/integrated state.
- Internal docs, Issues, PRs, reviews: Japanese is preferred.
- Shell code and identifiers: English.
- Never persist credentials, tokens, passwords, cookies, private keys, or provider auth files.

## 2. Canonical documentation hierarchy

For environment setup decisions, use this precedence:

1. accepted repository ADRs and this root contract
2. platform guide under `platforms/<platform>/README.md`
3. executable bootstrap / verify implementation
4. current official vendor documentation
5. current machine state as evidence, not authority

If executable behavior and documentation disagree, treat the mismatch as a defect. Do not silently redefine the desired environment from whatever happens to be installed on one machine.

## 3. Platform model

Each supported platform SHOULD have:

- a human-readable setup guide
- an idempotent or safely re-runnable bootstrap
- deterministic verification
- explicit manual/authentication steps
- official source links for version-sensitive installers
- re-evaluation conditions in ADRs for long-lived tool choices

Do not add an OS/platform directory merely as a placeholder. Capture it when the real environment can be observed and reproduced.

## 4. Desired state vs snapshots

Desired state describes the installation channel and required capability, for example:

- Rust: `rustup` stable
- Claude Code: official native installer
- OpenCode: official stable installer
- Worktrunk: Cargo package

A point-in-time version inventory is evidence only. Store version snapshots separately under `snapshots/` when useful.

Do not pin continuously updated user tools merely to make a snapshot look reproducible unless an ADR establishes a compatibility reason to pin them.

## 5. Ubuntu/WSL invariants

For `platforms/ubuntu-wsl`:

- target WSL2 + Ubuntu
- development repositories live on the Linux filesystem (`~/src` by default), not `/mnt/c`
- WSL is treated as its own development machine for tool installation and authentication
- GitHub CLI uses the GitHub-maintained Debian/Ubuntu package repository
- Rust uses `rustup`
- Bun uses the official installer
- Claude Code uses the official native Linux/WSL installer
- OpenCode uses the official stable installer
- Worktrunk is installed through Cargo and receives shell integration
- `ripgrep`, `fd`, `fzf`, `jq`, `bat`, compiler/build essentials and shell validation tools are present
- aliases/symlinks needed to normalize Ubuntu executable names (`fdfind` -> `fd`, `batcat` -> `bat`) are user-local

Changing these defaults is an ADR-level decision when it changes the long-lived reproduction model.

## 6. Bootstrap safety

Bootstrap scripts must:

- use `set -euo pipefail`
- be safe to rerun
- avoid overwriting unrelated user configuration
- mark any managed shell block
- avoid interactive authentication
- avoid storing secrets
- fail clearly when a mandatory installation step fails
- keep manual steps visible in the platform guide
- prefer official distribution channels over copied binaries from unknown sources

Do not perform a full OS upgrade as an incidental side effect of environment bootstrap.

## 7. Validation

Canonical local validation:

```bash
./scripts/ci.sh
```

It validates shell syntax and ShellCheck findings for repository scripts.

Platform verification:

```bash
./platforms/ubuntu-wsl/verify.sh
```

Missing required tools are failures. Missing account authentication and unset personal Git identity are warnings because they require user interaction.

A green CI run validates repository script quality; it does not prove a fresh WSL machine completed the external installers successfully.

## 8. Delivery workflow

Use the current `project-init` release-driven profile:

- one normal sprint -> one target minor version
- release integration branch: `release-x-y-z`
- one top-level GitHub Issue -> branch named only by Issue number -> one ticket PR
- independent ticket PR base: target release branch
- active durable ticket branches require a published remote head and Draft PR
- `main` changes through the release PR path
- PR landing method is merge commit; squash/rebase merge are not part of the intended repository policy
- agents do not merge PRs without explicit human authorization

The repository was initially empty, so creating the first `main` commit is a one-time bootstrap prerequisite, not a normal delivery path.

## 9. ADR policy

Create or revise an ADR when changing a long-lived decision about:

- platform scope
- tool selection or installation channel
- version/pinning policy
- shell/config ownership
- secrets/authentication boundary
- workspace location
- verification architecture
- repository delivery policy

ADRs describe the final decision and rationale, not the chronological work log.

## 10. Writing policy

Persistent prose must stand on its own for a future reader. Do not serialize conversation history, temporary branch state, investigation order, or transient tool output into README/ADR/Issue/PR text unless it is required for auditability or reproducibility.

When documenting a command, verify it against current official documentation when the command is version-sensitive.
