# 现成方案盘点：WSL 中的 Markdown 在 Windows 端实时预览

- 对应票据：`issues/02-existing-solutions-survey.md`
- 调研日期：2026-09-24（所有"最近 release / commit"数据均为当日通过 GitHub API、npm registry、PyPI、crates.io 获取）
- 方法：只采信一手来源——官方文档、项目 README 与源码、官方 issue 跟踪器 / 官方论坛。每条结论后附来源；标"推断"的是根据源码或文档推理而来、未经实测的结论。
- 未做任何实机验证（实机验证属于票据 05）。

## 0. 先决事实：WSL 两侧的通道

这些事实决定了下面每个工具能否工作，所以先列出来。

| # | 事实 | 来源 |
|---|---|---|
| F1 | WSL 内运行的网络服务，可在 Windows 浏览器中直接用 `localhost` 访问（默认 NAT 模式的 localhost 转发；mirrored 模式同样支持）。 | https://learn.microsoft.com/en-us/windows/wsl/networking （"Accessing Linux networking apps from Windows (localhost)"） |
| F2 | 微软建议：用 Linux 工具处理的文件放在 WSL 文件系统里（而不是 `/mnt/c`），Windows 侧通过 `\\wsl$` 访问。 | https://learn.microsoft.com/en-us/windows/wsl/filesystems |
| F3 | Windows 侧 API `ReadDirectoryChangesW` 在 `\\wsl$` 路径上**不受支持**（issue 自 2021 年起未关闭）。Node/Electron 的 `fs.watch` 在 Windows 上依赖这个 API，所以 Windows 侧应用监听 WSL 文件的变化不可靠。 | https://github.com/microsoft/WSL/issues/7674 |
| F4 | WSL2 中，Windows 应用修改 `/mnt/c/...` 下的文件**不会**触发 Linux 侧 inotify（issue 自 2019 年起未关闭，180+ 条评论）。所以 WSL 内基于 inotify / fsnotify 的工具，对 `/mnt/c` 上由 Windows 编辑器保存的文件无法感知；轮询类工具不受影响。 | https://github.com/microsoft/WSL/issues/4739 |
| F5 | Windows → WSL 的 9P 访问明显更慢（issue 报告元数据访问约 26 倍、读取约 73 倍于原生）。 | https://github.com/microsoft/WSL/issues/41480 |

结论前置：**"服务端跑在 WSL 内 + 文件放在 WSL 的 ext4 上 + Windows 浏览器访问 localhost"是所有现成工具中最没有平台障碍的一条路**。Windows 侧应用直接打开 `\\wsl.localhost` 路径的方案，会受 F3 影响。

## 1. 对比表

图例：✅ 支持（有一手来源） · ⚠️ 部分支持或有条件 · ❌ 不支持 · ？ 未能从一手来源确认。

