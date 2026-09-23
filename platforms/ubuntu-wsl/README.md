# Ubuntu / WSL setup

Ubuntu on WSL2 is an active development platform.

The machine baseline is now applied through the root mise bootstrap rather than a long Ubuntu-specific installer.

## Fresh setup

> Pre-release note: until 0.1.0 reaches `main`, the bootstrap command pins branch `1`.


From a fresh Ubuntu/WSL distribution:

```bash
curl -fsSL https://raw.githubusercontent.com/rebuildup/pc-setup/1/bootstrap.sh | bash
```

That entrypoint installs only the prerequisites needed to start mise, then mise applies the repository desired state.

When working from an existing pc-setup checkout:

```bash
./bootstrap.sh
```

The compatibility platform entrypoint delegates to the same root flow:

```bash
./platforms/ubuntu-wsl/bootstrap.sh
```

## What happens

The bootstrap converges the machine in this order:

```text
minimal Git + mise
  -> Ubuntu host/build packages through APT
  -> ~/.dotfiles checkout
  -> portable development tools through mise
  -> dotfiles bootstrap
  -> verification
```

Host packages include the native build foundation such as:

- Git / Git LFS
- CA certificates / curl / wget
- build-essential / pkg-config / OpenSSL headers
- CMake / Ninja / Clang / LLDB
- archive/sync utilities
- Python venv support
- OpenSSH client

Portable developer tools are declared once in `mise.global.toml`, which is linked as the user's global mise config:

- Node.js / Python / pnpm / Bun / Rust
- GitHub CLI / Infisical CLI
- Claude Code / Codex / OpenCode
- Worktrunk / Herdr
- Open Code Review / npkill / cargo-clean-all
- Google Cloud CLI / AWS CLI / Supabase CLI / Vercel CLI
- ripgrep / fd / fzf / jq / bat
- ShellCheck / Neovim

The Ubuntu bootstrap does not duplicate installation logic for those tools.

## Authentication and dotfiles

mise clones `rebuildup/dotfiles` to:

```text
~/.dotfiles
```

After the tool phase, the final bootstrap task runs:

```bash
~/.dotfiles/script/bootstrap
```

That flow owns:

- Git identity in `~/.gitconfig.local`
- GitHub browser authentication and credential helper
- private agent-config submodule checkout
- Infisical user login/access validation
- user-level symlink setup

Credentials are not stored in pc-setup.

## Workspace

Development repositories belong on the Linux filesystem:

```text
~/src/
```

Do not use `/mnt/c` as the normal Git/build/watch/worktree workspace.

The root bootstrap checkout itself defaults to:

```text
~/src/pc-setup
```

## Verify

After bootstrap, open a fresh shell and run:

```bash
cd ~/src/pc-setup
./platforms/ubuntu-wsl/verify.sh
```

A `FAIL` means the machine does not satisfy the declared baseline. Authentication/manual state may remain a `WARN`.

To capture version evidence without turning every current version into a desired-state pin:

```bash
mkdir -p snapshots
./platforms/ubuntu-wsl/verify.sh --snapshot \
  > "snapshots/ubuntu-wsl-$(date +%F).txt"
```

## Recovery path

If the downloaded root bootstrap cannot be used, install Git and mise only, then let mise do the rest:

```bash
sudo apt-get update
sudo apt-get install -y git curl ca-certificates
curl -fsSL https://mise.run/bash | sh
export PATH="$HOME/.local/bin:$PATH"

git clone --branch 1 --single-branch https://github.com/rebuildup/pc-setup.git "$HOME/src/pc-setup"
cd "$HOME/src/pc-setup"
./bootstrap.sh
```

Do not reconstruct the old package-by-package installation procedure manually.

## WSL boundary

The WSL distribution is treated as its own development machine. Windows-side installations and authentication do not imply the same tool/auth state inside WSL.

Windows-native applications are managed by the Windows pc-setup profile; the Linux development environment is managed here.
