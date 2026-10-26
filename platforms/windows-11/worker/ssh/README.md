# 専用WSLの公開鍵SSHとWindows gateway

Issue #142。新しいstandard Windows SIDに登録されたWSLだけを対象にする。Windows gatewayのVPN addressとWSLのinstance/hostkey/Linux userを分離し、WSL内VPN・Machine Identityを追加しない。source検査・レビューと実機適用、SSH/Herdrの疎通証拠は別に記録する。

## 準備と段階適用

native x64管理者PowerShell 7.3+で `runtime.ps1` を読み込む。credentialは既にレビューされたprovider手順からmemory SecureStringだけで渡す。秘密鍵やMac/Windowsの認証cacheをWSLへ配布しない。以下は手順であり実機成功の証拠ではない。

```powershell
. ./platforms/windows-11/worker/ssh/runtime.ps1
$instance = '<登録済みworker instance UUID>'
$publicKey = '<このWSL専用のMac Ed25519公開鍵一行>'
$null = Initialize-WorkerSshStage $instance $publicKey
$inspect = Invoke-WorkerSshStage $instance $password Inspect
# Inspectで既存server/user/home/group/policy/専用資源が全て不存在であることをレビュー。
$configured = Invoke-WorkerSshStage $instance $password Configure $inspect.Guest.wsl_conf_hash
# 既存Ubuntuや他distroを止めず、この新distroだけを明示停止する。
Invoke-WorkerSshStage $instance $password Restart
$guest = Invoke-WorkerSshStage $instance $password Verify
$hold = Start-WorkerSshHold $instance $password
```

Windows stageは `%ProgramData%/pc-setup-worker-ssh-<UUID>`。元worker/WSL manifest・SID・registry・profile・source/hash/ACLを照合し、当該workerにReadAndExecute、Administrators/SYSTEMにFullControlだけを許可する。Inspect/Configure/Restart/初回VerifyはそれぞれCreateNew markerと非秘密resultを保存する。失敗partial・markerは消さず、source driftやforeign資源を上書きしない。

guest scriptは固定sourceをstdinで、専用Windows本人から完全名distroの `root` / `env -i` / 非login bashに渡す。初期OS設定だけをrootで行い、常用SSHは新しい `worker`（非sudo・locked password・公開鍵のみ）に限定する。元のwsl.confは先にhashを確認しprivate backupを残す。OpenSSH ServerだけをUbuntu公式repositoryから導入し、temporary policy-rc.dでvendor port22の自動起動を防ぐ。vendor service/socketは新規distro内でdisableし、専用systemd unitだけをenableする。

host秘密鍵・manifest・設定・private logはroot所有0700の専用directoryに置く。sshdは対象userの権限でauthorized_keysを読むため、公開鍵だけは別のroot所有0755 directory/0644 fileに分離する。workerは公開鍵を読めるが変更できない。固有hostkeyはguest内で生成し秘密部分を外へ出さない。unitはeth0の現在IPv4だけに22224をbindし、0.0.0.0/IPv6/port22へlistenしない。

`wsl.conf` でこのdistroのautomount/interop/Windows PATH追加を無効にし、systemdとdefault user=workerを設定する。Verifyは実interop不在、Windows driveの `/mnt/<letter>` mount不在、非sudo user、所有ファイル/hash、専用unit、guest listenerと同一host fingerprintを検査する。WSLg/driver等の補助mountの完全不在や、他worker/管理socketの拒否を証明するものではない。SSH loginのPATHと非root UIDはMacの実接続で別検証する。

## VPN限定gateway

```powershell
. ./platforms/windows-11/worker/ssh/gateway.ps1
$gateway = Initialize-WorkerGateway $instance $guest '<現在のWindows VPN IPv4>' '<現在のMac VPN IPv4>'
Test-WorkerGateway $instance $guest
# 後日の読取再検査はmarker/resultを上書きしない。
$live = Invoke-WorkerSshStage $instance $password Verify -ReadOnly
Repair-WorkerGateway $instance $live
```

既存IP HelperがRunning、Windows Firewall全profileがEnabled、VPNの現在属性が一致していることを要求し、global service/policyを変更しない。targetは接続中のWSL仮想NICのprivate subnet内で、Windows自身のinterfaceではないIPv4に限る。全portproxy familyの同portを調べ、foreign mapping/listener/rule名を拒否する。

今回のVPN IPv4:22224だけをv4tov4でguest IPv4:22224へ転送する。controllerだけのAllowと、それ以外のIPv4 rangeのBlockを同じIP/portに限定して作る。他のbroad Allowによる露出を防ぐためのBlockであり、他port/既存22222/標準sshdを変更しない。実効Firewallと否定接続は別途実測する。共有gateway方式のためWSL独自VPN identityや隣接workerからの完全なnetwork分離を主張しない。

gatewayは別のAdmin所有manifestで所有mapping/rules/guest hostpin/SSH stage hashを追跡する。Repairはlive guest verificationと同一pinを要求し、旧mapping一致を確認した上で今回のmappingだけnetsh setする。before journalと新manifestのatomic replaceでIP変更を記録し、途中失敗はpartialのまま止める。foreign mappingを削除・adoptしない。

## 稼働時間と未達条件

systemdのserviceだけではWSL自体の稼働を保持できない。static portproxyも停止したdistroを起動しない。初期PoCは同じ標準SID本人/profileのnative foreground wsl.exeを一回だけ起動し、完全名distroの `worker` / `env -i` / `sleep infinity` を維持する。owner SID・native path・固定argv・PID/start timeを記録する。起動後はSecureStringをdisposeでき、provider sessionや親readerへの継続依存を作らない。自動停止せず、停止が必要なら記録したPIDだけでなくowner/path/argv/start timeを再照合し、この一回の所有processだけを対象にする。

このPoCで「常時接続可能」とは表示しない。SID本人のOS managed lifetime・GUI login後の復帰・reboot・idle後再接続は別source/gateで検証する。初期SSH nonceと一時foreground保持に成功してもこれらは未達のままである。guest lifecycle設計が確定するまで、無断でTask/S4U/password保存を追加しない。

停止・撤去を疎通直後に自動実行しない。撤去が必要な場合は、所有manifestと実mapping/rule/hostpinを照合してこのIP:portのmappingと今回二つのruleだけを対象にする。guest側も専用unitを停止してからroot-owned資源を別レビューする。既存Ubuntu・VPN登録・共有IP Helper・他worker・標準SSHの資源を削除しない。

検証: `scripts/test-windows-worker-ssh.ps1`、Bash構文、ShellCheck、`scripts/ci.sh`。credentialed OS実行/apt/service/guest restart/Firewall/nonceは実機証拠が必要。stdout取得は既存adapter同様に終了後size検査で、streamingの厳密なmemory上限ではない。

一次資料（2026-10-26確認）: [WSL distro設定](https://learn.microsoft.com/windows/wsl/wsl-config)、[WSL systemdと稼働時間](https://learn.microsoft.com/windows/wsl/systemd)、[netsh portproxy](https://learn.microsoft.com/windows-server/administration/windows-commands/netsh-interface)、[Windows Firewall rule](https://learn.microsoft.com/powershell/module/netsecurity/new-netfirewallrule)、[Ubuntu OpenSSH](https://ubuntu.com/server/docs/how-to/security/openssh-server/)。
