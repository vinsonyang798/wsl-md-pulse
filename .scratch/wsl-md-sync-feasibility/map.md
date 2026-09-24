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

## Not yet specified

- **对现有设计文档的取舍**：路线锁定后，`docs/architecture.md` 中哪些部分保留、哪些推翻、哪些需要改写。依赖"选定路线"。
- **路线内的技术栈**：语言、渲染库、前端框架等，只有拓扑确定后才能提成有意义的问题。
- **分发与启动方式**：用户如何安装、如何启动（CLI、常驻、编辑器命令、开机自启），Windows 侧是否需要安装任何东西。
- **安全边界**：取决于拓扑是否暴露网络端口、是否跨越 WSL/Windows 边界读文件。
- **"同步"的深度**：保存即刷新之外，是否要滚动位置保留、跟随编辑器光标、未保存内容预览——具体要求取决于使用场景讨论的结论和选定路线的能力。
- **规模与性能边界**：大目录（上万文件）、大文件、多个根目录时的行为。

## Out of scope

- 写产品代码或搭项目脚手架：本地图的终点是路线决策，实现在交接之后。
