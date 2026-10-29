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

`wsl.conf` でこのdistroのautomount/interop/Windows PATH追加を無効にし、systemdとdefault user=workerを設定する。旧Verifyは共有binfmt登録の不在を要求するため、登録が残る現行WSLでは失敗する。この判定をinterop実行権限の証明に使わず、下記v2で設定・所有ファイル/hash・Windows driveの `/mnt/<letter>` mount不在・非sudo user・専用unit/listener/host fingerprintを検査する。WSLg/driver等の補助mountの完全不在や、他worker/管理socketの拒否を証明するものではない。SSH loginのPATHと非root UIDはMacの実接続で別検証する。

## 既存setupを保持する検証v2

実機でv2の子processが `CommonApplicationData` を取得できず、再起動前検査が失敗した。v2 stageと失敗記録を保持し、再試行には後述のv3を使う。

Configure/対象distroのRestartまで完了したstageが対象。旧4 source・manifest・Verify失敗markerは変更しない。`verification-v2/runtime.ps1` は別のAdmin所有stage `%ProgramData%/pc-setup-worker-ssh-verification-v2-<UUID>` を作り、元setupのmanifest/guest source hashと新verifier source/manifest hashを分離して保持する。元Linux manifestの`source_hash`を新verifierへ付け替えない。初回VerifyV2/HoldV2のCreateNew marker/resultと後日のread-only再検査を分ける。

```powershell
. ./platforms/windows-11/worker/ssh/verification-v2/runtime.ps1
$null = Initialize-WorkerVerificationV2 $instance
$proof = Invoke-WorkerVerificationV2 $instance $password
$hold = Start-WorkerSshHoldV2 $instance $password
. ./platforms/windows-11/worker/ssh/verification-v2/gateway.ps1
$gateway = Initialize-WorkerGatewayV2 $instance $password '<現在のWindows VPN IPv4>' '<現在のMac VPN IPv4>'
Test-WorkerGatewayV2 $instance $password
```

guest v2はLinux設定を変更しない。現在addressからtemplateを展開した内容とroot所有privateなsshd.runtimeの完全一致、private host keyから導出した公開鍵と保存public keyの一致を確認する。ファイル検査だけでは稼働中daemonが既に読み込んだ設定を証明できず、提示host keyは後続のpin付きSSH handshakeで確認する。`interop_config_disabled=true`はwsl.confの実内容、`binfmt_registration=present|absent`は共有登録の観測であり、全経路でWindows PE実行を拒否できるという意味ではない。2026-10-27の専用worker UID1000によるMicrosoft署名whoami.exeの実測では、通常環境・env-iとも`UtilAcceptVsock / accept4 failed 110`で失敗した。同一digestのコピーは同じWindows標準SIDからUNC経由で実行できた。これは当該経路の実測であり、timeoutの原因や完全な隔離の証明ではない。WSLのinterop/automount設定は封じ込め境界として扱わず、Windows標準SID/ACLとLinux非sudo権限を基礎にする。

gateway v2は別manifest `%ProgramData%/pc-setup-wsl-gateway-v2-<UUID>` を使用し、v1 gatewayを移行・adoptしない。v1 sourceは保持し、共有helperのhashもv2 manifestにbindする。初回proof hash、同じSID/instance/hostpin、新verifier hash、foreground holdのPID/owner/path/argv/start timeを検査する。portproxy公開直前にcredentialed guest再検査・現在VPN/route/ActiveStore policy・二つの実効rule・foreign mapping/listener不在を再検査する。途中失敗のpending/rulesは残して自動retryしない。

これは認証済みcontroller一台に限定したPoC。固定22224はWSL一台専用であり、複数WSLのport割当、常用join/active、再起動/idle後の復帰は未達。v2はIP変更の自動repairや常駐taskを追加しない。IP変更時は公開中mappingを無断で更新せず、明示的な所有資源の再調整を行う。SSH nonce、SSH login内からのUID/PATH/Windows PE実行、Herdr、個別Codex認証は後続の実測で確認する。

