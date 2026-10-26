# 専用SSH endpointのOS管理起動

Issue #138。既存SSH PoCのkey/config/Firewall/enrollmentを保持し、`pc-setup-ssh-poc-22222` という専用Windows Scheduled Taskで署名済みWindows OpenSSHをforeground `-D` として動かす。標準sshdはStopped/Manualのまま。一般bootstrapや既存serviceへ組み込まない。

SYSTEM service-accountタスクを使い、password/token/private keyをtask定義に格納しない。タスク定義とruntime sourceの変更権限はAdministrators/SYSTEMだけ。runtimeは別の `%ProgramData%\pc-setup-ssh-poc-runtime` に置き、元のenrollment manifestのhash・user SID・source hash・ACLを照合する。別SID/account、foreign task、部分資源、source/config/ACL driftはadopt/上書きしない。

## 適用

元の `ssh-poc.ps1 -Action Verify` が成功するnative x64管理者PowerShellから、review済みsourceで実行する。Installはタスクの登録までであり、その場でlistenerを置き換えない。

```powershell
./platforms/windows-11/ssh-poc/ssh-task.ps1 -Action Install
./platforms/windows-11/ssh-poc/ssh-task.ps1 -Action Verify
# 前面PoC listenerを所有確認の上で明示停止した後だけ:
./platforms/windows-11/ssh-poc/ssh-task.ps1 -Action Start
```

Startは使用中のTCP22222を拒否し、無関係なprocessをkillしない。起動タスクはVPN IPが存在するまで最大5分待ち、失敗時はTask Schedulerが1分間隔で最大3回再実行する。taskのexecution time limitを無制限にし、電池移行による停止を無効にする。private logはruntimeの `logs/sshd.log`。長期利用時のlog容量は運用側で確認する。

Tailscaleをlogout後も稼働させるには、元profileを維持して公式 `tailscale set --unattended=true` を別の明示操作として使う。前後のノードID/IP/control server/RunSSH/必要Serve設定を比較する。新login/up/logoutで空状態を埋めず、登録やlogin-serverを切り替えない。

## 検証と停止

Verifyはowned task定義・ACL・source/enrollment同一性の検査であり、認証の成功ではない。`Get-NetTCPConnection` のIP/portとsshdのconfig pathを確認し、Macからhost pin・専用公開鍵・nonce・Herdr再接続を検証する。OS再起動の試験を行わない限りboot triggerの実動は未検証と記録する。

```powershell
./platforms/windows-11/ssh-poc/ssh-task.ps1 -Action Stop
```

Stopも所有権照合後、今回のtaskだけを対象にする。元のSSH enrollment、key、Firewall、task/runtimeは保持し、次回bootのtriggerも保持する。削除やforeign/partial修復は提供しない。元のPoC Undoを行う前にはtaskを停止し、startup登録の撤去を別途レビューする。停止/撤去を疎通直後に自動実行しない。

## 実装保証と限界

pure testsはtask XML、SYSTEM/no password、NoProfile、boot trigger、policy/ACL drift拒否を検査する。昇格WindowsではTask SchedulerのTASK_VALIDATE_ONLYを使い、taskを実登録せずOS schemaを検査する。実task起動、SYSTEMでのOpenSSH認証、OS reboot、VPN復帰は別の実機証跡が必要。controller/basic用の管理経路であり、低権限worker自身のSSH境界とは区別する。

一次資料（2026-10-26確認）: [Task Scheduler schema](https://learn.microsoft.com/windows/win32/taskschd/task-scheduler-schema)、[RegisterTask](https://learn.microsoft.com/windows/win32/taskschd/taskfolder-registertask)、[task security descriptor](https://learn.microsoft.com/windows/win32/taskschd/registeredtask-setsecuritydescriptor)、[Tailscale Windows MSI](https://tailscale.com/docs/install/windows/msi)。
