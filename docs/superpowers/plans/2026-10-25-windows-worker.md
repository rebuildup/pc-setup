# Windows worker account boundary implementation plan

> Execute with superpowers:executing-plans. Approved spec: [Issue #134](https://github.com/rebuildup/pc-setup/issues/134).

**Goal:** create a reviewable, fail-closed account/ownership/process boundary before any real worker enrollment.

**Architecture:** PowerShell 7.3+ x64, a pure contract, a Windows adapter and a fixed child probe. Logical identity is a UUID; SID/user/path/distro are owned resource attributes. .NET alternate-credential process creation loads the worker profile with an explicit environment allowlist; no broker or scheduler.

**Constraints:** no existing account/profile/distro modification; no password reset, privileged group grant, unregister, upgrade or reboot. SecureString stays in process memory. This source stage does not execute provisioning or import a distro. Account/profile/native-process and cross-user denial require later real credentials and are not inferred from unit tests.

## Review focus

- Foreign/SID/ACL/content drift must fail before a mutation or credentialed launch.
- Repeated provisioning compares ownership and never resets the password.
- Environment is built without copying controller PATH, credentials or canary.
- Partial account/directory creation is preserved for explicit investigation.
- A fresh image's hash/official source pointer is checked before account creation; no existing distro export.

## Tasks

1. Contract RED → GREEN: UUID/resource naming, source/hash, capacity budgets, SID/group/distro matching and child result acceptance; tests in `scripts/test-windows-worker.ps1`.
2. Windows adapter: explicit Provision/Verify/Probe, admin-owned manifest and probe, worker-only data ACL, SecureString credential process. Fixed child handles only its new profile and denial probes. No import command in this stage.
3. Non-mutating self probe: current filtered token + allowlisted environment, clearly not proof of another user's isolation. Verify Win32/.NET capability without creating accounts.
4. Japanese runbook, ADR, CI hook, Windows focused tests and `scripts/ci.sh`; independent review, commit/push branch `134`, Draft PR to `release-0-7-0`.

Native Git worktree is used on Windows; this app's managed-worktree API is bound to the unrelated dotfiles workspace. No runtime services or ports are allocated for authoring.
