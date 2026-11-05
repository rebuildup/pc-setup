# 標準Windowsユーザー内の新規WSL接続

Issue #134の次段階。既存basic/Ubuntuと既存worker manifest/probeを保持し、既に準備した標準worker SID内へ署名検証済みfresh Ubuntuイメージを一台だけ登録する。OS provisioningはpc-setup、非秘密設定のGit同期・logical node bindingはdotfilesが所有する。

1. pure contractの失敗を先に確認し、foreign/duplicate/WSL1/path driftの拒否と正規import argvを検査する。
2. 元のRead-WorkerStateによるSID/account/group/ACL/source照合後、別の管理者所有WSL stageへchild/contract/imageを固定する。部分状態は保持して停止する。
3. operatorのInfisical human loginから既存の専用passwordだけをSecureStringで受ける。新しいsource/controller hashを固定し、最初にcredentialed Inventoryだけを実行する。argv/env/log/fileへpasswordを出さない。
4. 容量とimage hashを再検査し、workerのnative NoProfile processからUUID対応distroを一度だけimportする。成功後は別のVerifyでregistry/SID/path/WSL2を検査する。import再試行・adopt・unregister・shutdown・既存Ubuntuの停止はしない。
5. import後にLinux boot、Windows mount/interop、native runtime、SSH trust/endpoint、Herdr公式接続を順に実測する。設定値やsourceテストを実効境界の証明としない。
6. scripts/ci.sh、独立レビュー、実機証跡をsourceのimmutable SHAと結び付け、Draft PRを更新する。mergeはしない。

このsource sliceの完了条件は専用SID内のowned WSL2登録とVerifyであり、Linux SSH/Herdr/常用運用の完了ではない。ユーザーの接続目標は後続sliceも完了するまで継続する。Windows/Mac controller Herdr PoCを低権限workerの実証に転用しない。
