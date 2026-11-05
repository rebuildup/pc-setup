# Windows SSH 接続 PoC

継続利用のための専用OS起動管理は[task手順](TASK.md)を参照。通常のStartは引き続き一接続の前面debug方式であり、boot時起動の証明にはしない。

既存 VPN 上で Windows のローカル管理者へ専用公開鍵で接続できることだけを検証する。既存 `sshd` service、`C:\ProgramData\ssh`、既存鍵、DefaultShell、VPN 登録、WSL、Infisical は変更しない。恒久 service 化や開発ノード登録は接続検証後の別工程とする。

今回の候補は UUU / `100.118.123.62`、TCP `22222`。接続元は操作者の VPN IPv4 **1 個**を明示する。VPN の通信認可も接続元→対象の当該 port だけに制限する。Windows Firewall の追加ルールだけでは、既存の広い許可ルールを狭められない。ただし daemon 自体は指定 VPN address のみに bind する。

## 前提と選択理由

- Windows 上で対象ローカル管理者として管理者権限の **PowerShell 7.3 以降 (`pwsh`)** を開く。`$env:USERNAME` と `whoami /user` で主体を確認する。Microsoft Entra / domain account、別管理者による RunAs、非管理者ユーザーはこの PoC の対象外。
- Tailscale は接続済みとする。login-server や既存登録を変更しない。
- Microsoft OpenSSH Server optional capability が必要。未導入時だけ、管理者 PowerShell で `Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0` を実行する。これは OS 機能導入であり標準 `sshd` service 等を追加し得る。標準 service を start/enable する手順は実行しない。既存機能の再導入や package の置換はしない。
- script は標準インストール先 `%WINDIR%\System32\OpenSSH` の Microsoft binary を使用する。

初回接続に限定するため、公式 troubleshooting が説明する管理者対話 `sshd -d` を使う。専用名 Windows service の OS 同梱版での互換性は未確認であり、既存標準 service の採用・変更もしない。debug mode は **1 接続で終了**する。Mac 側の `ssh-keyscan` も 1 接続を消費するため、その後の SSH verify 前に Start を再実行する。実機で管理者対話実行が対象版の認証に対応しない場合は停止して調査し、暗黙の service 切替や認証方式の緩和はしない。

## 準備と実行

Mac 側で今回専用の Ed25519 user key を生成し、**公開鍵 `.pub` だけ**を Windows に渡す。既存管理鍵や秘密鍵を渡さない。repository のこのフォルダーを Windows に用意し、管理者 `pwsh` から次を実行する。`ControllerAddress` と公開鍵 path は実際の値に置き換える。

```powershell
cd C:\path\to\pc-setup
$controller = '100.x.y.z' # Mac の tailscale ip -4 の結果
$user = $env:USERNAME.ToLowerInvariant()
./platforms/windows-11/ssh-poc/ssh-poc.ps1 -Action Bootstrap `
  -UserName $user -ListenAddress '100.118.123.62' `
  -ControllerAddress $controller -PublicKeyPath "$HOME\Downloads\windows-poc.pub"
./platforms/windows-11/ssh-poc/ssh-poc.ps1 -Action Verify
./platforms/windows-11/ssh-poc/ssh-poc.ps1 -Action Start
```

Bootstrap は専用 `%ProgramData%\pc-setup-ssh-poc` に config、authorized_keys、新規 device-local host key と所有権 manifest を作る。ACL は SYSTEM と BUILTIN\Administrators の FullControl のみに限定する。専用 config には標準 config の `Match Group administrators` を読み込まないため、管理者も共有 `administrators_authorized_keys` を参照しない。公開鍵認証のみ、指定 user のみ、agent/TCP forwarding 無効。専用 user key はこの Windows アカウントの権限で任意コマンドを実行できるため、PoC 終了後に undo する。

同じ引数の Bootstrap 再実行は照合のみ。異なる引数、既存専用 path、foreign firewall rule、ファイル hash/ACL の変更、不明ファイル、reparse point は拒否する。上書き修復しない。構築途中の失敗は証拠を残し、所有権を証明できない partial state を自動削除しない。

Verify の出力にある `user@IP:22222` と host key `SHA256:...` を Windows 画面から別経路で操作者に伝える。Mac 側はこの fingerprint と取得した host public key を照合してから専用 known_hosts に pin する。fingerprint を未確認の scan 出力だけから承認しない。

1. Windows で Start を起動。
2. Mac で host key を scan・fingerprint 照合・pin。
3. **Windows で Start を再実行**。
4. Mac で `StrictHostKeyChecking=yes`、専用 user key / known_hosts、port 22222 で nonce echo を検証。
5. 接続ごとに必要なら Start を再実行。誤った鍵、別 user、password 認証での拒否も確認する。これらも接続を消費する。

`-d` が接続後に前面 session を保持することがある。コマンドと接続を終えて Ctrl+C で listener を停止する。自動起動はなく、再起動後も Start を明示実行する。

## 検証と撤去

別の管理者 `pwsh` で次を観測する。Start 稼働中の listener が対象 VPN IP / port のみか、PID が今回の専用 `-f` config を使うかを確認する。Verify は資源/config/ACL/firewall と `sshd -t` の検査であり、接続成立の証明ではない。

```powershell
Get-NetTCPConnection -State Listen -LocalPort 22222
Get-CimInstance Win32_Process -Filter "Name='sshd.exe'" | Select-Object ProcessId, CommandLine
Get-NetFirewallRule -Name pc-setup-ssh-poc-22222 | Get-NetFirewallAddressFilter
```

Ctrl+C、SSH session 終了を確認してから撤去する。port の listener が残る場合は拒否し、無関係な process を kill しない。

```powershell
./platforms/windows-11/ssh-poc/ssh-poc.ps1 -Action Undo
```

Undo は所有権・hash・ACL・firewall scope を照合して今回専用 firewall rule と既知ファイルだけを削除する。SSH capability、標準 service、既存設定、受領した公開鍵ファイルは維持する。root と専用 firewall が共に不在なら再 Undo は何もしない。root 不在で firewall だけ残る場合は拒否し、削除対象を探索しない。manifest 前の失敗や drift は手動調査対象。秘密 host key は Git、dotfiles `home/`、共有 storage へコピーしない。Mac 側の今回専用接続設定・key・known_hosts の撤去は Mac 側手順で行う。

## 保証範囲と一次資料

入力境界・専用 config 生成・file hash と foreign file 拒否は `scripts/test-windows-ssh-poc.ps1` で実行検査する。PowerShell parser と `scripts/ci.sh` は macOS で実行可能。**Windows 実機の ACL / Firewall / OpenSSH version / 対話実行の認証 / VPN 到達 / undo は未検証**。これらの model gap は実機チェックと nonce echo を完了するまで残る。成功した接続と拒否試験の結果を機密値なしで issue #130 に記録してから次工程を判断する。

2026-10-24 確認:

- [Microsoft: OpenSSH installation](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_install_firstuse): optional capability の導入方法。
- [Microsoft: Windows server configuration](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh-server-configuration): `-f`、AllowUsers、管理者 authorized_keys の既定と Windows の制約。
- [Win32-OpenSSH: troubleshooting](https://github.com/PowerShell/Win32-OpenSSH/wiki/Troubleshooting-Steps): 管理者対話 `sshd -d`。
- [Win32-OpenSSH: file permissions](https://github.com/PowerShell/Win32-OpenSSH/wiki/Security-protection-of-various-files-in-win32-openssh): host key / authorized key の owner と ACL。
