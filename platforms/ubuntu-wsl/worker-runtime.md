# 分離worker向けCodex / Herdr runtime

この入口はpc-setupの既存mise backendでCodexとHerdrだけを導入する。APT、人間用dotfiles、GitHub/Infisicalログイン、OS account、WSL設定、ネットワーク、Herdrセッションを変更しない。通常のUbuntu全bootstrapを低権限workerに流用しない。

## 前提

Linux worker本人、Python 3.11以上、Linux-native mise、レビューしたpc-setup checkoutが必要。sudoで実行しない。miseが未導入なら、既存bootstrapと同じ[公式導入経路](https://mise.jdx.dev/getting-started.html)でmiseだけを先に導入する。親WindowsのPATHや認証ファイルを持ち込まない。

対象toolとversion requestはrootの`mise.global.toml`、解決版・URL・checksumは`mise.global.lock`がcanonical。worker用の別pinや独自download installerは持たない。Linux platform entryやchecksumがない場合は停止する。新architectureの追加はcanonical lockをmise CLIで更新してから行う。

## 導入と検証

次のminimum値は当該nodeの現在版または必要な互換性の下限を入力する。独立したversion pinではなく、古いsource取得によるdowngradeを防ぐための入力。更新後も既存runtimeより古い版への切替は拒否する。

```sh
python3 platforms/ubuntu-wsl/worker-runtime.py install \
  --mise "$HOME/.local/bin/mise" \
  --state "$HOME/.local/state/pc-setup/worker-runtime" \
  --minimum-codex 0.165.0 --minimum-herdr 0.9.5

python3 platforms/ubuntu-wsl/worker-runtime.py verify \
  --mise "$HOME/.local/bin/mise" \
  --state "$HOME/.local/state/pc-setup/worker-runtime" \
  --minimum-codex 0.165.0 --minimum-herdr 0.9.5
```

stateは本人所有0700のcanonical pathを使う。symlinkを含むpathや第三者が書換可能なdirectoryは拒否する。sourceからCodex/Herdrだけのmise設定を生成し、canonical lockを保持して`mise install --locked codex herdr`を実行する。config/data/cache/stateはこのworker runtime専用で、人間用のglobal設定や既存mise install inventoryを操作しない。installer失敗はexit codeを返し、credentialを含む可能性のあるprovider出力をログへ転送しない。

Codexの公式full package（`bin/codex`、`bin/codex-code-mode-host`、`codex-resources/bwrap`、`codex-path/rg`、`codex-package.json`）を保持する。locked install直後の新candidateについてだけ、専用inventory内の本人所有regular fileをno-followで開き、vendor展開由来のgroup/other writeを除去する。special bit、symlink、link countが1でないhardlinkは拒否する。外部inodeのpermissionは変更しない。その後package構造、owner/mode、metadata、versionを検証し、file hashを記録する。既存currentのpermission/hash driftは正規化せず停止する。片方だけ導入できた場合やhelper欠落時はcurrentへ公開しない。検証済みgenerationのcurrent symlinkを最後に原子的に切り替える。同じstateへの並行操作は拒否する。

返却する絶対pathはシェル初期化を必要としない。

```sh
~/.local/state/pc-setup/worker-runtime/current/bin/codex --version
~/.local/state/pc-setup/worker-runtime/current/bin/herdr --version
```

Herdr/既存agent launcherもこの実体または下記の明示移行済み入口を使う。別userの認証、共有環境変数、全シークレットを注入しない。Codexはworker本人が個別認証する。runtimeはそのauth/session/cacheを読み取ったり移送したりしない。

## 既存standaloneの明示移行

`install`は既存`~/.local/bin/codex`や`herdr`を変更しない。今回のPoCなど管理対象と確認できたregular executableに限り、事前の導入記録と照合したSHA256を指定する。現在fileを自分でhashしただけでは管理対象の証明にならない。不明fileやforeign symlinkは手動確認に止める。

```sh
python3 platforms/ubuntu-wsl/worker-runtime.py migrate \
  --mise "$HOME/.local/bin/mise" \
  --state "$HOME/.local/state/pc-setup/worker-runtime" \
  --minimum-codex 0.165.0 --minimum-herdr 0.9.5 \
  --tool codex --expected-sha256 '<導入記録と照合した64桁SHA256>'
```

元binaryは専用stateの`legacy/<tool>.<SHA256>`へ移動し、`~/.local/bin/<tool>`をcurrent entrypointへのsymlinkにする。既存versionより古いruntimeへの移行は拒否する。intent、元hash、backup、対象pathが一致すれば中断後も同じcommandで再開できる。異なるfileを自動adoptせず、backupを消さない。移行中に同じpathを外部から編集しない。

## 更新と障害時

source更新後、installとverifyを再実行する。古いgenerationやmise tool版はこの入口ではpruneしない。実行中のHerdrサーバーやagentを更新・停止する機能ではないため、client/server互換性と再接続は別に検証する。

同じstateへの操作は、本人所有・no-followのregular fileに対するOSの`flock`で排他する。process終了・crashでlockは自動解放され、stale PIDやlock directoryを推測して削除しない。未知状態の自動削除は行わず、残るinstallerの部分状態はmise自身の次回導入と検証で扱う。

miseのversions hostが新releaseをまだ列挙しない場合がある。canonical lockを更新する管理者は[公式手順](https://mise.jdx.dev/troubleshooting.html#versions-and-downloads)でupstreamとの差を調べ、必要なときだけ`MISE_USE_VERSIONS_HOST=0`で公式upstreamから対象toolを再解決する。lockのURL/checksumを手編集しない。

## 検証範囲

`python3 scripts/test-worker-runtime.py`は外部mise providerだけをfixtureに置き換え、実filesystem上で限定導入・helper欠落・drift・downgrade・foreign symlink拒否・backupと中断再開を検査する。repository CIへ組み込む。fixture成功は、実WSLでのinstaller完了、Codex tool実行、sandboxの実効性、Herdrの接続成功を証明しない。

実機適用後は非ログインHerdrからCodexを起動し、隔離した作業directoryでtool実行・編集・テスト、sandboxによる許可外書込拒否、detach/reattachを検証してから実用完了とする。

参考：[公式Codex package構造](https://github.com/openai/codex/blob/rust-v0.165.0/scripts/codex_package/README.md)、[mise install](https://mise.jdx.dev/cli/install.html)、[mise lock](https://mise.jdx.dev/cli/lock.html)。