| 工具 | 运行位置 | 刷新机制 | WSL 文件支持 / 已知 WSL 问题 | GFM / 代码高亮 / Mermaid / 数学 | 本地图片 / 文档间相对链接 / 目录树浏览 | 运行时依赖 | 维护状态（2026-09-24） |
|---|---|---|---|---|---|---|---|
| VS Code 内置预览 + WSL 扩展 | 编辑器内（UI 在 Windows，扩展与文件访问在 WSL 内的 VS Code Server） | 编辑器缓冲区，边输入边更新；磁盘上的外部修改由 Server 端文件监听同步 | ✅ 官方方案；WSL1 有监听问题，官方给了 polling 开关；开放 bug：重新打开预览时显示旧内容（#331900，环境为 WSL2） | ✅ / ✅ / ✅（内置）/ ✅ KaTeX（内置） | ✅ / ✅ / ✅（借用 Explorer，不在预览页里） | Windows 装 VS Code；WSL 内自动装 Server；不需要 Node | 非常活跃（1.139.0，2026-09-23） |
| Markdown Preview Enhanced（VS Code 扩展） | 编辑器内（Remote-WSL 下运行在 WSL） | 编辑器缓冲区 | ⚠️ 预览本身可用；"Open in Browser"在 WSL 下无反应（#2284，2026-09 关闭）；WSL 下 Bash code chunk 有问题（#1902） | ✅ / ✅ / ✅ / ✅ KaTeX/MathJax | ✅ / ✅ / ✅（同样借用 Explorer） | 同 VS Code | 活跃（0.8.36，2026-09-20） |
| grip（Python） | WSL 内 HTTP 服务 | 服务端每 0.3s 轮询 mtime + SSE 推送 | ✅ 推断可用（轮询，F4 不影响）；未找到 WSL issue | 由 **GitHub 在线 API** 渲染，有速率限制；离线渲染是 WIP | ✅ / ✅（相对 URL）/ ❌ | Python + pip；需联网 | 停滞（最后 commit 2023-10，PyPI 4.6.2 发布于 2023-10） |
| markserv（Node） | WSL 内 HTTP 服务 | Node `fs.watch({recursive:true})`（Linux 上即 inotify）+ 150ms 防抖 + WebSocket，局部更新、不整页刷新 | ✅ 推断：ext4 可用；`/mnt/c` + Windows 编辑器会受 F4 影响；未找到 WSL issue | ✅ / ✅ highlight.js / ✅（客户端懒加载）/ ✅ MathJax | ✅ / ✅ / ✅ 目录索引页 | Node（递归 watch 在 Linux 上需 Node ≥ 19.1） | 近期复活：npm 1.20.0 发布于 2026-09-23 |
| go-grip（Go） | WSL 内 HTTP 服务 | `aarol/reload`（fsnotify，递归监听目录）+ WebSocket，整页 reload | ✅ 推断同 markserv；未找到 WSL issue | ✅ GitHub 风格 / ✅ chroma / ✅ / ✅ | ✅ / ✅ 推断 / ✅ 文件树页 | 单个 Go 二进制（`go install` 或 nix） | 活跃（v0.10.0，2026-09-07） |
| gh-markdown-preview（gh 扩展，Go） | WSL 内 HTTP 服务 | fsnotify 监听文件所在目录 + WebSocket | ⚠️ 2021 年有 WSL 用户报告 live reload 不工作（#5，已关闭） | 由 **GitHub 在线 API** 渲染；Mermaid / 数学 ？ | ？ / ？ / ❌（面向单个 README） | `gh` CLI；需联网 | 活跃（v1.11.2，2026-08-30） |
| mdopen（Rust） | WSL 内 HTTP 服务（默认 127.0.0.1:5032） | Rust `notify`（Linux 上即 inotify）递归监听 `.` + WebSocket | ✅ 推断同 markserv | ✅ pulldown-cmark：表格/任务列表/删除线 / ✅ / ？ / ✅ | ？ / ？ / ⚠️ 简单目录列表 | Rust（`cargo install`） | 小众（crates 0.6.0，2026-05；44★） |
| md-fileserver（Node） | WSL 内 HTTP 服务（localhost:4000，需会话 token） | 对已访问文件逐个 `fs.watch` + WebSocket | ✅ 推断同上 | ✅ / ✅ highlight.js / ？ / ✅ KaTeX | ✅ / ✅ / ✅（`serve-index`） | Node | 活跃（1.11.1，2026-08） |
| live-server / five-server（Node） | WSL 内 HTTP 服务 | chokidar + WebSocket | — | ❌ **不渲染 Markdown**，只服务 HTML | — | Node | live-server 停滞（2022）；five-server 0.5.0（2026-05） |
| mdBook `serve`（Rust） | WSL 内 HTTP 服务 | 默认 **poll（每秒扫描）**，可选 native；WebSocket 刷新 | ✅ 轮询不受 F4 影响；WSL1 端口绑定报错（#1321，2020） | ✅ / ✅ / ⚠️ 需插件 mdbook-mermaid / ⚠️ 仅 MathJax 选项 | ✅ / ✅ / ⚠️ 侧栏按 `SUMMARY.md`，不是自动目录树 | 单个 Rust 二进制 | 活跃（v0.5.4，2026-07；最后 commit 2026-09-18） |
| MkDocs `serve`（Python） | WSL 内 HTTP 服务 | watchdog `PollingObserver`（0.5s）+ livereload | ⚠️ click > 8.2.1 时 live reload 默认不生效，需显式 `--livereload`（#4032、#4055；WSL 场景 #4081） | ✅ Python-Markdown（需扩展）/ ✅ / ⚠️ 需插件或主题 / ⚠️ 需插件 | ✅ / ✅ / ✅ 未配 `nav` 时自动按目录生成导航 | Python + `mkdocs.yml` | 核心停滞（1.6.1，2024-08；最后 commit 2025-10）；Material 团队转向 Zensical |
| glow（Go TUI） | WSL 终端 | pager 里用 fsnotify 监听当前文件并自动 reload；也可按 `r` 手动 | ✅ 在 WSL 内跑 | 终端渲染：无 Mermaid / 数学 / 图片 | ❌ / ❌ / ✅ TUI 文件列表 | 单个 Go 二进制 | 活跃（v3.0.0，2026-08） |
| Obsidian 打开 `\\wsl.localhost` | Windows 侧应用 | 应用自带文件监听（Windows 上依赖 F3 的 API） | ❌ 打开 WSL 目录作为 vault 报 `EISDIR ... watch '\\wsl.localhost\...'`；支持 WSL vault 的功能请求 2020 年至今未解决 | ✅ / ✅ / ✅ / ✅ | ✅ / ✅（wikilink）/ ✅ | Windows 安装 Obsidian | 活跃（v1.13.8，2026-08），但 WSL 支持没有进展 |
| Typora 打开 `\\wsl.localhost` | Windows 侧应用 | 监听外部修改并提示或重载 | ⚠️ 官方回复"打开 WSL 文件是支持的"；WSL 下相对路径图片不显示（#4837/#5118，官方称 v1.5.x 已修）；外部修改在 `\\wsl$` 上能否被感知 ？（F3） | ✅ / ✅ / ✅ / ✅ | ✅ / ✅ / ✅ 文件树 | Windows 安装（付费） | 活跃（issue 仓库 2026 年仍有新 issue） |
| markdown-preview.nvim | 编辑器内（Neovim 在 WSL）+ WSL 内 Node 服务 + 浏览器 | 编辑器缓冲区（默认边输入边刷新；`mkdp_refresh_slow=1` 时保存才刷新） | ⚠️ README FAQ：WSL2 终端 Vim 下打不开浏览器（需 xdg-utils 或自定义 `mkdp_browserfunc`）；WSL2 启动很慢（#621）；`cmd.exe` 打开浏览器失败（#710） | ✅ / ✅ / ✅ / ✅ KaTeX | ✅ / ？ / ❌ | Node + yarn（或预编译包）；需 Vim/Neovim | 停滞（最后 commit 2023-10，v0.0.10 发布于 2022） |
| peek.nvim | 编辑器内（Neovim）+ Deno 服务，默认 webview 窗口（WSL 下需 WSLg），可改为浏览器 | 编辑器缓冲区（`update_on_change`） | ？ 未找到 WSL 专门 issue；webview 在 WSL 下依赖 WSLg（推断） | ✅ / ✅ / ✅ / ✅ KaTeX | ？ / ？ / ❌ | Deno + Neovim | 停滞（最后 commit 2024-04） |
| 其他：docsify-cli | WSL 内 HTTP 服务 | livereload | 推断可用 | 客户端渲染，Mermaid / 数学需插件 | 侧栏需手写 `_sidebar.md` | Node | 活跃（v5.0.0，2026-07） |
| 其他：Madness（Ruby） | WSL 内 HTTP 服务 | README 未提及 live reload ⇒ 视为 ❌ | — | ✅ / ✅ / ✅ 可选 / ？ | ✅ / ✅ / ✅ 自动侧栏 | Ruby | 活跃（v1.3.1，2026-07） |
| 其他：inlyne（Rust GUI） | WSL 内 GUI（需 WSLg）或 Windows 原生 | 文件监听 | 放在 Windows 侧读 `\\wsl$` 会受 F3 影响（推断） | ✅ / ✅ / ？ / ？ | ✅ / ？ / ❌ | Rust 二进制 | 活跃（v0.5.3，2026-08） |

