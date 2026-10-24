# Headscale cohost PoC

既存 Infisical VPS に、開発 node 用 Headscale control plane を独立 Compose project `devnode-headscale` として置く。対象は Docker / Compose 導入済み Debian 13 amd64。OS provisioning、Infisical の再作成、既存 tailnet の切替、node 登録、credential 発行はこの手順の対象に含めない。[ADR-0015](../../docs/adr/ADR-0015.md) が責務境界を定める。

## 公開前の条件

- `headscale.rebuildup.dev` の A を実際の VPS 公開 IPv4 へ設定する。Cloudflare は **DNS only**。AAAA は VPS IPv6 と経路・firewall を実測して使える場合だけ設定する。古い AAAA を残さない。
- 外部から TCP 80/443 が VPS に届くことを provider firewall と host firewall の両方で確認する。80 は HTTP-01 証明書取得・更新に必要であり、初回取得後も閉じない。
- `ss -ltnp`、`docker ps` で 80/443 が空いていることを確認する。既存 SSH の port と management access を保持する。provider console 等の復旧経路も確保する。
- `df -h`、`free -h` と既存 service の負荷を確認する。小規模 PoC の同居判断であり容量保証ではない。Infisical の compose/network/volume/firewall rule を変更・停止・再起動しない。
- 手元から `curl --fail https://secrets.rebuildup.dev/api/status` と、VPS 上で `docker compose --project-directory /srv/infisical ps -q | xargs -r docker inspect --format '{{.Id}} {{.State.StartedAt}} {{.RestartCount}}'` の開始前記録を machine-local に採る。API の応答は記録前に公開情報だけと確認する。終了後も同じ container ID / StartedAt / RestartCount と endpoint の正常性を確認する。既存 Compose の実際の project/file 指定が異なる場合は既存の正式手順を使う。

## 準備・検証・起動

review 済み commit の checkout から VPS 上で実行する。対象 directory の親 `/srv` は既存であること。並行実行しない。prepare は新規 directory だけを作成し、同じ source での再実行は無変更となる。既存の所有権 marker がない directory、symlink、source と異なる file は拒否する。通常 bootstrap から自動起動しない。

```bash
sudo bash infrastructure/headscale/prepare.sh
sudo bash infrastructure/headscale/manage.sh validate
sudo bash infrastructure/headscale/manage.sh apply
sudo bash infrastructure/headscale/manage.sh verify
```

`validate` は Compose の一つの image reference を解決し、Compose schema と official image の `configtest` を検証する。configtest は server を構築するため、実 DB とは別の tmpfs state を使う。稼働後 `verify` は health、実行中 server を使った `policy check --file`、公開 TLS health を検証する。公開 TLS の初回発行には DNS・80 の条件が必要。失敗時は盲目的に再起動せず `docker compose --project-directory /srv/devnode-headscale logs --tail 100 headscale` を private な terminal で確認する。ログを公開する前に node 情報等を除去する。

`manage.sh` は project と既知の named resource の ownership label を確認する。`apply` はこの専用 project だけを起動する。既存資源を引き継ぐ汎用 installer ではない。手動で同名 project を作っていた場合も marker/label だけで正当と判断せず、先に resource の由来を確認する。

## ネットワークと policy

公開 port は TCP 80/443 だけ。HTTPS は Headscale 自身の ACME HTTP-01 で終端し、host 443 → container 8443、host 80 → challenge 8080 を割り当てる。metrics は無効、gRPC は container loopback、admin Unix socket は named volume 内だけ。PoC の headscale process は memory 512 MiB / CPU 1 / PID 128 に制限する。host 全体の容量・可用性を保証するものではなく、OOM/restart は監視して再評価する。DB、socket、private Noise key、ACME account/certificate は machine-local volume `devnode-headscale_state` が所有する。設定/policy は read-only bind mount、Git に秘密値や `.env` は置かない。

初期 policy は明示的な `{"grants": []}` で全 node 間通信を拒否する。policy の欠落・空 file は deny-all を意味しないため削除しない。登録機能の公開を network access の許可と混同しない。role ごとの grants と deny/accept policy tests を別 review で追加し、その後に node を登録する。preauth/API key、user 認証、broker、scheduler はまだ実装しない。credential を terminal 出力・Git・home 設定へ保存する issuance 手順も追加しない。

