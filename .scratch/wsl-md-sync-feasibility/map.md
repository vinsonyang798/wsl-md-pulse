Label: wayfinder:map

# 地图：WSL 下 Markdown 文档在 Windows 端同步显示——能不能走、怎么走

## Destination

一个可交接的**路线决策**：基于第一手事实判定"在 Windows 端实时同步显示 WSL 中的 Markdown 文档"是否可行（go / no-go / 直接用现成工具），若可行则锁定一条拓扑路线（进程跑在哪、文件变化怎么感知、画面怎么到 Windows），并列出这条路线的已知坑与验证结论。到达终点后才进入技术选型与详细设计。

## Notes

- **从零推导**：用户要求先忽略仓库已有结论。`docs/architecture.md`、`AGENTS.md` 里的方案（Go 单二进制 + React、WSL 内服务 + Windows 浏览器、轮询判定规则等）在本地图中**只算候选之一，不算前提**。等路线锁定后，再单独决定对现有文档保留还是推翻（见 Not yet specified）。
- 只做规划：每张票产出决策或事实，不写产品代码。
- 研究票用 `research` skill，研究笔记放在 `research/` 目录并从票据链接过去。
- 讨论票（grilling）必须和用户本人进行，同时使用 `grilling` 与 `domain-modeling` skill；agent 不替用户回答。
- Tracker：本地 markdown（`.scratch/wsl-md-sync-feasibility/`），约定见 `.cursor/skills/setup-matt-pocock-skills/issue-tracker-local.md`。

## Decisions so far

<!-- 每张已关闭票据一行：名称链接 + 一句话要点 -->

- [使用场景与"同步显示"的验收标准](issues/01-usage-scenario-and-acceptance.md)：笔记根目录只在 ext4，写入方是 WSL 内的 agent（codex cli）；要求独立预览页（自带目录树），1 秒内刷新，按阅读位置（标题段落）恢复，并提供可开关的跟随模式；需要 GFM、代码高亮、Mermaid、本地图片、相对链接，不需要数学；WSL 内只放单文件静态二进制，Windows 零安装。VS Code 内置预览经用户实测排除。术语见 `CONTEXT.md`。

- [现成方案盘点](issues/02-existing-solutions-survey.md)：现成方案已经可用（能接受编辑器内预览就用 VS Code + WSL 扩展；要独立浏览器页则 go-grip 最接近）。自己做的理由只剩：保留滚动位置、`/mnt/c` 与 ext4 都能刷新、零依赖、安全默认值。
- [现成工具对照验收标准的差距](issues/07-existing-tools-vs-acceptance.md)：没有工具满足全部验收标准。最接近的是 Vantage（安全默认值合格、局部刷新、有目录树），缺跟随模式和按阅读位置恢复，且项目小众；go-grip、markserv、mdserve 各有安全或功能硬伤。按标题恢复在所有工具中都要新写。
- [WSL2 文件变更检测的事实边界](issues/03-wsl-file-change-detection.md)：只有"WSL 内用 inotify 监听 ext4 上的目录"可靠；`/mnt/c` 上的 Windows 侧修改、以及 Windows 侧监听 `\\wsl.localhost`，都收不到原生通知，只能轮询。
- [Windows 侧访问 WSL 内服务与画面通道](issues/04-windows-to-wsl-display-channel.md)：WSL 内服务 + Windows 浏览器经 localhost 访问可行。前提是显式绑 `127.0.0.1`、客户端自动重连、打开浏览器用 `cmd.exe`/`powershell.exe` 并兜底打印 URL；反向方案（Windows 读 `\\wsl.localhost`、WSLg）只适合当备选。
- [真机实测：WSL2 监听与访问通道](issues/05-real-machine-verification.md)：用户机器（Win10 + WSL NAT）上这条拓扑可行："ext4 + inotify 监听目录 + WSL 内服务绑 `127.0.0.1` + Windows 浏览器访问"。codex 原地写、一阵写完就停。Vantage 推送约 101ms（持续密集写入时最坏 1 秒），但阅读位置按像素恢复（插入一节后偏一节）、刷新时白屏、没有跟随模式。持续写入期间"≤ 1 秒"的口径在"选定路线"中按实测结果接受。

- [选定路线](issues/06-choose-route.md)：**go，原样使用 Vantage v0.7.1**，外面包一层类似 `code .` 的 `mdv` 命令：每个目录一个实例，端口自动分配，用 `cmd.exe` 自动打开 Windows 浏览器，关闭终端标签页即停止。验收标准按 Vantage 的实际能力放宽（见验收标准票的"后续修订"）。原有的自研设计保留为备选，回到自研的触发条件写在票里。

## Handoff

终点已到达：路线已锁定。原先"未明确"的各项处理如下。

- **已随路线决定**：
  - 对现有设计文档：保留为自研备选，在 `docs/architecture.md` 和 `AGENTS.md` 开头注明。
  - 技术栈：沿用 Vantage 的，自研时再定。
  - 文件监听：由 Vantage 负责；第 2 批的约束留给自研备选。
  - 分发与启动：`mdv`。
  - 安全边界：接受 Vantage 的默认值和 CSRF 风险。
  - 跟随模式：降为以后的改进项。
  - 多根目录：每个目录一个实例。`/mnt/c` 不支持。
- **交付物**：`scripts/mdv`，用法和安装方法见脚本开头的注释。
- **交接后的验证**（不影响路线，结果不理想时再调整 `mdv` 或 `.wslconfig`）：
  - 睡眠、断网、空闲后能否恢复，以及关闭所有终端后的行为：运行 `windows-probe.ps1`，不加 `-SkipSleep`。
  - 真实项目目录的规模：运行 `wsl-probe.sh files --root <路径>`，或直接用 `mdv` 打开最大的项目看看。
  - VPN 的影响。

## Out of scope

- 写产品代码或搭项目脚手架：本地图的终点是路线决策，实现在交接之后。
- 在 Windows 侧直接编辑、或在 Windows 侧运行程序读 `\\wsl.localhost`：与"写入方是 WSL 内的 agent、Windows 零安装"的验收标准冲突（见[使用场景与"同步显示"的验收标准](issues/01-usage-scenario-and-acceptance.md)）。
