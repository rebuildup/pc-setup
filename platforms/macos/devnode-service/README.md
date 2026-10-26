# macOS専用開発ノードのLaunchAgent

`control.sh`は、既に検証した専用sshd設定とnamed Herdr serverを、ログインユーザーのLaunchAgentとして管理する。software install・node enrollment・鍵生成・秘密情報取得は行わない。rootやsudoで実行しない。

## 入力

Git/`home/`の外に本人所有0600のJSONを保存する。次のplaceholderは実際のprivate pathとSHA256へ置換する。秘密鍵そのものは記載しない。`shasum -a 256`などで、公開鍵認証専用のsshd config、Herdr実行binary、Herdr TOMLをそれぞれ確認する。

```json
{
  "version": 1,
  "instanceId": "14f29b3f-cda1-4acf-9f18-26d35f8d6074",
  "sshdConfig": {"path": "/absolute/private/sshd_config", "sha256": "REPLACE_WITH_SHA256"},
  "herdrBinary": {"path": "/absolute/tools/herdr", "sha256": "REPLACE_WITH_SHA256"},
  "herdrConfig": {"path": "/absolute/private/herdr.toml", "sha256": "REPLACE_WITH_SHA256"},
  "session": "devnode-owned-session",
  "workingDirectory": "/absolute/private/workspace",
  "path": "/absolute/tools/bin:/usr/bin:/bin:/usr/sbin:/sbin"
}
```

JSONは未知fieldを拒否する。private configは本人所有・group/world権限なし、binaryはrootまたは本人所有・group/world書込みなし、各fileはsymlink/hardlinkではない通常fileを要求する。working directoryは本人所有、group/world書込みなしにする。入力pathにsymlinkを使わない。

sshd設定は専用VPN address/portと、接続元を限定したAllowUsers/authorized_keysを事前に用意する。password・keyboard interactive・PAM・root login・forwarding・TTY・user RCを許可しない。標準sshd設定を流用せず、既存PoCでhost pinとnonceを確認してから登録する。Herdrは公式multi-machine機能を持つ互換版を使用し、default以外の固有session名と専用TOMLを用意する。

## 操作

```sh
./platforms/macos/devnode-service/control.sh plan --config /private/path/service.json
./platforms/macos/devnode-service/control.sh apply --config /private/path/service.json
./platforms/macos/devnode-service/control.sh status --config /private/path/service.json
./platforms/macos/devnode-service/control.sh remove --config /private/path/service.json
```

planはpathとlabelのみ表示する。applyは入力hashとsshdの有効設定を検査し、所有stateへworker/configを配置してから2つのjobをbootstrapする。既に同じ定義の所有jobがあれば再起動しない。foregroundで同じHerdr sessionが動いている場合は停止し、元の起動方法を確認してから明示的に切り替える。無関係なprocessを自動停止しない。

所有stateは`~/.local/state/pc-setup/devnode-service/<instanceId>/`、plistは`~/Library/LaunchAgents/dev.rebuildup.pc-setup.devnode.{ssh,herdr}.<instanceId>.plist`。ログはprivate state内の`ssh.log`・`herdr.log`。秘密鍵・入力config・default sessionを変更しない。job再起動時にもhashを再検査し、runtime環境はHOME/USER/LOGNAME/SHELL/PATH/HERDR_CONFIG_PATHだけを渡す。環境型secretは自動共有しない。

partial bootstrapはmanifestを保持する。同じ入力でapplyを再実行すれば未登録jobだけを起動する。定義や入力hashが変わった場合は自動修復せず停止する。管理ファイルを他ツールから同時編集しない。lockが残った場合は実行中の操作がないことを確認し、そのprivate lockだけを明示的に撤去する。

removeは所有確認済みjobのみをbootoutし、対応plist/worker/config/manifestを撤去する。ログは`retired-<instanceId>-<archive UUID>`へ保持する。入力JSON・sshd鍵・authorized_keys・Herdr TOML・Herdrの接続catalogは残す。登録失効やSSH権限撤回は別のnode lifecycle操作で実施する。

## 検証と制限

`python3 scripts/test-macos-devnode-service.py`は実際のprivate filesystemで所有/foreign resource拒否・drift・partial bootstrap・再実行・撤去を検証する。launchctl部分は狭い代替実装を用いるため、実機での起動・再接続やOS再起動は別途必要。

statusのloaded/runningはSSH認証やHerdr操作成功を意味しない。既存のpin付きSSH/nonceとHerdr E2Eを実行する。GUIログイン前・ログアウト中は対象外。VPNが遅れて起動した場合は最大60秒程度の再試行間隔がある。ログの自動rotationは実装していないので継続運用時は容量を監視する。

launchctl printは安定APIではないため、認識できない出力や異なるplist pathでは操作を拒否する。macOS更新時に再検証する。同じOSユーザーとrootを信頼する構成であり、同一ユーザー内の悪意あるprocessを隔離するものではない。
