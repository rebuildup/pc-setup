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
- Claude Code / Codex / OpenCode / Devin
- Worktrunk / Herdr
- Open Code Review / npkill / cargo-clean-all
- Google Cloud CLI / AWS CLI
- Supabase CLI
- ripgrep / fd / fzf / jq / bat / gdu
- ShellCheck / Neovim

### Rust on Windows

Windows の Rust も mise が管理する。`mise.global.toml` の `rust = "stable"` は全 OS 共通で、`core:rust` backend が rustup を前提に toolchain を入れる。

- 旧 policy (`scripts/apply-global-mise.ps1` が Windows 用 copy に `disable_tools = ["rust"]` を注入) は 2026-11-04 に破棄した。当該 machine には rustup.rs の standalone rustup が存在せず、guard は mise 自身の rustup + stable toolchain を PATH から隠すだけで、`cargo` / `rustc` が一切使えない状態を招いていた。
- 2026-10-17 の incident (mise shim を 1 回呼んだだけで既存 rustup toolchain の `rustc.exe` / `cargo.exe` が消えた) は standalone rustup と mise Rust の**併用**で起きた。guard の代わりに併用を禁止する: standalone rustup (`~/.cargo/bin`) をこの machine に入れない。Rust の正本は mise だけであり、入れ替え時は必ず `platforms/windows-11/verify.ps1` で実バイナリを確認する。
- プロジェクトの `mise.toml` / `rust-toolchain.toml` の pin は `idiomatic_version_file_enable_tools = ["rust"]` により machine-global の `stable` より優先される。
- `cargo:cargo-clean-all` など Rust 依存の cargo backend tool は `depends = ["rust"]` で Rust を要求する。
- `verify.ps1` は `rustup run stable rustc/cargo` で実バイナリを確認する。

### Optional apps and pending items

`apps.psd1` の `Optional = $true` は任意アプリ (Microsoft Teams、Warp)。

- 導入に失敗したら `%LOCALAPPDATA%\pc-setup\pending-apps.json` に記録し、以後 `install-apps.ps1` は自動再試行しない。再試行したい場合はその entry を削除する。
- `verify.ps1` は未導入でも FAIL にせず WARN (pending) とする。必須の開発環境の成立を妨げない。
- Tailscale の backend が `Running` 以外 (`NoState` / `NeedsLogin` など) の場合、verify は WARN (手動境界) とする。認証・node 登録・Serve 設定は自動実行せず、既存の node identity を変更しない。

### PowerShell

Windows の PowerShell は WinGet 管理の `Microsoft.PowerShell` を正本とし、`mise.global.toml` の `powershell` は Linux/macOS 限定。

Machine PATH で x86 版 (`Program Files (x86)\PowerShell`) が x64 版より先にある場合、`pwsh` は x86 版に解決される。Machine PATH は User PATH より先に評価されるため、User 側では直せない。

```powershell
pwsh -NoProfile -File platforms/windows-11/powershell-path.ps1          # plan のみ
pwsh -NoProfile -File platforms/windows-11/powershell-path.ps1 -Apply   # 管理者 shell で実行
```

並び順だけを変更し、PATH entry も PowerShell 本体も削除しない。変更前の PATH は `%LOCALAPPDATA%\pc-setup` に保存する。

### Herdr

実機の Herdr は GitHub backend (`github:herdrdev/herdr`、aqua registry より新しい)。Windows だけこの宣言を `mise.global.toml` に置き、Linux/macOS は従来の registry entry のまま。`mise.global.lock` には Windows の GitHub backend entry を追加している。

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

pc-setup は特定の製品 ID (例: `Microsoft.VisualStudio.2022.Community`) を要求しない。どの edition / 年版 (2022 Community、2026 Insiders、Build Tools など) でもよく、`verify.ps1` が `vswhere` で次の **capability** を検証する。

- MSVC x64/x86 build tools (`Microsoft.VisualStudio.Component.VC.Tools.x86.x64`)
- Windows 10/11 SDK (`Microsoft.VisualStudio.Component.Windows1[01]SDK.*`)

不足していても Visual Studio の構成は自動変更しない (installer 実行・workload 追加/削除なし)。FAIL として報告するだけで、Visual Studio Installer での追加は手動。C++ / .NET desktop の workload は未導入なら WARN のみ。

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

### PATH ownership

どの実行ファイルが選ばれるかは「どの経路で起動したか」で決まる。管理者は次の規則で割り当てる。

