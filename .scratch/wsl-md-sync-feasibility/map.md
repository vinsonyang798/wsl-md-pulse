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

- [现成方案盘点](issues/02-existing-solutions-survey.md)：现成方案已经可用（能接受编辑器内预览就用 VS Code + WSL 扩展；要独立浏览器页则 go-grip 最接近）。自己做的理由只剩：保留滚动位置、`/mnt/c` 与 ext4 都能刷新、零依赖、安全默认值。
- [WSL2 文件变更检测的事实边界](issues/03-wsl-file-change-detection.md)：只有"WSL 内用 inotify 监听 ext4 上的目录"可靠；`/mnt/c` 上的 Windows 侧修改、以及 Windows 侧监听 `\\wsl.localhost`，都收不到原生通知，只能轮询。
- [Windows 侧访问 WSL 内服务与画面通道](issues/04-windows-to-wsl-display-channel.md)：WSL 内服务 + Windows 浏览器经 localhost 访问可行。前提是显式绑 `127.0.0.1`、客户端自动重连、打开浏览器用 `cmd.exe`/`powershell.exe` 并兜底打印 URL；反向方案（Windows 读 `\\wsl.localhost`、WSLg）只适合当备选。

## Not yet specified

- **对现有设计文档的取舍**：路线锁定后，`docs/architecture.md` 中哪些部分保留、哪些推翻、哪些需要改写。依赖"选定路线"。
- **路线内的技术栈**：语言、渲染库、前端框架等，只有拓扑确定后才能提成有意义的问题。
- **分发与启动方式**：用户如何安装、如何启动（CLI、常驻、编辑器命令、开机自启），Windows 侧是否需要安装任何东西。已知约束：关掉所有 WSL 终端后实例会自动停止（`instanceIdleTimeout`），常驻服务会随之消失。
- **安全边界**：取决于拓扑是否暴露网络端口、是否跨越 WSL/Windows 边界读文件。
- **"同步"的深度**：保存即刷新之外，是否要滚动位置保留、跟随编辑器光标、未保存内容预览——具体要求取决于使用场景讨论的结论和选定路线的能力。
- **规模与性能边界**：大目录（上万文件）、大文件、多个根目录时的行为。

## Out of scope

- 写产品代码或搭项目脚手架：本地图的终点是路线决策，实现在交接之后。
