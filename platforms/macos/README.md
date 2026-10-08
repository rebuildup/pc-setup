# macOS

実機Macで観測・採用したmacOS desired state。

共通CLI/runtimeはroot `mise.toml` / `mise.global.toml` が所有し、このdirectoryはmacOS固有の設定、manual boundary、verificationを所有する。

## Keyboard baseline

低レイヤーの1:1配列変換はmacOS標準の `hidutil` で大西配列へ変換する。

canonical mapping:

```text
physical: Q W E R T  Y U I O P
output:   Q L U , .  F W R Y P

physical: A S D F G  H J K L ;
output:   E I A O -  K T N S H

physical: Z X C V B  N M , . /
output:   Z X C V ;  G D M J B

physical - -> /
```

特に `G -> -`、`- -> /`、`/ -> B` は独立した1:1 mappingであり、変換を再帰適用しない。

高度なtap-hold、layer、shortcut等はこのbaselineへ含めず、kanata導入時に上位layerとして扱う。

### Apply

```bash
./platforms/macos/install-keyboard.sh
```

installerはsystem-wideに次を配置する。

- `/usr/local/libexec/pc-setup/macos-keyboard/apply-onishi.sh`
- `/usr/local/libexec/pc-setup/macos-keyboard/onishi.json`
- `/Library/LaunchDaemons/dev.rebuildup.pc-setup.onishi-keymap.plist`

LaunchDaemonはmacOS起動時にrootでmappingを再適用する。これはログイン後だけ動くLaunchAgentではなく、macOSのloginwindowより前に起動できるsystem serviceとして扱う。

手動再適用:

```bash
sudo /usr/local/libexec/pc-setup/macos-keyboard/apply-onishi.sh
```

### Login screen boundary

`hidutil` のmapping自体は全ユーザーに適用されるため、通常のmacOS loginwindowではsystem LaunchDaemonにより適用可能。

ただしFileVaultが有効なcold boot直後のpassword画面はmacOSのuserlandではなくPreboot環境で動く。その段階では `launchd` / `hidutil` / Kanata はまだ起動していないため、このrepositoryの仕組みではカスタマイズできない。

確認:

```bash
fdesetup status
```

一時的にQWERTYへ戻す:

```bash
hidutil property --set '{"UserKeyMapping":[]}'
```

次回macOS起動またはinstaller再実行でdesired mappingへ戻る。

## Kanata custom layer

F1でのOnishi/QWERTY切替、Caps extra layer等は `platforms/macos/kanata` が所有する。

```bash
./platforms/macos/kanata/install-kanata.sh
./platforms/macos/kanata/verify.sh
```

KanataとKarabiner VirtualHID daemonはsystem LaunchDaemonとして起動する。詳細とTCC permission boundaryは [kanata/README.md](./kanata/README.md) を参照。

## Containers (Colima)

