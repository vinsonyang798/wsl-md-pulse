Type: research
Status: open
Blocked by:

# 现成方案盘点

## Question

已有哪些工具能让 WSL 中的 Markdown 在 Windows 端实时预览（保存后自动刷新）？每种工具的运行位置（WSL 内 / Windows 侧 / 编辑器内）、刷新机制、对 WSL 文件的支持情况、Markdown 特性覆盖（GFM、Mermaid、数学、本地图片、相对链接、目录树）、依赖（Node/Python/Go、Windows 安装）、维护状态分别是什么？是否存在某个现成方案已经够用，从而让"自己做"不必要？

候选（不限于）：VS Code 内置预览 + Remote-WSL、Markdown Preview Enhanced、grip、markserv、livemark/`live-server` 类、mdBook `serve`、MkDocs `serve`、`glow`（终端）、Obsidian/Typora 直接打开 `\\wsl.localhost` 路径、Neovim 的 `markdown-preview.nvim`/`peek.nvim`。
