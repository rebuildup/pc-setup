# Kanata on macOS

macOSでは低レイヤーの1:1大西配列を `hidutil` が所有し、KanataはF1のOnishi/QWERTY切替、Caps extra layer等のstateful customizationを所有する。

## Version pair

このreleaseでは次をcompatibility pairとして固定する。

```text
Kanata 1.12.0
Karabiner-DriverKit-VirtualHIDDevice 6.2.0
```

Kanata 1.12.0のmacOS backendはDriverKit 6.2.0のIPCを前提にしているため、片方だけを更新しない。

## Config source

canonical configは `rebuildup/key-map-kanata`。

pc-setupは実機smoke test済みcommitをpinしてsystem-readable locationへコピーする。

```text
key-map-kanata ref:
583f54d196b30ca00d4c5a8142514409c9757aef

installed config:
/usr/local/etc/pc-setup/kanata/kanata-us.kbd
```

## Install

```bash
./platforms/macos/kanata/install-kanata.sh
```

installerは次を行う。

- Kanata 1.12.0を要求する
- DriverKit 6.2.0が未導入なら公式pkgから導入する
- DriverKit system extensionをactivateする
- VirtualHID daemonをsystem LaunchDaemonとして登録する
- Kanataをroot system LaunchDaemonとして登録する
- key-map-kanataのpin済みconfigをroot-readable pathへ配置する

Kanata binaryはHomebrewのsymlinkではなく、その時点のreal pathをLaunchDaemonへ記録する。Homebrew updateでreal pathが変わった場合はinstallerを再実行し、macOS TCC permissionも新しい実体へ再付与する。

## Required manual permissions

LaunchDaemon化してもTCC permissionは自動付与できない。

installerが表示するexact Kanata binaryを次の両方でONにする。

- System Settings > Privacy & Security > Accessibility
- System Settings > Privacy & Security > Input Monitoring

DriverKit system extensionは次でONにする。

- System Settings > General > Login Items & Extensions > Driver Extensions

## Boot / login boundary

VirtualHID daemon、Kanata、hidutil baselineはいずれもsystem LaunchDaemonとしてmacOS起動時に開始する。

そのためFileVaultが無効で通常のmacOS loginwindowが表示される構成では、user login前から動作させられる。

ただしFileVault有効時のcold boot最初のpassword画面はmacOS Preboot環境であり、macOSのlaunchdが起動する前にdisk unlockを行う。この画面へhidutil/Kanataの設定を届けることはできない。

```bash
fdesetup status
```

FileVaultをkeyboard customizationのためだけに無効化することは推奨しない。

## Verify

```bash
./platforms/macos/kanata/verify.sh
```

個別確認:

```bash
sudo launchctl print system/org.pqrs.Karabiner-VirtualHIDDevice-Daemon
sudo launchctl print system/dev.rebuildup.pc-setup.kanata
sudo tail -n 200 /var/log/pc-setup-kanata.log
```
