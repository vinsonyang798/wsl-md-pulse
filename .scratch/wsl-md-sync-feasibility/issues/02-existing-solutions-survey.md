Type: research
Status: resolved
Blocked by:

# 现成方案盘点

## Question

已有哪些工具能让 WSL 中的 Markdown 在 Windows 端实时预览（保存后自动刷新）？每种工具的运行位置（WSL 内 / Windows 侧 / 编辑器内）、刷新机制、对 WSL 文件的支持情况、Markdown 特性覆盖（GFM、Mermaid、数学、本地图片、相对链接、目录树）、依赖（Node/Python/Go、Windows 安装）、维护状态分别是什么？是否存在某个现成方案已经够用，从而让"自己做"不必要？

候选（不限于）：VS Code 内置预览 + Remote-WSL、Markdown Preview Enhanced、grip、markserv、livemark/`live-server` 类、mdBook `serve`、MkDocs `serve`、`glow`（终端）、Obsidian/Typora 直接打开 `\\wsl.localhost` 路径、Neovim 的 `markdown-preview.nvim`/`peek.nvim`。

## Answer

**能用的现成方案已经有了；自己做是否值得，取决于使用场景要不要以下特性：独立浏览器页、保留滚动位置、`/mnt/c` 与 ext4 都能刷新、零运行时依赖、安全默认值。** 完整对比表与来源见 [研究笔记](../research/02-existing-solutions-survey.md)。

- 如果能接受在编辑器里看预览，**VS Code + WSL 扩展**（可再加 Markdown Preview Enhanced）已完全覆盖需求：边输入边刷新，Mermaid 和 KaTeX 内置，目录借用 Explorer。缺点是预览只能在 VS Code 里看；另有一个开放 bug：重新打开预览会显示旧内容（#331900）。
- 如果不想依赖编辑器，与需求最接近的是 **go-grip**：单个 Go 二进制，有文件树，支持 Mermaid 和数学，保存后整页 reload，至今仍活跃。它的缺口是：WebSocket 不校验 Origin；刷新是整页 reload，不保留滚动位置；依赖 inotify，所以用 Windows 编辑器修改 `/mnt/c` 上的文件时感知不到。
- **markserv**（Node）支持局部更新、有目录索引，但需要 Node，而且在 2019 到 2026 年间长期停更。
- **mdBook / MkDocs** 默认用轮询，`/mnt/c` 上的修改也能刷新，但要求先搭好 `SUMMARY.md` / `mkdocs.yml` 这类项目结构。
- **Windows 侧应用直接打开 `\\wsl.localhost` 不可靠**：Obsidian 打开 WSL 目录作 vault 时报 watch 错误；Typora 能否感知外部修改尚未确认。
- grip、gh-markdown-preview 依赖 GitHub 在线 API；live-server 不渲染 Markdown；glow 是终端工具；两个 nvim 插件都已停更。

待真机确认：go-grip 与 markserv 在 ext4 和 `/mnt/c` 上的实际刷新表现（已并入"真机实测：WSL2 监听与访问通道"）。
