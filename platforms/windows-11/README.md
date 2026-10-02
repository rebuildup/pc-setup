# Windows 11 setup

Windows 11 の actual daily environment を、GUI / creative / communication / input / development toolingまで含めて再現する。

machine bootstrapのcanonical entrypointはroot `bootstrap.ps1`。WinGetを直接列挙して実行する運用は廃止し、miseがdesired stateを適用する。

## Fresh setup

PowerShell:

```powershell
irm https://raw.githubusercontent.com/rebuildup/pc-setup/main/bootstrap.ps1 | iex
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
     -> Windows foundation SDKs through WinGet
     -> portable developer tools through mise
     -> ~/.dotfiles checkout
     -> Windows post-bootstrap boundary
  -> best-effort desktop apps from apps.psd1
  -> Notion official MSIX
  -> Microsoft Store-specific apps
```

### Mandatory Windows foundation via mise

root `mise.toml` の mandatory Windows package phase には、bootstrap / development foundation を残す。

- Git
- PowerShell 7
- .NET SDK 10
- Visual Studio 2022 Community
- Android Studio
- Google Cloud SDK
- AWS CLI
- Tailscale

これらは fail-fast。Git と mise 自体も bootstrap dependency。

### Best-effort desktop apps

GUI / desktop application は `platforms/windows-11/apps.psd1` が canonical inventory。

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
- kanata GUI

root bootstrap は `install-apps.ps1` を呼び、各 app を exact package ID で個別に導入する。1件の installer failure は warning として残し、残り app と bootstrap 全体は続行する。

一方、`verify.ps1` は同じ `apps.psd1` を読み、missing app を failure として扱う。つまり bootstrap continuity と desired-state completeness を分離する。

### Notion official MSIX boundary

NotionはWinGetのNSIS installerをmandatory mise phaseでは使用しない。vendor installer failureが他のmachine setup全体を停止させた実機事例があるため、root PowerShell adapterがNotion公式のMSIX endpointを使用する。

- x64: `https://www.notion.com/desktop/windows-msix/download`
- arm64: `https://www.notion.com/desktop/windows-msix-arm/download`

既存のlegacy WinGet/NSIS版またはMSIX版があれば再インストールしない。自動MSIX installが失敗した場合はwarningとして後続bootstrapを継続するが、`verify.ps1`ではNotion不在をfailureとして扱う。

### Portable tools via mise

OSごとにWinGet packageを重複宣言せず、`mise.global.toml [tools]` を共有する。

- Node.js / pnpm / Bun
- Python / Rust
- GitHub CLI / Infisical
- Claude Code / Codex / OpenCode
- Worktrunk / Herdr
- Open Code Review / npkill / cargo-clean-all
- Google Cloud CLI / AWS CLI
- Supabase CLI / Vercel CLI
- ripgrep / fd / fzf / jq / bat / gdu
- ShellCheck / Neovim

## Microsoft Store boundary

miseのWinGet managerではStore sourceをこのrepositoryの要件どおり明示できないため、Store product IDをroot PowerShell adapterが扱う。

- ChatGPT: `9PLM9XGG6VKS`
- Microsoft PC Manager: `9PM860492SZD`

region/account availabilityに依存する場合はWARNにし、regionを自動変更しない。

## Tailscale / WSL SSH

Windows host の Tailscale client 自体は通常の `bootstrap.ps1` で導入する。tailnet enrollment は secret-backed post-bootstrap boundary とし、interactive browser loginを bootstrap から開始しない。

secret-free contract は `platforms/windows-11/tailscale.psd1` に保持する。

- Infisical site: `https://secrets.rebuildup.dev`
- environment: `prod`
- path: `/infrastructure/tailscale`
- required secret: `TAILSCALE_OAUTH_CLIENT_SECRET`
- Tailscale device tag: `tag:personal-device`
- tailnet TCP `2222` -> `tcp://127.0.0.1:2222` (Ubuntu SSH)
- tailnet TCP `2223` -> `tcp://127.0.0.1:2223` (Ubuntu2 SSH)

Tailscale 側の OAuth client は `auth_keys` scope と `tag:personal-device` の発行権限を持たせ、その client secret を上記 Infisical path に保存する。secret value は repository や PowerShell profileへ保存しない。

Infisical CLI の認証が利用可能になった後、Windows PowerShell 7 から実行する。

```powershell
$env:INFISICAL_API_URL = 'https://secrets.rebuildup.dev/api'
infisical login --domain=https://secrets.rebuildup.dev
.\platforms\windows-11\setup-tailscale.ps1
```

setup script は Infisical から OAuth secret を runtime injectionし、未接続の host だけを persistent / preauthorized node として登録する。既に Tailscale backend が `Running` の host は既存 node identity を維持し、再登録しない。

その後 Tailscale Serve を idempotent に収束させるため、WSL 側の SSH endpoint は従来どおり Windows localhost にだけ bind したままでよい。LAN interfaceへ `2222` / `2223` を直接公開しない。

詳細な authority / recovery boundary は [ADR-0011](../../docs/adr/ADR-0011.md) を参照。

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
- best-effort desktop app inventory
- portable command capabilities
- Store apps / Notion MSIX
- Tailscale backend / WSL SSH Serve mapping
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

portable secretはInfisicalがsource of truth。Tailscale provisioning の provider pointer / required key / forwarding contract は `tailscale.psd1` に置き、OAuth client secret value は Infisical だけに保持する。各サービスのinteractive login / licensingは必要に応じて実機で行う。