## 2. 逐条来源

### 2.1 VS Code 内置预览 + WSL 扩展

- 预览可以并排打开，编辑时实时更新；默认跟随当前活动的 Markdown 文件；双击预览会跳到源码位置：https://code.visualstudio.com/docs/languages/markdown
- 同一页面写明：内置预览渲染 ` ```mermaid ` 代码块（支持平移、缩放），用 KaTeX 渲染 `$...$` / `$$...$$`（`markdown.math.enabled`）；支持路径补全、链接校验、跨文件标题链接。
- WSL 扩展会在 WSL 内安装 VS Code Server，"runs commands and other extensions directly in WSL"：https://code.visualstudio.com/docs/remote/wsl
- 同一页面的已知限制：WSL1 下文件监听引起 EACCES，可设 `remote.WSL.fileWatcher.polling`；"WSL 2 does not have that file watcher problem"。
- 开放 bug：Windows + WSL2 远程环境下，关闭后重新打开预览显示旧版本：https://github.com/microsoft/vscode/issues/331900
- 维护：microsoft/vscode 1.139.0 发布于 2026-09-23（GitHub API）。

### 2.2 Markdown Preview Enhanced（MPE）

- 功能：数学（KaTeX/MathJax）、Mermaid、PlantUML、Graphviz 等，本地渲染：https://github.com/shd101wyy/vscode-markdown-preview-enhanced （README）
- WSL 问题："Open in Browser" 在 Remote-WSL 下无反应：https://github.com/shd101wyy/vscode-markdown-preview-enhanced/issues/2284 （2026-09-22 关闭）；Bash code chunk 在 WSL 下不工作：https://github.com/shd101wyy/vscode-markdown-preview-enhanced/issues/1902
- 维护：0.8.36 发布于 2026-09-20；底层库 crossnote 0.9.39 同日发布（GitHub API）。

### 2.3 grip

- 使用 GitHub Markdown API 渲染；会触发 API 速率限制，可以用凭据提高配额；离线渲染"work in progress"；`AUTOREFRESH` 默认开启；"grip supports relative URLs"：https://github.com/joeyespo/grip （README）
- 刷新实现：`_render_refresh` 循环读取 `last_updated` 并 `time.sleep(0.3)`，即服务端轮询：https://github.com/joeyespo/grip/blob/master/grip/app.py
- 维护：最后 commit 2023-10-13；PyPI 4.6.2 发布于 2023-10-12（PyPI JSON API）。

### 2.4 markserv

- 功能：GitHub 风格 CSS、语法高亮、"Hot-reload as you edit"、"Directory indexes"、MathJax、TOC、表格；WebSocket 热更新"updates instantly without a full page reload"；Markdown 之间的链接可点击跳转：https://github.com/markserv/markserv （README）
- 刷新实现：`fs.watch(watchDir, {recursive: true}, ...)`，150ms 防抖；Mermaid 代码块输出为 `<pre class="mermaid">`，由客户端懒加载渲染；默认 `address: 'localhost'`：https://github.com/markserv/markserv/blob/master/lib/server.js 、https://github.com/markserv/markserv/blob/master/lib/cli-defs.js
- Node 在 Linux 上的递归 `fs.watch` 自 v19.1.0 起支持：https://github.com/nodejs/node/blob/main/doc/api/fs.md （`fs.watch` 的历史记录）
- 维护：npm 1.20.0 发布于 2026-09-23；上一个版本 1.17.4 发布于 2019-12-29，中间断档约 6 年；GitHub 仓库没有 Release 条目（npm registry）。

### 2.5 go-grip

- 功能：GitHub 风格、语法高亮、暗色模式、Mermaid、数学、GitHub alert/脚注/details；不依赖 GitHub API；`go-grip` 不带参数时显示当前目录的文件树（有 README.md 时直接打开它），可随时在 `http://localhost:6419` 浏览；`--no-reload` 可关闭自动刷新：https://github.com/chrishrb/go-grip （README）
- 刷新实现：`reload.New(directory)`（`github.com/aarol/reload`，递归监听目录，间接依赖 fsnotify）；WebSocket `CheckOrigin` 被设为恒返回 true：https://github.com/chrishrb/go-grip/blob/main/internal/server.go 、https://github.com/chrishrb/go-grip/blob/main/go.mod 、https://github.com/aarol/reload
- 维护：v0.10.0 发布于 2026-09-07（GitHub API）。