一次資料: [Ubuntuの共有binfmt登録](https://ubuntu.com/wsl/docs/stable/explanation/binfmt/)、[Microsoft WSLのsecurity boundary](https://github.com/microsoft/WSL/blob/master/doc/docs/technical-documentation/security.md)。

## 検証v3: 共通データパスの伝達

v3はv1 setupとv2 stageを保持した別のverification stageを作り、検査済みのWindows共通データdirectoryだけを、環境をクリアした専用標準ユーザーの子processへ `ProgramData` として渡す。秘密情報や親の任意環境変数は継承しない。v2のsource/manifest/失敗記録は変更せず、v3 sourceとproofをそれぞれ別hashに結合する。

```powershell
. ./platforms/windows-11/worker/ssh/verification-v3/runtime.ps1
$null = Initialize-WorkerVerificationV3 $instance
$proof = Invoke-WorkerVerificationV3 $instance $password
$hold = Start-WorkerSshHoldV3 $instance $password
. ./platforms/windows-11/worker/ssh/verification-v3/gateway.ps1
$gateway = Initialize-WorkerGatewayV3 $instance $password '<現在のWindows VPN IPv4>' '<現在のMac VPN IPv4>'
Test-WorkerGatewayV3 $instance $password
```

v3 gatewayはv1/v2の所有状態をadoptせず、別manifestを使用する。上記は再現手順であり実機成功の証拠ではない。serviceの稼働を保持するだけで再起動・idle後の自動復帰は保証しない。

## V3 gatewayの復旧とIP追従

`repair-v1/runtime.ps1` は既存V3のVerify/Hold証跡を変更せず、独立したAdmin所有manifestを作る。初回修復時は専用workerのWindowsアカウントとしてforeground WSL holdを起動し、資格情報は呼び出し元から受けるin-memory `SecureString`だけを使う。credentialed Verifyで既存host fingerprintを再確認し、現在のWSL IPv4が同じ仮想subnetに属することを確かめる。portproxyは既存のV3所有mappingと一致した場合に限って現在IPへ更新する。Firewall rule、通常のsshd、他WSL、既存V3証跡は変更しない。

```powershell
. ./platforms/windows-11/worker/ssh/repair-v1/runtime.ps1
$repair = Initialize-WorkerGatewayRepairV1 $instance
$repair = Invoke-WorkerGatewayRepairV1 $instance $password
```

`$password`はdotfiles側のprocess-scoped Infisical wrapperから渡し、terminal、argv、task definition、manifest、logへ出さない。毎回の実行は既存holdのPID/SID/path/argv/start timeを照合し、消失していれば同じ専用workerだけを再起動する。Admin所有journalには起動意図を先に記録し、起動後の完全なprocess identityを別記録へ保存する。中断後はその記録または一意に対応する起動意図があるprocessだけを再開し、曖昧な場合は停止して人の確認を求める。mapping更新前のjournalとmanifestを照合し、失敗後もmanifestまたは最新記録済みの新mappingだけを受け入れる。repair manifestはV3 base manifest hashとhost pinを保持し、V3の履歴証跡を上書きしない。V3の古いhold receiptに依存しない鍵stage後検査には、`Test-WorkerKeyStageGatewayRepairV1 $instance $operation $password`を使う。これは明示実行用の修復stageであり、Windows再ログイン時の自動起動・常時monitor taskは別途実機検証が必要である。

## 公開鍵の追加・失効

初回VerifyV3が成功した後の公開鍵変更は、`key-stage/runtime.ps1` の世代付きkey ledgerを使う。既存のsetup manifest、v3 verifier manifest、Linuxのroot所有setup manifestは書き換えず、鍵stageごとにsource/hash/ACL・対象SID・前世代のVerifyAfter proofをbindする。`Add` は既存公開鍵を残して追加し、`Revoke` は同じ公開鍵fingerprintの鍵だけを除く。失効済みfingerprintの再追加、重複鍵、古いgeneration、既存attemptの再利用を拒否する。

```powershell
. ./platforms/windows-11/worker/ssh/verification-v3/runtime.ps1
. ./platforms/windows-11/worker/ssh/key-stage/runtime.ps1
$operation = [guid]::NewGuid().ToString()
$keyStage = Initialize-WorkerKeyStage $instance $operation $password Add $publicKey
$before = Invoke-WorkerKeyStage $instance $operation $password VerifyBefore
$update = Invoke-WorkerKeyStage $instance $operation $password Update
$after = Invoke-WorkerKeyStage $instance $operation $password VerifyAfter
```

実行はnative x64管理者PowerShell 7.3+から行い、`$password` は既に承認されたprocess-scoped credential helperが返すmemory `SecureString` とする。公開鍵だけを `Add` し、秘密鍵・passwordをargv/env/file/terminalへ出さない。`VerifyBefore` は現在のauthorized_keys・hostkey・service/listenerとbaseline manifestを照合する。`Update` は前検査resultを必須とし、guest内の排他lock、before/after hash、一時fileと同一filesystemのrenameでauthorized_keysを置換する。失敗時はmarker/partial stateを残し、自動rollback・再試行をしない。結果不明なら新しいoperationを開始せず、保存resultと実guest状態を確認する。

後世代の変更には直前operationの `VerifyAfter` proofを `PreviousOperationId` として渡す。Add後のgateway検査には `key-stage/runtime.ps1` の `Test-WorkerKeyStageGateway` を使う。旧v3 gateway検査は初期authorized_keys hashを検査するため、key-stage更新後の再検査・修復には使用しない。SSH clientからの鍵認証成功はこのstageとは別に実接続で確認する。

## VPN限定gateway

```powershell
. ./platforms/windows-11/worker/ssh/gateway.ps1
$gateway = Initialize-WorkerGateway $instance $guest '<現在のWindows VPN IPv4>' '<現在のMac VPN IPv4>'
Test-WorkerGateway $instance $guest
# 後日の読取再検査はmarker/resultを上書きしない。
$live = Invoke-WorkerSshStage $instance $password Verify -ReadOnly
Repair-WorkerGateway $instance $live
```

既存IP HelperがRunning、VPNの現在属性が一致していることを要求する。FirewallのActiveStoreで三profileがEnabled、AllowInboundRules/AllowLocalFirewallRulesが明示True、VPN interfaceがDisabledInterfaceAliasesに含まれないことを確認する。作成した二つのlocal ruleもActiveStoreのscopeとPrimaryStatus/Enforcedを照合する。無効・未確定のGPO/local mergeをglobal policy変更で緩和しない。targetは接続中のWSL仮想NICのprivate subnet内で、Windows自身のinterfaceではないIPv4に限る。全portproxy familyの同portを調べ、foreign mapping/listener/rule名を拒否する。

今回のVPN IPv4:22224だけをv4tov4でguest IPv4:22224へ転送する。controllerだけのAllowと、それ以外のIPv4 rangeのBlockを同じIP/portに限定して作る。他のbroad Allowによる露出を防ぐためのBlockであり、他port/既存22222/標準sshdを変更しない。実効Firewallと否定接続は別途実測する。共有gateway方式のためWSL独自VPN identityや隣接workerからの完全なnetwork分離を主張しない。

gatewayは別のAdmin所有manifestで所有mapping/rules/guest hostpin/SSH stage hashを追跡する。Repairはlive guest verificationと同一pinを要求し、旧mapping一致を確認した上で今回のmappingだけnetsh setする。before journalと新manifestのatomic replaceでIP変更を記録し、途中失敗はpartialのまま止める。foreign mappingを削除・adoptしない。

## 稼働時間と未達条件

systemdのserviceだけではWSL自体の稼働を保持できない。static portproxyも停止したdistroを起動しない。初期PoCは同じ標準SID本人/profileのnative foreground wsl.exeを一回だけ起動し、完全名distroの `worker` / `env -i` / `sleep infinity` を維持する。owner SID・native path・固定argv・PID/start timeを記録する。起動後はSecureStringをdisposeでき、provider sessionや親readerへの継続依存を作らない。自動停止せず、停止が必要なら記録したPIDだけでなくowner/path/argv/start timeを再照合し、この一回の所有processだけを対象にする。

このPoCで「常時接続可能」とは表示しない。SID本人のOS managed lifetime・GUI login後の復帰・reboot・idle後再接続は別source/gateで検証する。初期SSH nonceと一時foreground保持に成功してもこれらは未達のままである。guest lifecycle設計が確定するまで、無断でTask/S4U/password保存を追加しない。

停止・撤去を疎通直後に自動実行しない。撤去が必要な場合は、所有manifestと実mapping/rule/hostpinを照合してこのIP:portのmappingと今回二つのruleだけを対象にする。guest側も専用unitを停止してからroot-owned資源を別レビューする。既存Ubuntu・VPN登録・共有IP Helper・他worker・標準SSHの資源を削除しない。

検証: `scripts/test-windows-worker-ssh.ps1`、Bash構文、ShellCheck、`scripts/ci.sh`。credentialed OS実行/apt/service/guest restart/Firewall/nonceは実機証拠が必要。stdout取得は既存adapter同様に終了後size検査で、streamingの厳密なmemory上限ではない。

一次資料（2026-10-26確認）: [WSL distro設定](https://learn.microsoft.com/windows/wsl/wsl-config)、[WSL systemdと稼働時間](https://learn.microsoft.com/windows/wsl/systemd)、[netsh portproxy](https://learn.microsoft.com/windows-server/administration/windows-commands/netsh-interface)、[Windows Firewall rule](https://learn.microsoft.com/powershell/module/netsecurity/new-netfirewallrule)、[Ubuntu OpenSSH](https://ubuntu.com/server/docs/how-to/security/openssh-server/)。