MagicDNS は `devnodes.rebuildup.dev`。通常 DNS resolver は node の設定を保持する。IPv4 allocation は `100.96.0.0/16`（Tailscale CGNAT 範囲内）で、既知の既存 node address と重ならないように選んだ。これは全既存 tailnet・VPN の重複を保証しない。導入 node ごとに route を確認する。異なる control plane を prefix だけで分離できるとは扱わず、既存 Tailscale account/tailnet を自動切替しない。IPv6 tail address は初期 PoC では割り当てない。

embedded DERP は無効で、この VPS に UDP 3478 は開けない。default Tailscale DERP map を取得するため外部 HTTPS/DNS と Tailscale の relay/STUN availability に依存する。relay 経由でも node 間 payload は end-to-end 暗号化されるが、relay 側には接続元・タイミング・転送量等が見える。直接接続できない node は外部 relay 障害の影響を受ける。Headscale/VPS 障害時は登録、key 更新、policy/DNS/map 配布ができず、既存接続の継続も無期限には保証しない。Infisical と host 障害・資源枯渇の failure domain を共有する。独立可用性や relay 自立性が必要なら別 host / 自前 DERP を再検討する。

## Backup・変更・rollback

停止を伴う整合 backup を採る。`sudo bash infrastructure/headscale/manage.sh stop` 後、volume の mountpoint を `sudo docker volume inspect devnode-headscale_state --format '{{.Mountpoint}}'` で確認し、root 権限・umask 077 でその全内容と `/srv/devnode-headscale` を machine-local backup へ保存する。DB のみの稼働中 copy はしない。backup は秘密鍵を含むため Git/共有 home に置かず、off-host 保存は暗号化する。復旧は Headscale を停止し、同じ image version の volume と設定を組で戻して validate/apply/verify する。検証用 restore は本番 port / 本番 volume を共有しない。

設定・policy・image 更新は backup 後に source diff を review する。prepare は既存と異なる file を上書きしないため、更新時は managed directory の旧 file を保護してから operator が明示的に差し替える。稼働中 policy の暗黙 hot reload に依存せず専用 service を再作成し、policy check を実行する。schema migration 後の image downgrade は volume の同時 restore が必要になり得る。

`stop` も source と host 設定の一致を要求する。設定差分や破損で拒否され、緊急停止が必要な場合は、実在する当該 container の `com.docker.compose.project` が `devnode-headscale`、`com.docker.compose.service` が `headscale`、`com.docker.compose.project.config_files` が `/srv/devnode-headscale/compose.yaml` であることと、image / mount の由来を `docker inspect` で実測確認する。その container ID を明示して `sudo docker stop <確認済みのcontainer-ID>` だけを実行する。名前だけでは所有権の根拠にしない。full down / prune や他 service 操作は使わない。

PoC rollback は `sudo bash infrastructure/headscale/manage.sh stop` で専用 service を止め、public DNS/firewall の今回追加分だけを戻す。volume は保持し、`down -v`、system prune、Infisical の compose 操作は使わない。SSH/private key や既存 management tailnet を変更しない。最後に Infisical の開始前後 assertion を照合する。

image は 0.29.6 の official OCI multi-platform index digest `sha256:cabe84f0699913dbca9320f0883dca7565dd08df3c5be29edfabbebeff763966`（amd64 / arm64）に固定する。tag と digest を組で review し、実際の image 選択は Compose を唯一の source とする。

## 検証範囲と根拠

`./scripts/ci.sh` は shell syntax/ShellCheck と filesystem ownership regression を実行する。`docker compose -f infrastructure/headscale/compose.yaml config --quiet` は daemon 不要。image/schema、実 TLS 発行、provider firewall、既存 Infisical の無停止は上記 VPS 検証で別途 evidence を採る。ローカル静的 gate の成功で実運用成功を主張しない。

- [v0.29.6 release](https://github.com/juanfont/headscale/releases/tag/v0.29.6)
- [version 固定 config schema](https://github.com/juanfont/headscale/blob/v0.29.6/config-example.yaml)
- [configtest 実装](https://github.com/juanfont/headscale/blob/v0.29.6/cmd/headscale/cli/configtest.go)、[policy check 実装](https://github.com/juanfont/headscale/blob/v0.29.6/cmd/headscale/cli/policy.go)
- [container guide](https://headscale.net/stable/setup/install/container/)、[TLS](https://headscale.net/stable/ref/tls/)、[DERP](https://headscale.net/stable/ref/derp/)