### 2.6 gh-markdown-preview

- 用 GitHub 官方 Markdown API 渲染、使用 GitHub CSS；live reload；默认监听 `localhost:3333`：https://github.com/yusukebe/gh-markdown-preview （README）
- 刷新实现：fsnotify 监听目录：https://github.com/yusukebe/gh-markdown-preview/blob/master/cmd/watcher.go
- WSL 用户报告 live reload 不工作（2021，已关闭）：https://github.com/yusukebe/gh-markdown-preview/issues/5
- 维护：v1.11.2 发布于 2026-08-30。

### 2.7 mdopen

- 不使用 GitHub API，本地编译；支持语法高亮、数学公式、hot-reload：https://github.com/immanelg/mdopen （README）
- 源码：`notify::RecommendedWatcher` 递归监听 `.`（`src/watch.rs`）；默认 host 为 127.0.0.1、端口 5032（`src/cli.rs`）；对目录生成 HTML 列表（`src/main.rs`）；pulldown-cmark 开启了表格、任务列表、删除线、数学（`src/markdown.rs`）。
- 维护：crates.io 0.6.0，2026-05-24。

### 2.8 md-fileserver

- GFM、KaTeX、highlight.js；"Automatic update in browser after saving edited file"；只接受本机访问，带会话参数：https://github.com/commenthol/md-fileserver （README）
- 刷新实现：对每个请求过的文件做 `fs.watch`（非递归）：https://github.com/commenthol/md-fileserver/blob/master/lib/watch.js
- 目录浏览靠 `serve-index` 依赖（npm registry 依赖列表）。维护：1.11.1，2026-08-28。

