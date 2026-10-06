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

installerは次をuser-localに配置する。

- `~/.local/libexec/pc-setup/macos-keyboard/apply-onishi.sh`
- `~/.local/libexec/pc-setup/macos-keyboard/onishi.json`
- `~/Library/LaunchAgents/dev.rebuildup.pc-setup.onishi-keymap.plist`

LaunchAgentはログイン時にmappingを再適用する。現在のログインsessionにはinstaller自身が即時適用する。

手動再適用:

```bash
~/.local/libexec/pc-setup/macos-keyboard/apply-onishi.sh
```

一時的にQWERTYへ戻す:

```bash
hidutil property --set '{"UserKeyMapping":[]}'
```

次回ログインまたはinstaller再実行でdesired mappingへ戻る。

## Verification

```bash
./platforms/macos/verify.sh
```

GUI application inventoryは実機利用に応じて `plans/macos` から段階的に昇格する。platformがActiveであることはcandidate GUI一覧をすべて採用したことを意味しない。
