# Windows 専用 SSH 接続 PoC の実装境界

- 確認日: 2026-10-24
- 追跡: [pc-setup #130](https://github.com/rebuildup/pc-setup/issues/130)
- 実行手順: [Windows SSH PoC](../../platforms/windows-11/ssh-poc/README.md)

## 一次資料と判断

[Microsoft の導入資料](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_install_firstuse) は OS optional capability と標準 service の起動を分けて説明する。導入は port 22 の標準 firewall rule を追加するため、今回の専用 port 22222 のルールと同一視しない。既存標準 service と設定を今回の実装の所有物として採用しない。

[Windows server configuration](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh-server-configuration) は `-f` による別 config、AllowUsers の小文字指定、標準管理者グループに対する共有 authorized_keys の既定を説明する。今回の config は独立した AuthorizedKeysFile と単一ローカル user を指定し、標準 config を Include しない。

[公式 troubleshooting](https://github.com/PowerShell/Win32-OpenSSH/wiki/Troubleshooting-Steps) は `sshd -d` の管理者対話実行時、実行中の user への鍵認証だけが可能であると説明する。この前提を current SID と target local user SID の一致で拘束する。専用名 service の OS 同梱版での互換性は確認できていない。今回は単発接続 PoC として対話実行を選択し、接続ごとに再起動する。恒久化の方式は決定しない。

[Win32-OpenSSH の ACL 資料](https://github.com/PowerShell/Win32-OpenSSH/wiki/Security-protection-of-various-files-in-win32-openssh) に基づき、専用 config、公開鍵、host key と manifest の所有者を BUILTIN\Administrators とし、SYSTEM / Administrators のみを許可する。既存ユーザーの authorized_keys や host key を流用しない。

## Assurance map

| 性質 | 機構 | 保証の限界 |
| --- | --- | --- |
| 単一 user / VPN IPv4 / Ed25519 wire format | 純粋 helper の実行テストと runtime validation | 実際の Windows account mapping は実機対象 |
| 専用 config / publickey only / forwarding 無効 | config 生成テスト、実機 `sshd -t` | OS 同梱版の機能対応は実機で確認 |
| foreign / drift の非破壊拒否 | hash / file-set test、ACL runtime check | Windows ACL API は未実行 |
| 専用 firewall scope / listener | API の resource 属性照合、明示 Start | 実ネットワークと既存広域ルールの影響は未検証 |
| host identity の pin | 別経路 fingerprint 照合を要求 | Mac 側の操作と人間の照合が必要 |

counterexample として wildcard user、非 VPN address、source CIDR、複数 public key、短い不正 wire key、変更済み管理ファイル、foreign file を拒否する実行検査を置く。

## Known model gaps

macOS 上の PowerShell parser / pure helper テストと repository CI は Windows provisioning 成功の証拠ではない。Windows の ACL、firewall、sshd 起動/認証/終了、VPN 到達性、Undo の実機挙動は未実行。実機で host fingerprint 照合、専用鍵での nonce echo、別 user / 別鍵 / password 拒否、listener と firewall scope、撤去を確認するまで接続 PoC 成立とは扱わない。Infisical Machine Identity と WSL 登録はこの段階に含めない。
