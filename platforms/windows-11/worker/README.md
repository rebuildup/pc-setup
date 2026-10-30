# Windows標準ユーザーごとのWSL worker準備

[Issue #134](https://github.com/rebuildup/pc-setup/issues/134) / [ADR-0016](../../../docs/adr/ADR-0016.md)。現段階はOS account・所有権・native process境界のsource候補であり、worker登録完了ではない。

## 現在の実行gate

実行対象は `Plan` / `Capability` / sourceテストのみ。`Provision` / `PrepareProfile` / credentialed `Probe` は、OS passwordの生成・operator限定保管・process-scoped配送を統合担当と合意し、実機実行を承認してから使う。passwordをチャット・argv・環境変数・ログ・manifest・平文ファイルへ置かない。Infisicalの値を平文引数へ渡すwrapperは作らない。

WindowsのPowerShell **7.3以上・64bit** が必要。変更操作とVerifyには管理者昇格が必要。既存basic/Ubuntu/default distro/`.wslconfig`/SSH/管理鍵/VPSは変更しない。

```powershell
$entry = './platforms/windows-11/worker/worker.ps1'
$instance = [guid]::NewGuid().ToString('D')
& $entry -Action Plan -InstanceId $instance -MemoryGB 4 -Processors 2
& $entry -Action Capability
./scripts/test-windows-worker.ps1
```

Capabilityは現在tokenで小さい子PowerShellを起動し、canaryとPATHの非継承、nativeログオン/profile APIの存在だけを確認する。account作成・profile load・WSL importはしない。`WorkerLogonTested/ProfileCreationTested/CrossUserDenialTested=false` を成功出力にも残す。PowerShellが追加する機械共通PSHOMEは許可する。

## 後段で承認を得て行う手順

1. [Canonicalの手順](https://ubuntu.com/wsl/docs/latest/howto/install-ubuntu-wsl2/)から公式fresh Ubuntu WSL imageを取得する。releaseのSHA256と署名の由来を独立確認し、URL/hashを記録する。許可hostは `releases.ubuntu.com` / `cloud-images.ubuntu.com`、HTTPSのみ。自己計算hashとURLだけを公式由来proofとしない。既存Ubuntu export/鍵/login/cacheを複製しない。
2. Windows RAM/diskを再測定する。既定予算4GiB/2CPU/swap1GiB、入力範囲2..8GiB/1..4CPU。各作成時に要求memory+2GiB以上のavailable RAMと保存先NTFSの空き20GiBが必要。二台目も再測定する。これは予約/hard quotaではない。過去の31.7GiB RAM/C:約124GiB空きsnapshotをcurrent proofにしない。
3. 下記の `$image/$officialUrl/$officialSha256` は検証済み入力。passwordはSecureStringでprocess memory内だけに受け、保管配送が未合意の間は実行しない。

```powershell
# 次gateの承認後だけ実行する。
$password = Read-Host 'New worker Windows password' -AsSecureString
try {
    & $entry -Action Provision -InstanceId $instance -Password $password `
      -ImagePath $image -SourceUri $officialUrl -Sha256 $officialSha256
    & $entry -Action PrepareProfile -InstanceId $instance -Password $password
    & $entry -Action Verify -InstanceId $instance
} finally { $password.Dispose(); Remove-Variable password }
```

Provisionは新規standard local user `pcw-<UUID先頭12桁>` を作る。local Users以外のgroup所属は拒否する。短縮名衝突もforeignとして拒否し、別accountへ黙って切り替えない。再実行はSID/description/ACL/hash/source/budget照合だけでpasswordをresetしない。

Windows accountのDescriptionは専用plan属性 `AccountDescription=pcw/v1/<完全UUID>`（43文字）で、[New-LocalUserの上限48文字](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.localaccounts/new-localuser?view=powershell-5.1#-description)以内にする。manifestのOwner namespace `pc-setup/windows-worker/v1` と分離し、作成・照合に同じ属性を使う。旧namespaceとUUIDを連結したDescriptionや、属性のない旧manifestはadopt/上書きしない。

manifestと固定child probeは `%ProgramData%\pc-setup-worker-<UUID>`、dataは `%ProgramData%\pc-setup-worker-data-<UUID>`。ownerはAdministrators、SYSTEM/AdministratorsのみFullControl。workerはmetadataへReadAndExecute、dataへModify。他worker/Users全体へは許可しない。foreign path/reparse point/SID/group/ACL/hash drift/不明metadata fileを拒否する。途中失敗は保持して停止し、adopt/上書き修復/自動削除しない。

PrepareProfileは.NETのSecureString credentialと`LoadUserProfile=true`でそのuser自身のprofileをロードし、新規`.wslconfig`だけを作る。同一内容の再実行は照合、異なる既存file/reparse pointは拒否。管理者token/controller envを渡さず、stdinも閉じる。worker自身のregistry inventoryを先に調べ、アクセス拒否を空と扱わない。失敗時は管理者fallbackしない。

## 実機の拒否proof

二つの専用userを承認済み手順で準備後、各credentialでProbeを実行する。`$managementKeyPath` は実在するhost管理鍵path、`$peerInstance` は別の所有manifestを持つUUID。秘密値は渡さず、pathの不用意な共有も避ける。

```powershell
# 未実行。鍵の内容は読まず、file handleのopenだけを検査する。
$password = Read-Host 'Worker Windows password' -AsSecureString
try {
    & $entry -Action Probe -InstanceId $instance -Password $password `
      -ProtectedFile $managementKeyPath -PeerInstanceId $peerInstance
} finally { $password.Dispose(); Remove-Variable password }
```

PASSにはSID一致、標準token、canary不在、管理鍵file open拒否、別worker directory列挙拒否が必要。不在/IO errorは拒否proofにせず失敗させる。読める場合は他人のACLを黙って変えず停止する。

管理者Verifyだけでは未ロードworker HKCUを検査できず、foreign distro不在を証明しない。credentialed childが自分のHKCUを検査する。native profile/processとクロスuser拒否、WSL network/limitsの実効性はpure testsと別に記録する。

## 次のgateと禁止操作

`wsl-worker.ps1` は[Microsoftのimport手順](https://learn.microsoft.com/windows/wsl/use-custom-distro)に沿う後続stage。元のmanifest/probeは維持し、別の `%ProgramData%\pc-setup-worker-wsl-<UUID>` に管理者所有・当該worker読取のみのsource/image/manifestを固定する。異なるsource/ACL/hash/部分状態は上書きしない。

review済みsourceとpassword配送を固定したnative x64管理者controllerから、次の順で呼ぶ。passwordはSecureString memory内だけ。例は手順であり実機成功の証拠ではない。

```powershell
$wslEntry = './platforms/windows-11/worker/wsl-worker.ps1'
& $wslEntry -Action Prepare -InstanceId $instance -ImagePath $image
& $wslEntry -Action Inventory -InstanceId $instance -Password $password `
    -ProtectedFile $managementKeyPath -ProtectedDirectory $operatorPrivateDirectory
# Inventoryが空で、直前の容量/image検査が成功した場合だけ、一度実行する。
& $wslEntry -Action Import -InstanceId $instance -Password $password
& $wslEntry -Action Verify -InstanceId $instance -Password $password
```

Inventoryは専用標準user本人のHKCU、SID、native profile、`.wslconfig`、canary不在を検査する。parentは既存の操作者所有file/directoryの存在・型・ownerとreparse不在を確認し、childがfile handle openとdirectory列挙だけを試す。UnauthorizedAccessExceptionだけが拒否proofで、missing/IO errorを拒否扱いにしない。これはoperator資源への拒否であり別standard worker間の拒否とは区別する。Importは既存distro/install directoryを拒否し、新しいUUID対応distroだけをWSL2として登録する。一度失敗したimportは再試行/adopt/rollbackせず証跡を保って調査する。Verifyはregistryの名前/version/BasePathを別途照合する。import command成功と登録検証、Linux boot、SSH/Herdr疎通を混同しない。

LinuxではWindows PATH混入を防ぎ、Linux-native runtimeの実体/versionを確認する。新規distroのinterop/automount抑制は防御補助でありOS権限境界の代替ではない。network公開port/Headscale/Infisical登録は別gate。`terminal.shell_mode=non_login` はPowerShellの `-NoProfile` を意味せず、worker clean environmentの代替にしない。

unregister、既存WSL停止/再生成、OS upgrade/reboot、daemon/scheduler追加は提供しない。再作成は新UUID/新resourceで行い、既存accountのpassword resetでidentityを取り替えない。

## 検証

`scripts/test-windows-worker.ps1` はpure contract/parser/env builder/registry errorの拒否を検査する。Windows管理者ではtemp配下のscratch ACL/state fixtureでforeign SID/hash/file/partial state拒否と再実行を検査する。実ユーザー/WSLは触らず、非管理者ではfixtureをSKIP表示する。`scripts/ci.sh` に組み込み、Windows CIは非変更Capabilityも実行する。

`scripts/test-windows-worker-wsl.ps1` はforeign/duplicate/WSL1/path drift/既存importの拒否、registry path正規化、限定import argv、source parserを検査する。native credentialed実行・実WSL登録・bootは別の実機証跡が必要。

一次資料（2026-10-25確認）: [.NET Password](https://learn.microsoft.com/en-us/dotnet/api/system.diagnostics.processstartinfo.password)、[LoadUserProfile](https://learn.microsoft.com/en-us/dotnet/api/system.diagnostics.processstartinfo.loaduserprofile)、[CreateProcessWithLogonW](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-createprocesswithlogonw)。現在userのWindows mountから管理鍵が見えるという実測と、本案の別user拒否proofを混同しない。

## 登録後の最初のLinux起動

`boot-runtime.ps1` は元のworker/WSL stageを変更せず、別の `pc-setup-worker-boot-<UUID>` に本人読取・Administrators/SYSTEM書込だけの固定sourceとmanifestを準備する。レビュー済みcontrollerで `Initialize-WorkerBootStage`、続いてSecureStringを使い `Invoke-WorkerBootStage` を一回だけ呼ぶ。実行直前にCreateNewのattempt markerを作り、失敗時も消さず保持する。

標準Windows SID本人のnative profile/WSL registry照合後、完全名distroだけを `--user root --exec /usr/bin/env -i` で起動し、固定shell probeでLinux/Ubuntu24.04/x86_64/root UIDとnonce往復、CPU数、memory、Windows mount/interopの存在を測る。新しいLinux userの作成・package導入・SSH/Herdr起動・network公開・credential登録は行わない。このboot stageだけではrootを新規import直後のinventoryに限定し、常用worker認証の完成とは扱わない。

Windows mount/interopがある場合も隠さず結果へ記録する。これはLinux bootの証拠であり、最終のWindows PATH排除やmount/interop抑制、resource budgetの実効性、SSH/Herdr疎通の合格ではない。first-boot vendor stderrの有無はbooleanだけ記録し、内容はチャットへ出さない。timeoutはプロセス/部分状態を保持し、global shutdownや再importをしない。既存adapter同様にstdout/stderrの取得は終了後size検査であり、streamingの厳密なメモリ上限ではない。

## 限定OS package maintenance

`maintenance-v1/runtime.ps1` は、完全UUIDで特定したworkerの別ProgramData stageに `contract.ps1`・`child.ps1`・`root-maintenance.sh` を保存する。初回stage作成は管理者PowerShellから、review済みのclean pc-setup commitを指定して一度行う。root scriptのSHA256はruntimeに固定され、再利用時はcommit、source hash、worker manifest、WSL登録、ACLを再照合する。driftやpartial stageはadopt・上書きしない。

```powershell
. ./platforms/windows-11/worker/maintenance-v1/runtime.ps1
$repositoryRoot = (Get-Location).Path
$null = Initialize-WorkerRootMaintenanceStage $instance $repositoryRoot '<reviewed pc-setup commit>'

# $passwordは承認済みprocess-scoped Infisical wrapperが返すSecureString。
$result = Invoke-WorkerRootMaintenanceV1 $instance $password Apply $repositoryRoot '<reviewed pc-setup commit>'
```

stage準備と実行はreview済みclean checkoutからnative x64 PowerShell 7.3以上・管理者tokenで行う。実行中に別Windows userのprocessを起動するため、その本人のWindows credentialを`SecureString`で渡す。通常運用では承認済みprocess-scoped Infisical wrapperから値を得て、手入力・平文引数・file保存はしない。

`Apply` は直前にpackage inventoryを調べ、不足がある時だけ同じworker Windows SIDからUUID対応WSLへ `--user root` で接続し、保護stageの固定scriptをstdinで実行する。対象は`mise.toml`のUbuntu/Linux APT baselineに限定し、`apt-get upgrade`・削除・sudo付与・フルbootstrap・mise/dotfilesやユーザー領域scriptのroot実行を行わない。適用後に再inventoryする。Windows passwordはSecureStringのprocess memoryだけで使い、Linux sudo passwordは設定しない。失敗時はAPTのraw diagnosticsやsecretを出さず、状態を確認してから明示的に再実行する。これはWindows account ownerが所有するdistroの保守経路であり、同一Windows userからのWSL root起動を防ぐ隔離境界ではない。

sourceテストはpackage一覧が`mise.toml`と一致すること、引数・報告parser、SHA256 pin、PowerShell/Bash構文を確認する。実APT導入や実WSL root実行の証拠ではない。初回実機適用、Windows→WSL SSHの専用鍵/host pin/nonce、Herdr接続は個別に記録する。