### 2.9 live-server / five-server

- live-server 是"development server with live reload"，用于 HTML/JS/CSS，README 未涉及 Markdown 渲染；ENOSPC 故障排查条目说明它依赖 inotify：https://github.com/tapio/live-server
- 维护：live-server 最后 commit 2022-04；five-server 0.5.0 发布于 2026-05（npm）。

### 2.10 mdBook `serve`

- "watches the book's src directory for changes, rebuilding the book and refreshing clients"；`--watcher`：`poll`（默认，每秒扫描）/ `native`（"may not be as reliable"）；默认 hostname 为 localhost:3000：https://rust-lang.github.io/mdBook/cli/serve.html
- WSL1 下端口绑定报错（开放）：https://github.com/rust-lang/mdBook/issues/1321
- 维护：v0.5.4 发布于 2026-07-06；最后 commit 2026-09-18。
- Mermaid 需第三方预处理器、导航取决于 `SUMMARY.md`，属于本文作者对 mdBook 的常识，未在本次调研中逐条核对官方文档（见"不确定项"）。

### 2.11 MkDocs `serve`

- CLI 文档列出 `--no-livereload`、`--dirty`、`-w/--watch`、`--watch-theme`：https://www.mkdocs.org/user-guide/cli/
- 源码使用 `watchdog.observers.polling.PollingObserver(timeout=polling_interval)`，默认 `polling_interval=0.5`：https://github.com/mkdocs/mkdocs/blob/master/mkdocs/livereload/__init__.py
- click > 8.2.1 时不再监听文件变化：https://github.com/mkdocs/mkdocs/issues/4032 ；需显式 `--livereload`：https://github.com/mkdocs/mkdocs/issues/4055 ；WSL ext4 上同一现象：https://github.com/mkdocs/mkdocs/issues/4081 （均为开放状态）
- 维护：PyPI 1.6.1 发布于 2024-08-30；最后 commit 2025-10-20。Material for MkDocs 团队的新项目 Zensical（v0.0.64，2026-09-22）：https://github.com/zensical/zensical