コンテナ実行は Docker Desktop ではなく [Colima](https://github.com/abiosoft/colima) で構成する ([ADR-0013](../../docs/adr/ADR-0013.md))。
`colima` / `docker` / `docker-compose` / `docker-buildx` / `docker-credential-helper` / `ffmpeg` と GUI アプリは `mise.global.toml` の `[bootstrap.packages]` に `os = "macos"` 付きで宣言され、`mise bootstrap packages apply` が導入する。OS 条件がないと Windows / Linux の bootstrap まで Homebrew cask を解こうとするため、条件は必須である。

Docker Desktop は使用しない。GUI と常駐サービスが不要で、エージェントは CLI だけで完結でき、コンテナのデータは Apple Virtualization.framework 上の仮想機に分離される。registry 認証も Docker Desktop に依存しない。Docker Desktop は `docker-credential-osxkeychain` を同梱し、アンインストールで消えても `~/.docker/config.json` の `credsStore` は残すため、その状態では `docker pull` が credential helper の不足で失敗する。`brew:docker-credential-helper` が同じ Keychain backed helper を提供する。

### 初回セットアップ

```bash
mise bootstrap packages apply
./platforms/macos/containers/install.sh
```

`install.sh` は次を収束させる。

- `~/.docker/cli-plugins` への `docker-compose` / `docker-buildx` リンク。壊れたリンクは検出して張り替え、正常なリンクと他人の実体ファイルは触らない
- `colima` Docker Context の存在確認
- VM が無ければ次の設定で作成する

```text
runtime: docker / vm-type: vz (Apple Virtualization.framework) / mount-type: virtiofs
cpus: 4 / memory: 4GiB / disk: 60GiB / arch: host に追従
```

Apple Silicon でも Intel でも同じ手順で、Homebrew の prefix は mise に問い合わせて解決するので `/opt/homebrew` を前提にしない。サイズは `PC_SETUP_COLIMA_CPUS` / `PC_SETUP_COLIMA_MEMORY` / `PC_SETUP_COLIMA_DISK` で上書きできる。

既存 VM は削除・再作成・サイズ変更しない。設定が desired と異なる場合は差分を表示するだけなので、変更するかどうかは人が決める。

```bash
colima start --cpus 8 --memory 8 --disk 100   # 明示的に変更する場合のみ
```

`colima delete` やデータ初期化を伴う操作は repository の script からは行わない。

### 起動と停止

Colima は常時起動しなくてよい。必要なときだけ起動する。

```bash
./platforms/macos/containers/control.sh start   # 起動 (登録済み設定のまま)
./platforms/macos/containers/control.sh stop    # 停止 (イメージとボリュームは残る)
./platforms/macos/containers/control.sh status  # VM と docker 接続の確認
```

launchd の常駐 service は作らない。VM 未作成の状態で `start` しないこと: `colima` 自身の既定値で VM が作られ、desired 設定とずれる。その場合は `install.sh` を先に実行する。

### Docker Context

Docker Context は `colima` を利用する。`colima start` が context を登録し、active にする。

- `DOCKER_HOST` をグローバルに固定しない。shell 起動ごとに別の daemon を指す状態になり、解消が難しい
- repository の script は既存の Docker Context を切り替えない。切り替えたい場合のみ `docker context use colima` を手動で実行する

```bash
docker context ls
docker info
```

### エージェントからの利用

Codex / Claude Code / Pi などのコーディングエージェントは、そのまま `docker` コマンドを使える。

1. `./platforms/macos/containers/control.sh status` で VM の状態を確認する
2. stopped なら `./platforms/macos/containers/control.sh start`
3. `docker ps` / `docker compose ...` を通常どおり実行する

VM を停止したまま `docker` を実行すると `Cannot connect to the Docker daemon` になる。これは環境未構築ではなく停止状態なので、`start` で復旧する。エージェントは VM の削除・再作成・サイズ変更を行わず、差分が見つかったら報告して判断を仰ぐ。

### トラブルシューティング

| 症状 | 原因 | 対処 |
| --- | --- | --- |
| `Cannot connect to the Docker daemon` | VM が停止している | `./platforms/macos/containers/control.sh start` |
| `docker: 'compose' is not a docker command` | プラグインが未リンク、またはリンクが壊れている | `./platforms/macos/containers/install.sh` を再実行する |
| `error getting credentials - docker-credential-osxkeychain not found` | Docker Desktop 削除の残骸 (`credsStore` のみ残っている) | `mise bootstrap packages apply` で `brew:docker-credential-helper` を入れる |
| 既存 VM の設定が desired と違う | 手動で変更したか、古い設定のまま | 差分は `install.sh` / `verify.sh` が報告する。変更する場合のみ `colima start --cpus ... --memory ... --disk ...` |
| `colima start` が古い既定値で VM を作ってしまった | VM 未作成のまま `start` した | 誤作成した profile は人が判断して `colima delete` する。repository の script は削除しない |

### Verification

```bash
./platforms/macos/containers/verify.sh
./platforms/macos/containers/verify.sh --smoke   # コンテナを1回実行する (Docker Hub から pull)
```

verify は mise 設定の読み込みと OS 条件、`colima` / `docker` / compose / buildx / `ffmpeg`、Docker Context、VM 設定を確認する。VM を起動することはなく、停止中は「作成済みだが停止中」と未構築を区別して報告し、daemon に依存する項目だけを skip する。`--smoke` は VM が起動中のときだけ有効。

## Verification

```bash
./platforms/macos/verify.sh
./platforms/macos/kanata/verify.sh
./platforms/macos/containers/verify.sh
```

GUI application inventoryは実機利用に応じて `plans/macos` から段階的に昇格する。platformがActiveであることはcandidate GUI一覧をすべて採用したことを意味しない。
