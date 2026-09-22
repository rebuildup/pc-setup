# Architecture Decision Records

`pc-setup` の長寿命な environment / tooling / reproduction decision を記録します。

## Index

| ADR | Status | Decision |
| --- | --- | --- |
| [ADR-0001](./ADR-0001.md) | Accepted | Platform guide + bootstrap + verify を canonical reproduction model とする |
| [ADR-0002](./ADR-0002.md) | Accepted | Ubuntu/WSL2 baseline toolchain と official installation channel |
| [ADR-0004](./ADR-0004.md) | Accepted | Windows complete application inventory と mixed installation channels |
| [ADR-0005](./ADR-0005.md) | Accepted | macOS は real-machine observation まで candidate profile とする |

新しい ADR は `ADR-NNNN.md` の連番で追加します。既存 decision を置換する場合は旧 ADR の status と `Superseded by` も更新します。