### 2.12 glow

- TUI 在当前目录（或 Git 仓库）里查找 Markdown 文件：https://github.com/charmbracelet/glow （README）
- pager 用 fsnotify 监听文件，收到 `reloadMsg` 时重新加载；快捷键 `r` 手动 reload：https://github.com/charmbracelet/glow/blob/master/ui/pager.go
- 维护：v3.0.0 发布于 2026-08-11。

### 2.13 Obsidian

- 在 `\\wsl$` 下新建或打开 vault 报 `EISDIR: illegal operation on a directory, watch '\\wsl.localhost\Ubuntu\home\...'`，官方版主把它指向已有的功能请求：https://forum.obsidian.md/t/cant-create-or-open-vault-in-wsl-folder/34688
- 功能请求 "Support for vaults in WSL"（2020-11 起，79 帖，2026-09-16 仍有人跟帖"almost six years with no movement"）：https://forum.obsidian.md/t/support-for-vaults-in-windows-subsystem-for-linux-wsl/8580
- 官方帮助仓库里只有针对"network drive"的修复记录（例如 1.13.5 "Fixed vaults on network drives not working"），没有 WSL 相关说明：https://github.com/obsidianmd/obsidian-help （`Release notes/v1.13.5.md`）

### 2.14 Typora

- 官方文档：Typora 会监听已打开文件夹的变化并自动更新文件树，异常时可手动刷新：https://support.typora.io/File-Management/
- 官方维护者回复"open files in wsl is supported, but has issue #4837"：https://github.com/typora/typora-issues/issues/4873
- WSL 下相对路径图片加载失败，维护者回复"fixed in v1.5.x"：https://github.com/typora/typora-issues/issues/4837 、https://github.com/typora/typora-issues/issues/5118
- 外部修改提示 / 重载功能存在，但仍有相关 bug：https://github.com/typora/typora-issues/issues/6525

### 2.15 markdown-preview.nvim

- 功能：KaTeX、Mermaid、本地图片等；`g:mkdp_refresh_slow` 默认 0（边编辑边刷新），设为 1 则保存或离开插入模式时刷新；默认只监听 127.0.0.1；可设 `mkdp_browserfunc`：https://github.com/iamcco/markdown-preview.nvim （README）
- README FAQ："WSL 2 issue: Can not open browser when using WSL 2 with terminal Vim"。相关 issue：WSL2 启动约 20 秒 https://github.com/iamcco/markdown-preview.nvim/issues/621 ；`cmd.exe` 打开浏览器失败 https://github.com/iamcco/markdown-preview.nvim/issues/710
- 维护：最后 commit 2023-10-17；v0.0.10 发布于 2022-05。

### 2.16 peek.nvim

- 依赖 Deno；KaTeX、Mermaid；`update_on_change`；默认用 webview 窗口，可设 `app = 'browser'`：https://github.com/toppair/peek.nvim （README）
- 维护：最后 commit 2024-04-09。

### 2.17 其他

- docsify-cli：本地 livereload 服务：https://github.com/docsifyjs/docsify-cli （v5.0.0，2026-07）
- Madness：自动侧栏、TOC、可选 Mermaid；README 未提 live reload：https://github.com/DannyBen/madness
- inlyne：GPU 渲染的 Markdown 查看器，不依赖浏览器：https://github.com/Inlyne-Project/inlyne
- GitHub 搜索"markdown preview live reload server"还能找到大量个人小项目（多为 0–5★），不纳入评估。

## 3. 结论

**是否已有现成方案足以满足"WSL 文件 + Windows 端 + 保存即刷新 + 目录浏览"？**

有，而且不止一个，但各有缺口：

1. **编辑器内方案（VS Code + WSL 扩展，可加 MPE）已完全满足**：文件在 WSL、界面在 Windows、实时刷新、Mermaid/KaTeX 内置、目录树用 Explorer。缺口：
   - 预览必须在 VS Code 里看，不是独立的浏览器标签页；
   - 默认跟随当前编辑的文件；
   - 如果用户的编辑器不是 VS Code（例如 WSL 内的 Vim），需要为了预览专门开一个 VS Code 窗口；
   - 有"重开预览显示旧内容"的开放 bug。
