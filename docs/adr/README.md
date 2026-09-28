# Architecture Decision Records

`pc-setup` の長寿命な environment / tooling / reproduction decision を記録します。

## Index

| ADR | Status | Decision |
| --- | --- | --- |
| [ADR-0001](./ADR-0001.md) | Accepted | Platform guide + bootstrap + verify を canonical reproduction model とする |
| [ADR-0002](./ADR-0002.md) | Superseded | Ubuntu/WSL2 baseline toolchain と旧 imperative installation channel |
| [ADR-0004](./ADR-0004.md) | Accepted | Windows 11のGUI/creative/development inventory boundary |
| [ADR-0005](./ADR-0005.md) | Accepted | macOS は real-machine observation まで candidate profile とする |
| [ADR-0003](./ADR-0003.md) | Accepted | NixOSをFlake + Home Managerで宣言的に再現 |
| [ADR-0006](./ADR-0006.md) | Accepted | NixOS以外のcross-platform bootstrapをmiseへ統一 |
| [ADR-0007](./ADR-0007.md) | Accepted | Open Code Review は検証可能な公式 GitHub Release binary から導入 |
| [ADR-0008](./ADR-0008.md) | Accepted | Windows Notion は mandatory WinGet phase ではなく公式 MSIX boundary で導入 |
| [ADR-0009](./ADR-0009.md) | Accepted | Windows desktop apps は best-effort convergence + strict verification で扱う |
| [ADR-0010](./ADR-0010.md) | Accepted | machine-global tools を continuous update train で日次検証・採用する |

新しい ADR は `ADR-NNNN.md` の連番で追加します。既存 decision を置換する場合は旧 ADR の status と `Superseded by` も更新します。
