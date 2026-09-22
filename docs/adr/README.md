# Architecture Decision Records

`pc-setup` の長寿命な environment / tooling / reproduction decision を記録します。

## Index

| ADR | Status | Decision |
| --- | --- | --- |
| [ADR-0001](./ADR-0001.md) | Accepted | Platform guide + bootstrap + verify を canonical reproduction model とする |
| [ADR-0002](./ADR-0002.md) | Accepted | Ubuntu/WSL2 baseline toolchain と official installation channel |
| [ADR-0003](./ADR-0003.md) | Accepted | NixOS declarative stable-system / unstable-tooling profile |

新しい ADR は `ADR-NNNN.md` の連番で追加します。既存 decision を置換する場合は旧 ADR の status と `Superseded by` も更新します。
