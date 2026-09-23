# Windows 11 setup

Windows 11 の actual daily environment を、GUI / creative / communication / input / development toolingまで含めて再現する。

machine bootstrapのcanonical entrypointはroot `bootstrap.ps1`。WinGetを直接列挙して実行する運用は廃止し、miseがdesired stateを適用する。

## Fresh setup

> Pre-release note: until 0.1.0 reaches `main`, the common bootstrap intentionally pins branch `1`.


PowerShell:

```powershell
irm https://raw.githubusercontent.com/rebuildup/pc-setup/1/bootstrap.ps1 | iex
```

既存checkoutから:

```powershell
.\bootstrap.ps1
```

platform wrapperも同じroot flowへ委譲する:

```powershell
.\platforms\windows-11\bootstrap.ps1
```

## Bootstrap model

```text
WinGet
  -> Git + mise
  -> mise bootstrap
     -> Windows host apps / SDKs through WinGet
     -> portable developer tools through mise
     -> ~/.dotfiles checkout
     -> Windows post-bootstrap boundary
  -> Microsoft Store-specific apps
```

### WinGet via mise

root `mise.toml` が以下のようなWindows native desired stateを所有する。

- Vivaldi
- Discord
- PowerToys
- WizTree
- Google 日本語入力
- Logitech G HUB
- Linear
- Slack
- Microsoft Teams
- Cursor
- Visual Studio Code
- Warp
- Adobe Creative Cloud
- Android Studio
- Visual Studio 2022 Community
- .NET SDK 10
- PowerShell 7
- kanata GUI

Git自体もbootstrap dependency / desired stateとしてWinGet管理。

### Portable tools via mise

OSごとにWinGet packageを重複宣言せず、root `[tools]` を共有する。

- Node.js
- Python
- Bun
- Rust
- GitHub CLI
- Infisical
- Claude Code
- Codex
- OpenCode
- Worktrunk
- ripgrep / fd / fzf / jq / bat
- ShellCheck
- Neovim

## Microsoft Store boundary

miseのWinGet managerではStore sourceをこのrepositoryの要件どおり明示できないため、Store product IDをroot PowerShell adapterが扱う。

- ChatGPT: `9PLM9XGG6VKS`
- Microsoft PC Manager: `9PM860492SZD`

region/account availabilityに依存する場合はWARNにし、regionを自動変更しない。

## dotfiles

`~/.dotfiles` のcheckout自体はmiseが用意する。

Windows nativeのsymlink adapterはまだcanonical化していないため、root mise taskはWindowsではmachine tool/app setupまでで止める。

現時点のuser-level agent/dotfiles設定はWSL側をcanonicalとし、Windows native adapter完成後に同じsource of truthを接続する。

## Manual/vendor boundaries

次はpackage presenceだけでは完了しない。

### Adobe

Creative Cloudへログイン後:

- After Effects
- Illustrator

をインストールする。

### Cubase / Steinberg

Steinberg Download Assistantを使い、ライセンスに従ってCubaseを導入する。

### Visual Studio

active projectに必要なworkloadだけをVisual Studio Installerから有効化する。

主な候補:

- Desktop development with C++
- .NET desktop development
- Windows App SDK / WinUI related components

### Keyboard

- ChgKey: registry/scan-code based persistent remap
- kanata: runtime/layer based remap

presenceだけで設定完了とは判定しない。

## Verify

```powershell
.\platforms\windows-11\verify.ps1
```

verifyは:

- Windows 11
- `mise bootstrap status --missing`
- portable command capabilities
- Store apps
- Adobe/Cubase child apps
- GitHub auth
- Git identity

を確認する。

## Snapshot

actual machineとの差分を調べる場合:

```powershell
.\platforms\windows-11\snapshot.ps1
```

snapshotはevidenceであり、検出した全appを自動的にdesired stateへ昇格させない。

## Secrets / authentication

password / token / API key / cookie / license secret / private keyはrepositoryへ保存しない。

portable secretはInfisicalがsource of truth。各サービスのinteractive login / licensingは必要に応じて実機で行う。