| 経路 | PATH の出どころ | 勝つ実行ファイル |
|---|---|---|
| `mise activate pwsh` 済みの shell | mise が install dir / shim を PATH 先頭へ差し込む | mise 管理のもの |
| 非 activation (`pwsh -NoProfile`、Scheduled Task、IDE、GUI 起動) | registry の Machine PATH → User PATH の順 | registry 上で先に並ぶもの |

- mise 管理のツールを activation なしで使う必要がある経路 (Scheduled Task など) は、`mise exec -- <tool>` か shim の絶対パス (`%LOCALAPPDATA%\mise\shims\<tool>.exe`) を使う。PATH の並びに依存しない。
- registry PATH に置く mise 由来の最小集合は `%LOCALAPPDATA%\mise\shims` だけ (User PATH)。mise の install dir は activation が差し込むもので、registry には置かない。mise の data dir の外にある Rust home (`%USERPROFILE%\.cargo\bin`) も registry PATH には置かない (ADR-0015)。
- Machine PATH は User PATH より先に評価される。そのため、Machine PATH にある `Program Files` 配下の同名 binary は、User PATH の shim より先に勝つ。User 側の編集ではこれを直せない。
- registry PATH を編集するときは、編集前の値 (Machine/User とも、展開前の生の値) を `%USERPROFILE%\.local\state\pc-setup\backup-<timestamp>.txt` に保存し、そのファイルに復旧コマンドを書き残す。編集は完全一致の重複 entry の削除に限る。
- 同名の重複 binary は自動では削除しない。残すものと理由:
  - `Program Files` の `gh` / `node` / `nvim`、chocolatey の `rg`: それぞれの installer が管理し、アンインストール経路を持つ。削除は installer 側の操作であり、PATH の整理ではない。mise が activation 済みの shell では mise 側が勝つので実害は出ない。
  - `%APPDATA%\npm` の `claude.cmd`、`%USERPROFILE%\.local\bin\claude.exe`、`%USERPROFILE%\.bun\bin` の `codex` / `opencode`: ほかの npm / bun global package と同じディレクトリにあるため、PATH entry の削除では解消できない。個別に uninstall する場合は各 package manager の操作として別途行う。
  - `WindowsApps` (App execution alias) と `WinGet\Links`: GUI アプリや vendor updater が使う。`mise` 本体は `WinGet\Links` から解決される。
- `verify.ps1` の "Tool ownership" は、activation 済み shell で mise が勝つこと (FAIL)、非 activation で mise の外に解決されるもの (WARN、名前と解決先を列挙)、`mise which` が実在する binary を指すこと、version を確認する。shim だけが残って tool が宣言されていない orphan shim も WARN にする。

### Legacy `%USERPROFILE%\.rustup` / `%USERPROFILE%\.cargo` (orphaned, retained)

ADR-0015 / #150 は Rust と Cargo の home を `%LOCALAPPDATA%\mise\{rustup,cargo}` に移す。旧 `%USERPROFILE%\.rustup` と `%USERPROFILE%\.cargo` は、移行後は参照されない (orphaned) が、そのまま残っていても害はない (inert)。削除は不可逆なので、この変更では削除せず**残す**。`verify.ps1` は存在を情報として WARN に出すだけで、FAIL にはしない。

device-windows では、#150 の「旧 home は削除済み」は検証した別 devnode の話であり、この機では旧 dir が残っている。

削除手順 (将来の reviewed change として実施する。先にバックアップ):

1. 新 home が自立していることを確認する: `mise exec -- rustc --version`、`mise exec -- cargo --version`、`mise exec -- printenv RUSTUP_HOME CARGO_HOME` が `%LOCALAPPDATA%\mise\...` を返す。
2. `mise.global.toml` の全 `cargo:` tool が新 home だけで入ることを確認する。別の一時 `MISE_DATA_DIR` で `mise install --locked` を通すか、`mise ls --current` で全 `cargo:` が `missing` でないことを確認する。
3. バックアップ: `robocopy "$env:USERPROFILE\.cargo" "$env:USERPROFILE\.local\state\pc-setup\legacy-rust-<timestamp>\.cargo" /E` と、`.rustup` について同様。`.cargo\bin` の中身の一覧も控える。
4. 旧 dir を削除する (`.cargo\bin` が registry PATH に無いことを再確認してから)。
5. `verify.ps1` と `pwsh -NoProfile` での解決を再確認する。
6. 復旧: バックアップの `.rustup` / `.cargo` を `%USERPROFILE%` へ `robocopy /E` で戻す。必要なら `.cargo\bin` を User PATH へ戻す。