2. **WSL 内 HTTP 服务 + Windows 浏览器**这条路没有平台障碍（F1），关键在于选对工具：
   - **go-grip**：单个 Go 二进制，自带文件树、Mermaid、数学、自动刷新，维护活跃，与需求最接近。缺口：整页 reload（不保留滚动位置，推断）；WebSocket 不校验 Origin；依赖 fsnotify，对 `/mnt/c` 上由 Windows 编辑器保存的文件无效（F4）；较小众（173★）。
   - **markserv**：目录索引、热更新且不整页刷新、MathJax、Mermaid，2026-09 刚发新版。缺口：需要 Node；同样受 F4 影响；长期维护连续性未知（npm 上 1.17.4 发布于 2019-12，之后直到 2026-09-23 才连发 1.19.1、1.20.0）。
   - **mdBook / MkDocs**：默认轮询，能覆盖 `/mnt/c` 场景。缺口：都是"站点生成器"，需要 `SUMMARY.md` 或 `mkdocs.yml` 这类项目结构，不适合"随手预览任意目录"；MkDocs 还需要 `--livereload` 规避 click 的 bug，而且核心项目处于停滞状态。
   - grip 与 gh-markdown-preview 依赖 GitHub 在线 API，也没有目录树，不适合离线或内网场景。
3. **Windows 侧应用直接打开 `\\wsl.localhost` 路径的方案不可靠**：Obsidian 明确不支持（打开 vault 时 watch 报错，功能请求近 6 年未解决）；Typora 能打开文件，但外部修改能否被感知取决于 F3，未确认。
4. **终端 / Neovim 方案**：glow 能自动 reload，但不渲染图片、Mermaid、数学；markdown-preview.nvim 与 peek.nvim 只能配合 Vim 缓冲区使用，WSL 下打开浏览器有已知问题，而且两者都已停止维护。

**总体判断**：只看"能不能用"，现成方案（VS Code + WSL，或 WSL 内的 go-grip / markserv）已经够用，"自己做"并非必需。"自己做"的理由只可能来自以下差异化需求，需要在票据 01（使用场景与验收）里确认是否真的重要：

- 不依赖编辑器的独立浏览器预览；
- 刷新时保留滚动位置、不整页刷新；
- 同时覆盖 ext4 与 `/mnt/c`（inotify 与轮询自动切换）；
- 单个二进制、零运行时依赖，同时具备目录树、Mermaid、数学；
- 安全默认值（只绑定本机、校验 WebSocket Origin、路径越界检查）。

现有工具里，没有一个同时满足上面全部条件。

## 4. 不确定项（需要实机验证或进一步查证）

1. go-grip、markserv、mdopen、md-fileserver 在 WSL2 ext4 上的实际刷新表现，以及对 `/mnt/c` + Windows 编辑器保存的表现，都是根据源码（inotify 类监听）和 F4 推断的，**未实测**。应交给票据 05。
2. go-grip 刷新后能否保留滚动位置、文档间 `.md` 相对链接能否点击跳转（README 未明示，推断可以）。
3. Typora、Obsidian 以外的 Windows 侧应用，在 `\\wsl.localhost` 上能否收到外部修改通知：F3 只说明 `ReadDirectoryChangesW` 不受支持，应用是否另有轮询兜底未知。
4. gh-markdown-preview 与 grip 经 GitHub API 渲染时，Mermaid 与数学能否在本地页面正确显示（GitHub 网页上的 Mermaid/数学依赖前端脚本，API 返回的 HTML 未必包含）。
5. mdBook 的 Mermaid/KaTeX 支持细节和导航规则，本次未逐条核对官方文档页面。
6. VS Code 内置预览对"WSL 内其他程序修改文件"的同步时延，以及 #331900 的触发条件，未实测。
7. 各项目的"维护状态"只反映 2026-09-24 当天的发布和 commit 时间，不代表长期维护承诺。
