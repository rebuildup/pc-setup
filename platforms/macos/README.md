# macOS setup

macOS の actual machine baseline。共通CLI/runtimeは root `mise.toml` / `mise.global.toml` が所有し、このdirectoryは実機で確認した macOS 固有設定を扱う。

未採用・未検証のGUI/creative/audio候補は引き続き `plans/macos/` に置き、Windows inventory から自動継承しない。

## Fresh setup

root entrypoint:

```bash
curl -fsSL https://raw.githubusercontent.com/rebuildup/pc-setup/main/bootstrap.sh | bash
```

Apple Command Line Tools が未導入なら bootstrap が案内して終了する。導入後に同じcommandを再実行する。

既存checkout:

```bash
./bootstrap.sh
```

## Keyboard baseline

大西配列の単純な1:1置換は macOS 標準の `hidutil` が所有する。

`platforms/macos/apply-onishi.sh` の確定mappingには次を含む。

- physical `-` -> `/`
- physical `G` -> `-`
- physical `/` -> `B`
- backtick は変更しない

layer / tap-hold / chord / navigation 等の高レベル入力変換はこのmappingへ混ぜず、kanata側で扱う。

Appleの `hidutil` mapping は再起動時に失われるため、bootstrap は user LaunchAgent `dev.rebuildup.pc-setup.onishi` を `~/Library/LaunchAgents` に導入する。LaunchAgent はログイン時にmappingを再適用し、bootstrap再実行時には現在のrepository版へ更新・再ロードする。

現在のsessionへ手動で再適用する場合:

```bash
./platforms/macos/apply-onishi.sh
```

LaunchAgentだけを再構成する場合:

```bash
./platforms/macos/setup-keyboard.sh
```

この方式はuser session開始後に有効になる。macOSのlogin screen自体を大西配列へ変更することは今回のscope外。

## Verify

```bash
./platforms/macos/verify.sh
```

verifyはmacOS、installed apply script、LaunchAgent registration、active `hidutil UserKeyMapping` を確認する。

## Remaining candidates

GUI application / creative / audio / kanata のうち、actual daily desired stateとしてまだ確定していないものは `plans/macos/` で評価を継続する。candidateであることだけを理由にactive bootstrapへ追加しない。

## References

- Apple Technical Note TN2450 — Remapping Keys in macOS 10.12 Sierra
- Apple Service Management / launchd documentation
