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

`winget:Microsoft.PowerShell` は MSI と MSIX のどちらの package も同じ正本として導入されうる。MSIX の場合 `pwsh` は `%LOCALAPPDATA%\Microsoft\WindowsApps\Microsoft.PowerShell_<ver>_x64__<publisher>\pwsh.exe` の per-user 実行エイリアスに解決される。`verify.ps1` は MSI path・MSIX `InstallLocation`・実行エイリアスのいずれにも一致すれば正本として受理する。

### Herdr

実機の Herdr は GitHub backend (`github:herdrdev/herdr`、aqua registry より新しい)。Windows だけこの宣言を `mise.global.toml` に置き、Linux/macOS は従来の registry entry のまま。`mise.global.lock` には Windows の GitHub backend entry を追加している。

### Rex

Rex (https://www.superlogical.com/rex) は agent execution runtime の Windows 側 desired state。WinGet package は存在しないため、`platforms/windows-11/install-rex.ps1` が preview channel の公式 artifact index (`blob.superlogical.com/api/releases/rex/preview`) から windows 向け zip を取得し、SHA-256 を照合して `%LOCALAPPDATA%\Programs\Rex` へ展開する。管理者権限は不要。

- user PATH への追加と `rex server install --user`(HKCU Run によるサインイン時起動)まで自動化する。
- 常駐 Windows Service 化 (`rex server install`、管理者権限とアカウントパスワード入力が必要) は手動境界とし、自動実行しない。
- beta 期間中は Windows server が tester enrollment を要求するため、install または server 登録が失敗しても bootstrap は継続する。`verify.ps1` は未導入を FAIL ではなく WARN (pending) として報告する。

channel / pin 判断は [`ADR-0026`](../../docs/adr/ADR-0026.md) を参照。

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

`tailscale status --json` の出力は UTF-8 で decode する。Windows PowerShell 5.1 が console の OEM code page で decode すると、日本語 Windows では Health 文字列が文字化けして `ConvertFrom-Json` が失敗するため、status / serve の呼び出しは一時的に UTF-8 へ切り替えて実行する。

status が取得・parse できない場合は **fail closed** とし、node 登録 (`tailscale up --auth-key`) へ進まない。状態不明を「未接続」と誤認して既存 node を再登録する経路はない。`BackendState` が判明して `Running` 以外 (`NeedsLogin` / `Stopped` など) の場合だけ登録処理へ進む。

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
- registry PATH に置く mise 由来の最小集合は `%LOCALAPPDATA%\mise\shims` だけ (User PATH)。mise の install dir は activation が差し込むもので、registry には置かない。mise の data dir の外にある Rust home (`%USERPROFILE%\.cargo\bin`) も registry PATH には置かない。
- Machine PATH は User PATH より先に評価される。従って `Program Files` 配下の vendor コピーは User PATH の shim より先に勝つ。User 側の編集では直せないため、`mise-path-ownership.ps1` で Machine PATH から冗長な entry を除去する (後述)。
- registry PATH を編集するときは、編集前の値 (Machine/User とも、展開前の生の値) を `%USERPROFILE%\.local\state\pc-setup\` に保存し、そのファイルに復旧コマンドを書き残す。
- 同名の重複のうち、mise が提供しないコマンドを含まない entry は除去対象。含む場合は保持し、各 installer のアンインストールで解消する:
  - `Program Files` の `node` (=`corepack` を含む)、`chocolatey\bin` (=`choco` / `sops` / `terraform` を含む)、`coreutils\bin` は保持。
  - `Program Files` の `gh` / `nvim` は mise が全コマンドを提供するため除去対象。
  - `%APPDATA%\npm` の `claude.cmd`、`%USERPROFILE%\.local\bin` の `claude.exe`、`%USERPROFILE%\.bun\bin`: ほかの npm / bun global package と同じディレクトリにあるため、PATH entry の削除では解消できない。個別に uninstall する場合は各 package manager の操作として別途行う。
  - `WindowsApps` (App execution alias) と `WinGet\Links`: GUI アプリや vendor updater が使う。`mise` 本体は `WinGet\Links` から解決される。
- `verify.ps1` の "Tool ownership" は、activation 済み shell で mise が勝つこと (FAIL)、非 activation で mise の外に解決されるもの (FAIL、名前と解決先を列挙し `mise-path-ownership.ps1` を案内)、`mise which` が実在する binary を指すこと、version を確認する。shim だけが残って tool が宣言されていない orphan shim も WARN にする。

### PATH の一本化 (`mise-path-ownership.ps1`)

Machine PATH が User PATH より先に評価されるため、`Program Files` 配下の vendor コピーは mise shim に勝つ。`verify.ps1` はこれを FAIL として報告するが、修正手段が無かった。`platforms/windows-11/mise-path-ownership.ps1` がその修正を行う。

```powershell
pwsh -NoProfile -File platforms/windows-11/mise-path-ownership.ps1           # plan のみ (書き込みなし)
pwsh -NoProfile -File platforms/windows-11/mise-path-ownership.ps1 -Apply    # 管理者 shell で実行
pwsh -NoProfile -File platforms/windows-11/mise-path-ownership.ps1 -Restore <backup-file>
```

判定は `mise which <name>` を正本とする。あるディレクトリ内の全実行ファイルについて「mise が同名の実体を解決できるか」を調べ、全件が mise 提供なら `remove`、1 件でも mise 非提供なら `keep` として理由を表示する。`keep` の entry は、そのパッケージ固有の installer (winget / choco) でアンインストールするまで残す。

- 変更するのは **Machine PATH のみ**。User PATH、インストール済みプログラム、ディレクトリは消さない。
- 書き込み前に展開前の生値を `%USERPROFILE%\.local\state\pc-setup\machine-path-backup\machine-path-<timestamp>.txt` に保存する。`-Restore` はその値をそのまま書き戻す。
- 管理者権限が無い場合、`-Apply` は変更せず終了する。
- 変更は新規プロセスにのみ効く。既に起動済みの shell は古い PATH を保持し続けるため、PATH から外したコピーを解決しようとして失敗することがある。`-Apply` 後は新しいターミナルを開く。

### User PATH の収束 (`user-path.ps1`)

ADR-0021 は registry User PATH に置く mise 由来の entry を `%LOCALAPPDATA%\mise\shims` だけとし、旧 Rust home の `%USERPROFILE%\.cargo\bin` を外すことを要求する。`platforms/windows-11/user-path.ps1` がその収束を行う。

```powershell
pwsh -NoProfile -File platforms/windows-11/user-path.ps1           # plan のみ (書き込みなし)
pwsh -NoProfile -File platforms/windows-11/user-path.ps1 -Apply    # HKCU のみ、昇格不要
pwsh -NoProfile -File platforms/windows-11/user-path.ps1 -Restore <backup-file>
```

- 変更するのは **User PATH (HKCU) のみ**。展開後の完全一致で `.cargo\bin` entry を除去し、mise shims entry が無ければ末尾へ追加する。並び順は変えず、他の entry・ファイル・ディレクトリは触らない。
- Machine PATH は `mise-path-ownership.ps1` の担当であり、この script は触らない。
- 書き込み前に展開前の生値を `%LOCALAPPDATA%\pc-setup\user-path-backup\user-path-<timestamp>.txt` に保存する。registry の値 kind (REG_SZ / REG_EXPAND_SZ) は保持する。
- `bootstrap.ps1` と `converge.ps1` の両方から呼ばれ、再実行は冪等。`verify.ps1` は `.cargo\bin` 残存と shims entry 欠落を FAIL として報告する。

### 宣言済みツールの実行確認

`verify.ps1` は `Get-Command` による**解決**だけでなく、宣言済みツールを**実際に起動**して確認する。存在確認では検出できない破損があるため。

- 事例: `Get-Command devin` は成功したが `devin --version` は `the devin-win32-x64 package is not installed` で失敗した。mise の npm backend が作る `node_modules/.mise/<pkg>@<ver>` 配下の内部依存が完全でないと、この形で壊れる。
- 同じ壊れ方は devin 固有ではない。別ツールで内部依存ディレクトリを削除すると同じ失敗が再現し、`playwright` でも確認した。
- `mise install <tool>` はこれを修復しない ("already installed" と判断する)。修復は `mise install <key> --force` で行う。
- 失敗時は mise key と実行したコマンド、終了コード、出力の先頭を表示する。

### Legacy `%USERPROFILE%\.rustup` / `%USERPROFILE%\.cargo` (removed)

ADR-0015 / #150 は Rust と Cargo の home を `%LOCALAPPDATA%\mise\{rustup,cargo}` に移した。旧 `%USERPROFILE%\.rustup` と `%USERPROFILE%\.cargo` は移行後は参照されない (orphaned) ため、2026-11-20 に削除した (#206)。削除後も `rustc` / `cargo` / 全 `cargo:` tool が新 home だけで動作することを確認済み。

削除の前提として次を確認した:

1. `mise exec -- rustc --version` と `mise exec -- cargo --version` が通り、`mise exec -- printenv RUSTUP_HOME CARGO_HOME` が `%LOCALAPPDATA%\mise\...` を返す。
2. `mise ls --current` で宣言済みの `cargo:` tool が 1 つも `missing` でない。
3. 旧 `.cargo\bin` が User / Machine どちらの registry PATH にも無い。
4. `~/.config/mise/config.toml` に旧 home への参照が無い。
5. バックアップを `robocopy /E` で取得し、ファイル数が一致することを確認してから削除した。

バックアップは `%USERPROFILE%\.local\state\pc-setup\legacy-rust-<timestamp>\` に置く。復旧はその `.rustup` / `.cargo` を `%USERPROFILE%` へ `robocopy /E` で戻し、必要なら `.cargo\bin` を User PATH へ戻す。

`verify.ps1` は旧 home が再び現れた場合に WARN で報告する (FAIL にはしない。別 machine で意図的に残す判断を妨げないため)。
