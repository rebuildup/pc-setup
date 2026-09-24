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
- an idempotent/safely re-runnable bootstrap or a declarative platform definition that replaces imperative bootstrap
- deterministic verification
- explicit manual/authentication steps
- official source links for version-sensitive installers
- re-evaluation conditions in ADRs for long-lived tool choices

Do not add an OS/platform directory merely as a placeholder. Capture it when the real environment can be observed and reproduced.

## 4. Desired state vs snapshots

Desired state describes the installation channel and required capability. Installation mechanism is platform-specific.

Ubuntu/WSL examples:

- Rust: `rustup` stable
- Claude Code: official native installer
- OpenCode: official stable installer
- Worktrunk: Cargo package

NixOS uses the declared Nix package graph instead of those imperative installers.

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

## 6. NixOS invariants

For `platforms/nixos`:

- primary system baseline tracks NixOS 26.05 stable
- Home Manager tracks the matching `release-26.05`
- fast-moving developer tools use the separately exposed `nixos-unstable` package set
- Claude Code, OpenCode, Worktrunk, Bun, and Rust tooling are Nix-managed, not installed through self-installers
- Home Manager owns user development packages and Worktrunk Bash integration
- hardware configuration, boot, disk layout, hostname, credentials, passwords, and original stateVersion values remain host-specific
- provider credentials and other secrets must not be embedded in Flakes, Nix expressions, or Nix store paths
- concrete hosts commit a `flake.lock` to select exact input revisions
- project-specific runtime/native dependencies remain owned by each project rather than being accumulated into the machine-wide profile

Changing stable/unstable split, package ownership, or host/profile boundary is an ADR-level decision.

## 7. Bootstrap safety

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

## 8. Validation

Shell validation:

```bash
./scripts/ci.sh
```

NixOS profile evaluation:

```bash
nix flake check --no-build ./platforms/nixos
```

Platform verification:

```bash
./platforms/ubuntu-wsl/verify.sh
./platforms/nixos/verify.sh
```

Missing required tools are failures. Missing account authentication and unset personal Git identity are warnings because they require user interaction.

A green CI run validates repository-controlled shell quality and Nix profile evaluation; it does not prove a fresh WSL machine completed external installers or that an arbitrary physical NixOS host can boot.

## 9. Delivery workflow

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

## 10. ADR policy

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

## 11. Writing policy

Persistent prose must stand on its own for a future reader. Do not serialize conversation history, temporary branch state, investigation order, or transient tool output into README/ADR/Issue/PR text unless it is required for auditability or reproducibility.

When documenting a command, verify it against current official documentation when the command is version-sensitive.


## 12. Project-local Skills

Use progressive disclosure: load only the Skill needed for the current task.

### Delivery / coordination
- `skills/github-delivery/SKILL.md`
- `skills/linear-release-control/SKILL.md`
- `skills/parallel-orchestration/SKILL.md`
- `skills/agent-delivery-estimation/SKILL.md`
- `skills/agent-recovery/SKILL.md`

### Engineering / quality
- `skills/engineering-decisions/SKILL.md`
- `skills/design-refinement/SKILL.md`
- `skills/correctness-assurance/SKILL.md`
- `skills/quality-gate/SKILL.md`
- `skills/policy-evaluation/SKILL.md`

### Runtime / security
- `skills/sandbox-runtime/SKILL.md`
- `skills/worktree-workflow/SKILL.md`
- `skills/security-audit/SKILL.md`
- `skills/security-maintenance/SKILL.md`

### Communication / onboarding
- `skills/writing-discipline/SKILL.md`
- `skills/interaction-discipline/SKILL.md`
- `skills/onboarding/SKILL.md`

These Skills are reconciled from `rebuildup/project-init`; `skills/README.md` records the upstream source and last reconciliation evidence. Existing copies are not considered permanently current merely because they are present.


## Constitution / operating profile

- 最上位 contract: [`constitution/CONSTITUTION.md`](constitution/CONSTITUTION.md)
- current Operating Model: [`organization/profiles/release-driven-solo.md`](organization/profiles/release-driven-solo.md)
- 既存の project-specific invariant / ADR は、Constitution と両立する限り generic upstream Practice より具体的な authority として保持する。
