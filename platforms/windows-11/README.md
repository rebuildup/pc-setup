# Windows 11 setup

Windows 11 の actual daily environment を、CLI だけでなく GUI / creative / communication / input / hardware utility まで含めて記録します。

## Model

- WinGet で管理できるもの: `winget-packages.txt`
- Microsoft Store: `store-packages.txt`
- Adobe / Steinberg / ChgKey 等: `manual-apps.md`
- 自動導入: `bootstrap.ps1`
- desired state 検証: `verify.ps1`
- 実機 inventory 採取: `snapshot.ps1`

詳細な長期方針は `docs/adr/ADR-0004.md` を参照してください。

## Desired applications

### Daily desktop

- Vivaldi
- ChatGPT app
- Discord
- PowerToys
- WizTree
- Microsoft PC Manager
- Google 日本語入力
- Logitech G HUB
- Linear
- Slack
- Microsoft Teams
- Cursor
- Visual Studio Code
- Warp

### Creative / audio

- Adobe Creative Cloud
- Adobe After Effects
- Adobe Illustrator
- Steinberg Download Assistant
- Cubase

### Development

- Android Studio
- Visual Studio 2022 Community
- .NET SDK 10
- Git / GitHub CLI
- PowerShell 7
- Node.js LTS
- Bun
- Rust / Cargo
- ripgrep / fd / fzf / jq / bat

### Keyboard / input

- kanata GUI
- ChgKey / Change Key

## Bootstrap

PowerShell 7 または Windows PowerShell から repository root で:

```powershell
.\platforms\windows-11\bootstrap.ps1
```

実際に変更せず install plan だけ確認:

```powershell
.\platforms\windows-11\bootstrap.ps1 -WhatIf
```

Store app を後回しにする場合:

```powershell
.\platforms\windows-11\bootstrap.ps1 -SkipStore
```

WinGet package は fuzzy search ではなく exact package ID で導入します。

## Microsoft Store

ChatGPT は OpenAI の current official Windows deployment product ID を使用します。

```powershell
winget install --id 9PLM9XGG6VKS --source msstore --exact
```

PC Manager:

```powershell
winget install --id 9PM860492SZD --source msstore --exact
```

PC Manager は Store availability が region/account に依存する場合があります。bootstrap は region を勝手に変更しません。

## Adobe

Creative Cloud desktop app は WinGet で導入します。その後 Creative Cloud にログインして:

- After Effects
- Illustrator

をインストールします。

Creative Cloud が存在するだけでは setup 完了ではありません。

## Cubase / Steinberg

Steinberg Download Assistant は Steinberg の current official installer から導入します。

- https://www.steinberg.net/sda

ログイン/ライセンス認証後に Cubase をインストールします。edition/version は実際の license に従い、この repository では勝手に固定しません。

## Android Studio / JDK

Android Studio は `Google.AndroidStudio` で導入します。

過去のように複数の system JDK を無秩序に増やさず、Android Studio bundled runtime と project-specific toolchain を優先します。

## Visual Studio

`Microsoft.VisualStudio.2022.Community` を導入した後、Visual Studio Installer で active project に必要な workload を確認します。

主な候補:

- Desktop development with C++
- .NET desktop development
- Windows App SDK / WinUI 関連 component

不要な workload を『念のため』全部入れる方針にはしません。

## Keyboard remapping

kanata と ChgKey は同一物として扱いません。

- ChgKey: scan-code / registry ベースの persistent remap
- kanata: runtime / layer / advanced remap

現行の実際の key mapping 自体は、実機から確認して別途 config として保存します。

## Verify

```powershell
.\platforms\windows-11\verify.ps1
```

package/tool が無い場合は FAIL、login / licensing / manual mapping のような対話状態は WARN として扱います。

## Capture the actual machine

desired state に書き漏らしたアプリを探すため、実機から snapshot を取れます。

```powershell
.\platforms\windows-11\snapshot.ps1
```

取得対象:

- WinGet export / list
- AppX/MSIX package list
- uninstall registry inventory
- selected CLI versions
- Windows build / architecture

snapshot は actual machine evidence であり、出てきた package を自動的に desired state へ昇格させません。

snapshot には username や install path が混ざる可能性があるため、commit 前に必ず review します。

## Authentication / licensing

次は自動化しません。

- GitHub
- ChatGPT
- Discord
- Linear
- Slack
- Teams
- Adobe Creative Cloud
- Steinberg
- Google/Logitech account state

password / API key / token / cookie / license secret / private key は repository に保存しません。

## Update

WinGet-managed applications:

```powershell
winget upgrade --all
```

ただし Adobe child apps と Cubase はそれぞれ Creative Cloud / Steinberg Download Assistant 側の update state も確認します。

## References

- WinGet: https://learn.microsoft.com/windows/package-manager/winget/
- PowerToys install: https://learn.microsoft.com/windows/powertoys/install
- ChatGPT Windows deployment: https://developers.openai.com/docs/enterprise/windows-deployment
- Steinberg Download Assistant: https://www.steinberg.net/sda
- Change Key: https://forest.watch.impress.co.jp/library/software/changekey/
- Warp Windows install: https://docs.warp.dev/getting-started/quickstart/installation-and-setup
