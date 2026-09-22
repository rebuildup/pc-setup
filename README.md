# pc-setup

普段使っているPC・OSごとの開発環境を、別マシンや新しいOS環境でも再現できるように保存するための repository です。

一般的な「おすすめツール集」ではなく、**実際に使っている環境の desired state と、その再現手順を管理する personal environment source of truth** として扱います。

## Platforms

| Platform | Status | Entry point |
| --- | --- | --- |
| Ubuntu on WSL2 | Active | [`platforms/ubuntu-wsl/README.md`](./platforms/ubuntu-wsl/README.md) |
| Windows 11 | Active | [`platforms/windows-11/README.md`](./platforms/windows-11/README.md) |
| macOS | Candidate / planning | [`plans/macos/README.md`](./plans/macos/README.md) |

現在の active platform は Ubuntu/WSL2 と Windows 11 です。

## Repository model

各 platform は原則として次の3層で管理します。

1. **Guide** — 人間が読んで理由・順序・手動作業まで理解できる手順
2. **Bootstrap** — 再実行可能な自動セットアップ
3. **Verify** — desired state を満たしているか確認する deterministic check

時点依存の実バージョンは desired state と分離し、必要な場合だけ [`snapshots/`](./snapshots/README.md) に保存します。

```text
.
├── platforms/
│   ├── ubuntu-wsl/
│   │   ├── README.md
│   │   ├── apt-packages.txt
│   │   ├── bootstrap.sh
│   │   └── verify.sh
│   └── windows-11/
│       ├── README.md
│       ├── winget-packages.txt
│       ├── store-packages.txt
│       ├── manual-apps.md
│       ├── bootstrap.ps1
│       ├── verify.ps1
│       └── snapshot.ps1
├── config/
│   └── shell/
│       └── env.sh
├── docs/
│   └── adr/
├── plans/
│   └── macos/
│       ├── README.md
│       ├── Brewfile.candidate
│       └── manual-apps.md
├── snapshots/
├── scripts/
├── AGENTS.md
├── CLAUDE.md
└── CONTRIBUTING.md
```

## Ubuntu/WSL quick start

WSL2 上の Ubuntu で、この repository 自体も Linux filesystem 側に clone します。

```bash
mkdir -p ~/src
cd ~/src
git clone https://github.com/rebuildup/pc-setup.git
cd pc-setup

./platforms/ubuntu-wsl/bootstrap.sh
exec bash
./platforms/ubuntu-wsl/verify.sh
```

bootstrap は以下を整備します。

- base CLI / build toolchain
- GitHub CLI
- Rust / Cargo
- Bun
- Claude Code
- OpenCode
- Worktrunk
- ripgrep / fd / fzf / jq / bat 等のCLI
- `~/.local/bin`, Bun, Cargo を含む shell PATH
- `~/src` workspace

認証は意図的に自動化しません。インストール後に GitHub / Claude / OpenCode の各アカウントへ対話的にログインします。詳細は [`platforms/ubuntu-wsl/README.md`](./platforms/ubuntu-wsl/README.md) を参照してください。

## Windows 11 quick start

Windows は CLI だけでなく GUI / creative / communication / input tooling まで desired state として管理します。

```powershell
.\platforms\windows-11\bootstrap.ps1
.\platforms\windows-11\verify.ps1
```

実機 inventory は `snapshot.ps1` で取得できます。Adobe After Effects / Illustrator / Cubase / ChgKey など package manager 外の項目も明示的に管理します。

## macOS planning

macOS はまだ actual daily environment が確定していないため active platform にはしていません。

[`plans/macos/`](./plans/macos/README.md) に candidate profile を置き、Ghostty / Amphetamine などの高確度候補と cross-platform 候補を区別しています。実機導入後に inventory を採取し、採用内容を確定してから `platforms/macos` へ昇格します。

## Principles

- password、API key、token、cookie、private key 等は commit しない。
- WSL の開発 repository は原則 `/mnt/c` ではなく Linux filesystem (`~/src` 等) に置く。
- official installer / official package repository を優先する。
- 「latest stable を追うもの」と「version pin するもの」を区別する。
- setup 手順の変更理由が長期的に残る場合は ADR を追加する。
- automation が壊れても人間が README から復旧できる状態を維持する。
- bootstrap の成功だけで setup 完了とせず、verify の結果を確認する。

## Decisions

- [`ADR-0001`](./docs/adr/ADR-0001.md) — personal environment を platform guide + bootstrap + verify で管理する
- [`ADR-0002`](./docs/adr/ADR-0002.md) — Ubuntu/WSL2 の baseline toolchain と installation channel
- [`ADR-0004`](./docs/adr/ADR-0004.md) — Windows の complete application inventory と mixed installation channels
- [`ADR-0005`](./docs/adr/ADR-0005.md) — macOS は実機観測まで candidate profile として管理する

## Development

この repository 自体の変更は `project-init` の release-driven workflow に従います。詳細は [`CONTRIBUTING.md`](./CONTRIBUTING.md) と [`AGENTS.md`](./AGENTS.md) を参照してください。

Local validation:

```bash
./scripts/ci.sh
```
