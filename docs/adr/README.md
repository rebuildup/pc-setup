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
| [ADR-0011](./ADR-0011.md) | Accepted | Tailscale device provisioning は Infisical runtime injection を使用する |
| [ADR-0012](./ADR-0012.md) | Accepted | macOS keyboard baseline は hidutil と system LaunchDaemon で管理する |
| [ADR-0013](./ADR-0013.md) | Accepted | macOS のコンテナ実行環境は Colima と Homebrew Docker CLI で管理する |
| [ADR-0014](./ADR-0014.md) | Accepted | Orca は macOS の任意の worktree frontend とし、設定と Skill stub は Orca 自身が持つ |
| [ADR-0016](./ADR-0016.md) | Accepted | 採用（train）・配備（converge）・シェル（activate のみ）を分離し、OS スケジューラで main を配備する |

| [ADR-0021](./ADR-0021.md) | Accepted | Windows の Rust toolchain も mise が管理する |
| [ADR-0022](./ADR-0022.md) | Accepted | macOS のWizTreeMacを公式Tap経由でmise管理する |
| [ADR-0023](./ADR-0023.md) | Accepted | Vercel CLI は machine-global baseline に含めない |
| [ADR-0024](./ADR-0024.md) | Accepted | converge の verify 用に launchctl print 1件だけを NOPASSWD で許可する |
| [ADR-0025](./ADR-0025.md) | Accepted | Windows のツール所有は mise を唯一の正本とし、実行確認で壊れを検出する |
| [ADR-0026](./ADR-0026.md) | Accepted | Rex は OS 公式導入経路で管理し preview channel を追跡する |
| [ADR-0027](./ADR-0027.md) | Accepted | herdr-t3 は検証済み ref の独立リリース配置で導入・更新・復旧する |

新しい ADR は `ADR-NNNN.md` の連番で追加します。既存 decision を置換する場合は旧 ADR の status と `Superseded by` も更新します。
