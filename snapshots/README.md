# Environment snapshots

ここには「その時点で実際に入っていたtool version」を必要に応じて保存します。

snapshotはdesired stateではなく観測 evidence です。

Ubuntu/WSL:

```bash
./platforms/ubuntu-wsl/verify.sh --snapshot \
  > "snapshots/ubuntu-wsl-$(date +%F).txt"
```

## Rules

- secret / token / credentialを含めない。
- home directoryやusername等、不要なmachine-specific pathを含めない。
- snapshotのversionへdesired stateを自動的にpinしない。
- compatibility調査、upgrade regression、環境比較など目的があるときに保存する。
