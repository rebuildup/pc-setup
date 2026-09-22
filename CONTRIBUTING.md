# Contributing to pc-setup

`pc-setup` は実環境の再現性を維持する repository です。変更では「その場で動く」だけでなく、fresh environment から同じ状態へ到達できることを優先します。

## Workflow

この repository は `project-init` の release-driven workflow に従います。

- `main`: released/integrated state
- `release-x-y-z`: sprint integration branch
- `<issue-number>`: ticket branch
- 1 top-level Issue = 1 ticket branch = 1 ticket PR
- ticket PR は通常 target release branch を base にする
- release PR のみが `main` を更新する
- PR は merge commit で land する
- squash merge / rebase merge は使用しない
- merge は explicit human authorization がある場合だけ実行する

## Documentation changes

セットアップ手順を変更するときは、最低限次を確認します。

1. その tool は実際の環境で使うものか。
2. official installation source はどこか。
3. install channel は latest stable 追従か、version pin か。
4. authentication / secret は repository 外に維持されるか。
5. bootstrap を再実行して既存設定を壊さないか。
6. verify で desired state を観測できるか。
7. 長寿命な判断なら ADR が必要か。

## Validation

```bash
./scripts/ci.sh
```

Ubuntu/WSL 実機では追加で:

```bash
./platforms/ubuntu-wsl/verify.sh
```

外部 installer、ログイン、WSL host integration は GitHub Actions だけでは証明できません。実機でしか確認できないものは、その境界を documentation に明記します。

## Secrets

次を commit しません。

- `.env` / API key
- GitHub token
- Claude / OpenCode provider credentials
- SSH private key
- browser cookie
- cloud credential
- machine-specific auth database

credential の保存場所を documentation に記す場合も、値そのものは記録しません。

## ADR

長期的な setup 方針は `docs/adr/ADR-NNNN.md` に記録します。既存 ADR を revise / supersede する場合は、新旧 ADR の両方から追跡できるようにしてください。
