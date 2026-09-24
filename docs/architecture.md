# wsl-md-pulse 架构设计

> 本文档是**约束性文档**：后续代码必须符合这里的目录划分、依赖方向和接口定义。
> 需要打破约束时，先改这份文档（写明原因），再改代码。

## 0. 产品边界

- **做什么**：在 WSL2 里运行的 Markdown **只读**预览服务。`mdview <文件或目录>` 启动，Windows 浏览器打开 `http://localhost:<port>`，左侧目录树列出根目录下所有 `.md`，右侧渲染预览；文件变化后实时推送刷新，保留滚动位置。
- **不做什么**：编辑、多用户、鉴权、远程访问、云同步、数据库。
- **运行形态**：**单个 Go 静态二进制**（`CGO_ENABLED=0`，前端资源经 `go:embed` 打包在内）。WSL 里运行时**不需要 Node.js**；Node 只在开发机上用于构建前端。
- **运行环境**：服务端 Linux（WSL2 为主，普通 Linux/macOS 也应可运行），amd64 与 arm64；前端运行在 Windows 浏览器（Edge/Chrome/Firefox 最新版）。
- **只监听本机**：HTTP 默认绑定 `127.0.0.1`（WSL2 的 localhost 转发会把它暴露给 Windows）。

## 1. 技术选型（已定，不随意替换）

### 1.1 服务端（Go ≥ 1.24）

| 用途 | 选型 | 依据 / 备注 |
|---|---|---|
| HTTP | 标准库 `net/http`（`ServeMux` 方法+路径模式） | 路由很少，不引入 gin/echo/chi |
| WebSocket | `github.com/coder/websocket` | 维护活跃、支持 `context`，与 HTTP 同端口 upgrade |
| 文件监听 | `github.com/fsnotify/fsnotify` + **自研**递归/防抖/轮询层 | fsnotify 不递归、不合并原子保存、无轮询，这三点在 `platform/watch` 自己实现 |
| Markdown | `github.com/yuin/goldmark` + `extension.GFM` | CommonMark 兼容，AST 带源码字节区间，可换算行号 |
| 代码高亮 | `github.com/yuin/goldmark-highlighting/v2`（chroma v2），输出 CSS class 而非内联样式 | 主题切换只换 CSS |
| HTML 净化 | `github.com/microcosm-cc/bluemonday`（仅 `allowHtml=true` 时） | 默认不输出原始 HTML，无需净化 |
| CLI | 标准库 `flag` | 零依赖 |
| 日志 | 标准库 `log/slog` | |
| 测试 | 标准库 `testing`（+ `testing/fstest`） | 不引入断言库 |
| 静态检查 | `golangci-lint`（含 `depguard`）+ 自有架构测试 `internal/archtest` | 见第 3 节 |
| TS 类型生成 | `github.com/gzuidhof/tygo` | 从 `internal/core/protocol` 生成 `web/src/gen/protocol.ts` |

### 1.2 前端

| 用途 | 选型 | 备注 |
|---|---|---|
| 构建 | Vite | 产物输出到 `web/dist`，由 Go 嵌入 |
| 语言 | TypeScript（strict） | |
| UI | React | 仅管理外壳（目录树、TOC、设置、状态条）；**预览 HTML 不交给 React 渲染** |
| 样式 / 组件 | Tailwind CSS + shadcn/ui | 原子组件放 `web/src/components/ui` |
| 状态 | 每个 feature 一个小 store + `useSyncExternalStore` | 不引入 Redux/Zustand/MobX |
| 懒加载 | Mermaid、KaTeX 在文档需要时动态 `import()` | 控制首屏体积 |
| 测试 | Vitest + Testing Library | |
| 依赖检查 | ESLint + `dependency-cruiser` | 见第 3 节 |

新增任何运行时依赖（Go module 或前端 `dependencies`）必须先更新本节表格。

## 2. 目录结构

```text
/
├─ AGENTS.md                     # 硬性规则摘要
├─ docs/architecture.md          # 本文件
├─ go.mod
├─ Makefile                      # dev / build / test / lint / gen
├─ .golangci.yml
├─ tygo.yaml
├─ cmd/
│  └─ mdview/main.go             # 仅：解析 flag → 调 app.Run；不写任何逻辑
├─ internal/
│  ├─ app/                       # 组装层（composition root）
│  │  ├─ app.go                  # Run()：创建平台实现、注入依赖、启动/优雅关闭
│  │  ├─ config.go               # flag + 设置合并后的不可变 Config
│  │  └─ httpapi/                # HTTP 适配器：路由、请求解析、错误翻译、静态资源
│  ├─ core/                      # 纯逻辑：无 I/O
│  │  ├─ relpath/                # RelPath 类型、规范化、越界判断（纯字符串）
│  │  ├─ doctree/                # 目录树数据结构、排序、增量更新（纯函数）
│  │  ├─ render/                 # goldmark 管线
│  │  │  ├─ render.go
│  │  │  └─ ext/                 # sourceline / anchor / assetlink / diagram（每个一个文件）
│  │  ├─ protocol/               # HTTP/WS 的 DTO 与消息类型（tygo 生成 TS 的来源）
│  │  └─ domainerr/              # 领域错误码
│  ├─ features/                  # 用例层
│  │  ├─ tree/                   # 目录树索引：初次扫描 + 消费监听事件
│  │  ├─ preview/                # 读取 + 渲染 + 缓存 + 文档版本
│  │  ├─ assets/                 # 安全提供 md 引用的图片等文件
│  │  └─ settings/               # 设置读取、校验、默认值
│  ├─ platform/                  # 平台能力
│  │  ├─ ports.go                # 端口接口与值类型（只有定义，无实现）
│  │  ├─ osfs/                   # FileSystem 实现
│  │  ├─ watch/                  # Watcher 实现：fsnotify 递归 + 防抖 + 轮询
│  │  ├─ mounts/                 # 解析 /proc/self/mounts
│  │  ├─ browser/                # 打开 Windows 浏览器
│  │  ├─ sysenv/                 # WSL 检测、配置目录
│  │  └─ fake/                   # 测试用内存实现
│  ├─ storage/                   # JSON 状态文件（无数据库）
│  │  ├─ schema.go
│  │  └─ jsonstore.go
│  ├─ livesync/                  # WebSocket hub、会话、订阅、推送
│  │  ├─ hub.go                  # （不叫 sync，避免与标准库 sync 冲突）
│  │  └─ session.go
│  └─ archtest/                  # 架构测试：校验第 3 节依赖规则
├─ web/                          # 前端（Vite 工程）；同时是 Go 包，负责 embed
│  ├─ embed.go                   # package web；//go:embed all:dist
│  ├─ package.json
│  ├─ vite.config.ts
│  ├─ index.html
│  └─ src/
│     ├─ main.tsx
│     ├─ app/                    # 根组件、布局、URL ↔ 当前文档
│     ├─ features/
│     │  ├─ tree/                # 左侧目录树
│     │  ├─ preview/             # 右侧预览、滚动恢复、TOC、懒加载 Mermaid/KaTeX
│     │  └─ settings/            # 主题、字号
│     ├─ sync/                   # 唯一的 WebSocket 客户端
│     ├─ api/                    # 唯一的 HTTP 客户端
│     ├─ gen/protocol.ts         # tygo 生成，禁止手改
│     ├─ components/ui/          # shadcn/ui 原子组件
│     └─ lib/                    # 纯工具
└─ testdata/                     # 跨模块 fixtures（md 样例目录、渲染快照）
```

### 2.1 每个目录的职责

| 目录 | 负责 | 明确不负责 |
|---|---|---|
| `cmd/mdview` | 程序入口，调用 `app.Run(ctx, args)` 并以其返回值作为退出码 | 任何逻辑 |
| `internal/app` | 合并 flag 与设置得到 `Config`；**唯一**创建平台实现并注入 features/livesync；信号处理与优雅关闭；打开浏览器 | 业务判断（哪些文件算 md、如何渲染） |
| `internal/app/httpapi` | 把 HTTP 请求翻译成 feature 调用、把结果/错误翻译成响应；挂载 `/ws` 到 livesync；托管嵌入的前端 | 读文件、渲染 |
| `internal/core/*` | 纯数据结构与纯函数 | 任何 I/O、时间、goroutine |
| `internal/features/tree` | 启动扫描根目录生成 `doctree.Tree`；消费 `Watcher` 事件增量更新；对外发 tree 变化 | 推送给浏览器 |
| `internal/features/preview` | 按 `RelPath` 读取、调用 `core/render`、LRU 缓存、维护 `docVersion`；对外发 doc 变化 | 决定推给哪些客户端 |
| `internal/features/assets` | 校验相对资源路径并返回可读流与 MIME | 目录列表 |
| `internal/features/settings` | 设置的默认值、校验、更新 | 文件格式（交给 storage） |
| `internal/platform` | 所有与 OS 打交道的代码；对上只暴露 `ports.go` | 业务规则 |
| `internal/storage` | 状态文件读写、原子替换、schema 迁移 | 设置的业务含义 |
| `internal/livesync` | WS 连接、会话订阅表、按订阅路由事件、心跳 | 渲染、读文件 |
| `internal/archtest` | 用 `go list -deps -json ./...` 校验包依赖方向 | — |
| `web/src/app` | 根组件、布局、URL 状态 | 直接 `fetch` / 直接用 WebSocket |
| `web/src/features/*` | 各自 UI 与 store | 跨 feature 直接 import |
| `web/src/sync` / `web/src/api` | 唯一的 WS / HTTP 客户端 | UI |

## 3. 模块依赖规则（谁能调用谁）

依赖只能**自上而下**（箭头 = 可以 import）：

```text
cmd/mdview ──► internal/app ──┬──► internal/app/httpapi ──┐
                              │                           ▼
                              ├──────────────► internal/livesync ──► internal/features/* ──┬──► internal/storage
                              │                                                            │        │
                              ├──► internal/platform/<impl>  ─┐                            ▼        ▼
                              │                               └────────────►  internal/platform（ports.go）
                              └──► web（embed）                                            │
                                                                                           ▼
                                                                              internal/core/*
```

### 3.1 服务端规则表

| 包 | 允许 import | 禁止 import |
|---|---|---|
| `internal/core/...` | 标准库中**无 I/O** 的包（`strings`、`bytes`、`sort`、`path`（非 `path/filepath`）、`unicode`…）、goldmark 系、bluemonday、`core` 内其他包 | `os`、`os/exec`、`io/fs`、`net/...`、`path/filepath`、`time.Now` 的使用、`internal/` 下其他任何目录 |
| `internal/platform`（ports.go） | `core/...`、`context`、`io`、`time` | 其他一切 |
| `internal/platform/<impl>` | `platform`、`core/...`、标准库、fsnotify | `features`、`storage`、`livesync`、`app` |
| `internal/storage` | `platform`（接口）、`core/...`、`encoding/json` | `platform/<impl>`、`features`、`livesync`、`app` |
| `internal/features/<x>` | `platform`（接口）、`storage`、`core/...`、**其他 feature 的包根**（非子包） | `platform/<impl>`、`livesync`、`app`、`os`、`net/...` |
| `internal/livesync` | `features/...`、`core/...`、coder/websocket | `platform/...`、`storage`、`app` |
| `internal/app/httpapi` | `features/...`、`livesync`、`core/...`、`web` | `platform/<impl>`、`storage` |
| `internal/app` | 全部 | —（但不得包含业务逻辑） |
| `internal/archtest` | 标准库 | — |

补充规则：

1. **只有 `internal/app` 可以构造 `platform/<impl>`**；其他包的构造函数只接收 `platform` 中的接口。
2. **`os`、`os/exec`、`path/filepath`、`io/fs`、`fsnotify` 只允许出现在 `internal/platform/<impl>`**（以及 `internal/app` 的信号/退出处理、`cmd`）。
3. 包级可变全局变量禁止（`var x = ...` 仅允许常量性质的值，如正则、表）。
4. 禁止 `init()` 中做 I/O 或注册副作用。
5. 规则由 `internal/archtest`（`go test ./internal/archtest`）强制；`golangci-lint` 的 `depguard` 做同样的快速检查。二者任一失败即不可合并。

### 3.2 前端规则表

| 模块 | 允许 import | 禁止 import |
|---|---|---|
| `web/src/gen` | — | 一切（生成文件） |
| `web/src/lib` | 无 | 项目内其他目录 |
| `web/src/api`、`web/src/sync` | `gen`、`lib` | `features`、`app`、`components` |
| `web/src/components/ui` | `lib` | `features`、`api`、`sync`、`app` |
| `web/src/features/<x>` | `api`、`sync`、`components`、`lib`、`gen` | 其他 `features/<y>` |
| `web/src/app` | 全部 | — |

由 `dependency-cruiser`（`npm run lint:deps`）强制执行。

## 4. 状态放在哪里

原则：**每份状态只有一个所有者**；其他地方只读快照（值拷贝）或订阅事件。

### 4.1 服务端（内存）

| 状态 | 所有者 | 形态 | 并发保护 |
|---|---|---|---|
| 根目录绝对路径（已 `EvalSymlinks`） | `app.Config` | 不可变值 | 无需 |
| 目录树 `doctree.Tree` + `treeVersion` | `features/tree.Service` | 不可变快照；每次更新生成新快照替换指针 | `atomic.Pointer` 读 / 单 goroutine 写 |
| 渲染缓存 | `features/preview.Service` | LRU（默认 50 篇），key=`RelPath`，值含 `mtime`、`size`、`version`、`html`、`toc` | `sync.Mutex` |
| 文档版本号 | `features/preview.Service` | 每篇单调递增 `uint64` | 同上 |
| 会话订阅表 | `livesync.Hub` | `map[sessionID]*session`，每会话一个当前 `RelPath` | Hub 单 goroutine 事件循环 |
| 监听句柄 | `platform/watch` | fsnotify watcher 或轮询 goroutine | 内部 |

- 服务端**不保存**任何 UI 状态（滚动位置、展开节点）。
- 所有内存状态都能从文件系统重建。
- 所有长期 goroutine 必须接收 `context.Context`，`app.Run` 退出前等待全部结束（`errgroup` 语义，可用标准库自行实现）。

### 4.2 服务端（持久化）

只有用户设置，见第 5 节。

### 4.3 浏览器

| 状态 | 位置 | 说明 |
|---|---|---|
| 当前打开的文档 | **URL** `/?path=<RelPath>` | 唯一真相；刷新、前进后退都可用 |
| 目录树数据 | `features/tree` store | 来自 `GET /api/tree` + `tree.changed` 推送 |
| 目录展开状态 | `sessionStorage` `mdpulse:expanded` | 标签页级 |
| 每篇滚动位置 | `sessionStorage` `mdpulse:scroll:<RelPath>` = **源码行号** | 存行号不存像素，内容变化后仍能对齐 |
| 主题 / 字号 | 服务端设置为准；`localStorage` 仅首屏缓存防闪烁 | |
| WS 连接状态 | `sync` store：`connecting / open / reconnecting / offline` | 状态条展示 |

## 5. 数据存储（"数据库表"）

**本项目不使用数据库**（包括 SQLite）。数据只有少量设置；目录树与渲染结果随时可从文件系统重建，持久化它们只会产生一致性问题。

持久化为单个 JSON 文件：

- 路径：`$XDG_CONFIG_HOME/wsl-md-pulse/state.json`，默认 `~/.config/wsl-md-pulse/state.json`，文件权限 `0600`
- 写入：写 `state.json.tmp` → `fsync` → `rename`（原子替换）
- 损坏：重命名为 `state.json.corrupt-<unix>`，使用默认值继续运行，打印一条 warn

逻辑"表"（新增/修改字段必须同步更新本节与 `internal/storage/schema.go`，并提升 `SchemaVersion`、编写迁移函数与测试）：

```go
// internal/storage/schema.go
const SchemaVersion = 1

type StateFile struct {
    SchemaVersion int          `json:"schemaVersion"`
    Settings      Settings     `json:"settings"`     // 表 settings：单行
    RecentRoots   []RecentRoot `json:"recentRoots"`  // 表 recent_roots：≤ 20 条，按 LastOpenedAt 倒序
}

type Settings struct {
    Theme          string   `json:"theme"`          // "system" | "light" | "dark"
    FontSize       int      `json:"fontSize"`       // 12–24
    AllowHTML      bool     `json:"allowHtml"`      // 默认 false；开启后经 bluemonday
    PollIntervalMs int      `json:"pollIntervalMs"` // 轮询间隔，默认 300，范围 100–5000
    Ignore         []string `json:"ignore"`         // 额外忽略的目录名
}

type RecentRoot struct {
    Path         string    `json:"path"`         // Linux 绝对路径
    LastOpenedAt time.Time `json:"lastOpenedAt"`
    LastDoc      string    `json:"lastDoc"`      // RelPath，可为空
}
```

## 6. 接口定义

**唯一来源**：`internal/core/protocol/*.go`。前端类型由 `make gen`（tygo）生成到 `web/src/gen/protocol.ts`，CI 检查生成结果与提交一致。改接口 = 改 Go 结构体 → `make gen` → 同步本节。

### 6.1 基础类型

```go
// internal/core/protocol

// RelPath：相对根目录的 POSIX 路径，不以 / 开头，不含 . 或 .. 段。根目录为 ""。
type RelPath = string

type NodeKind string // "dir" | "file"

type TreeNode struct {
    Path     RelPath    `json:"path"`
    Name     string     `json:"name"`
    Kind     NodeKind   `json:"kind"`
    Children []TreeNode `json:"children,omitempty"` // 仅 dir；目录优先 + 自然排序
}

type TocItem struct {
    Level int    `json:"level"` // 1–6
    ID    string `json:"id"`
    Text  string `json:"text"`
    Line  int    `json:"line"`  // 1-based 源码行号
}

type DocFeatures struct {
    Mermaid bool `json:"mermaid"`
    Math    bool `json:"math"`
}

type RenderedDoc struct {
    Path     RelPath     `json:"path"`
    Version  uint64      `json:"version"`
    MtimeMs  int64       `json:"mtimeMs"`
    HTML     string      `json:"html"`     // 已安全处理的片段，不含 <html>/<body>
    Toc      []TocItem   `json:"toc"`
    Features DocFeatures `json:"features"`
}

type ErrorCode string // 见下
const (
    ErrNotFound    ErrorCode = "NOT_FOUND"
    ErrOutsideRoot ErrorCode = "OUTSIDE_ROOT"
    ErrNotMarkdown ErrorCode = "NOT_MARKDOWN"
    ErrTooLarge    ErrorCode = "TOO_LARGE"
    ErrReadFailed  ErrorCode = "READ_FAILED"
    ErrBadRequest  ErrorCode = "BAD_REQUEST"
)

type APIError struct {
    Code    ErrorCode `json:"code"`
    Message string    `json:"message"`
}
```

### 6.2 HTTP

| 方法 路径 | 返回 | 说明 |
|---|---|---|
| `GET /api/health` | `{ ok, version, root, watchMode: "native"\|"polling" }` | |
| `GET /api/tree` | `{ version, root: TreeNode }` | 完整目录树 |
| `GET /api/doc?path=<RelPath>` | `RenderedDoc` | |
| `GET /api/settings` | `Settings` | |
| `PUT /api/settings` | `Settings` | body 为部分字段，服务端校验 |
| `GET /files/{path...}` | 原始文件 | md 引用的资源；仅根目录内、白名单扩展名 |
| `GET /ws` | WebSocket upgrade | 见 6.3 |
| `GET /` 及其他 | 嵌入的前端；未命中回退 `index.html` | |

- 错误统一返回 `APIError` JSON：400 `BAD_REQUEST`、403 `OUTSIDE_ROOT`、404 `NOT_FOUND`/`NOT_MARKDOWN`、413 `TOO_LARGE`（默认 5 MB）、500 `READ_FAILED`。
- `/files/` 白名单：`png jpg jpeg gif webp svg avif bmp ico pdf mp4 webm`；`svg` 响应附加 `Content-Security-Policy: sandbox`；统一 `X-Content-Type-Options: nosniff`。
- HTML 响应 CSP：`default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; connect-src 'self'`。
- WS upgrade 校验 `Origin` 必须是 `http://localhost:<port>` 或 `http://127.0.0.1:<port>`，防止其他网页连接本机服务。

### 6.3 WebSocket（`/ws`，与 HTTP 同端口）

前端用 `` `ws://${location.host}/ws` `` 连接，**禁止写死主机名或端口**。消息为 JSON，外层统一 `{ "type": string, ... }`。

```go
// 客户端 → 服务端
type ClientHello       struct { Type string `json:"type"` /* "hello" */;       Protocol int     `json:"protocol"` }
type ClientSubscribe   struct { Type string `json:"type"` /* "subscribe" */;   Path     RelPath `json:"path"` }
type ClientUnsubscribe struct { Type string `json:"type"` /* "unsubscribe" */ }
type ClientPing        struct { Type string `json:"type"` /* "ping" */ }

// 服务端 → 客户端
type ServerWelcome     struct { Type string `json:"type"` /* "welcome" */;      Protocol int; TreeVersion uint64; WatchMode string }
type ServerTreeChanged struct { Type string `json:"type"` /* "tree.changed" */; Version uint64; Root TreeNode }
type ServerDocChanged  struct { Type string `json:"type"` /* "doc.changed" */;  Doc RenderedDoc }
type ServerDocRemoved  struct { Type string `json:"type"` /* "doc.removed" */;  Path RelPath }
type ServerError       struct { Type string `json:"type"` /* "error" */;        Error APIError }
type ServerPong        struct { Type string `json:"type"` /* "pong" */ }
```

（上面是示意，实际代码中每个字段都要写 json tag。）

约定：

- `Protocol` 当前为 `1`；不一致时服务端发 `error` 后关闭，前端提示刷新。
- 每个连接同时只订阅一篇文档；`subscribe` 后服务端立即推一次 `doc.changed`。
- `tree.changed` 第一版推全量；节点数 > 5000 时再设计增量。
- 服务端对每个会话的发送队列设上限（16 条），溢出时丢弃旧的 `doc.changed`（只保留最新）并记录 warn；慢客户端不得阻塞 Hub。
- 前端收到 `doc.changed` 只替换预览容器内容并按行号恢复滚动，**禁止整页刷新**。
- 重连：1s 起指数退避，上限 30s，无限重试；成功后重新 `hello` + `subscribe`，并重新拉取 `/api/tree`。

### 6.4 模块内部接口（服务端）

feature 包对外只暴露如下形态（构造函数 + 方法），其余标识符小写：

```go
// internal/features/tree
type Service interface {
    Start(ctx context.Context) error             // 初次扫描 + 开始消费监听事件，阻塞到 ctx 结束
    Snapshot() (version uint64, root protocol.TreeNode)
    Has(p relpath.RelPath) bool
    Subscribe(fn func(version uint64, root protocol.TreeNode)) (unsubscribe func())
}
func New(fs platform.FileSystem, w platform.Watcher, rootAbs string, opt Options, log *slog.Logger) Service

// internal/features/preview
type Service interface {
    Render(ctx context.Context, p relpath.RelPath) (protocol.RenderedDoc, error)
    Subscribe(fn func(ev DocEvent)) (unsubscribe func())   // DocEvent{Path, Kind: Changed|Removed}
}

// internal/features/assets
type Service interface {
    Open(ctx context.Context, p relpath.RelPath) (rc io.ReadCloser, mime string, size int64, err error)
}
```

- feature 间事件通过 `Subscribe` 回调传递；回调内不得阻塞（需要时自行投递到 channel）。禁止全局事件总线。
- 返回的错误必须能被 `errors.As(err, *domainerr.Error)` 识别；HTTP/WS 层只负责翻译成 `APIError`。
- 所有可能阻塞的方法第一个参数为 `context.Context`。

## 7. 平台能力封装

`internal/platform/ports.go` 只包含接口与值类型：

```go
type FileKind int // KindFile | KindDir | KindOther

type FileInfo struct {
    Kind    FileKind
    Size    int64
    ModTime time.Time
}

type DirEntry struct {
    Name string
    Kind FileKind
}

type FileSystem interface {
    EvalSymlinks(abs string) (string, error)
    Stat(abs string) (FileInfo, error)                     // 不存在返回 domainerr NOT_FOUND
    ReadFile(abs string, maxBytes int64) ([]byte, error)   // 超限返回 TOO_LARGE
    Open(abs string) (io.ReadCloser, FileInfo, error)
    ReadDir(abs string) ([]DirEntry, error)
    WriteFileAtomic(abs string, data []byte, perm uint32) error
}

type WatchOp int // OpAdd | OpChange | OpRemove | OpAddDir | OpRemoveDir

type WatchEvent struct {
    Op  WatchOp
    Abs string
}

type WatchMode string // "native" | "polling"

type WatchOptions struct {
    Ignore       func(abs string, isDir bool) bool
    ForceMode    WatchMode     // "" = 自动
    PollInterval time.Duration
}

type Watcher interface {
    // Watch 阻塞直到 ctx 结束；事件与错误通过回调投递（回调不得阻塞）。
    Watch(ctx context.Context, rootAbs string, opt WatchOptions, onEvent func(WatchEvent), onError func(error)) error
    Mode() WatchMode
}

type MountProbe interface {
    FSType(abs string) (string, error) // "ext4" | "9p" | "drvfs" | "fuse.xxx" ...
}

type BrowserOpener interface {
    Open(ctx context.Context, url string) bool // 失败返回 false，不返回 error
}

type Env interface {
    IsWSL() bool
    Distro() string   // WSL_DISTRO_NAME，非 WSL 为空
    ConfigDir() string
}
```

实现要点（只能写在 `internal/platform/<impl>`）：

1. **监听**（`platform/watch`）：
   - **模式选择**：`MountProbe.FSType(root)` 为 `9p`、`drvfs`、`cifs`、`nfs*`、`fuse*`，或路径以 `/mnt/` 开头 ⇒ `polling`；否则 `native`。`--poll` / `--no-poll` 可强制。
   - **native**：fsnotify **监听目录而不是文件**（这样 vim 等"写临时文件再 rename"的原子保存不会丢监听）；启动时递归 `Add` 所有未被忽略的目录，收到目录 `Create` 事件时递归补加，目录删除时移除。
   - **防抖与归并**：同一路径 150ms 内的事件合并；窗口结束后 `Stat` 一次决定最终是 `OpAdd`/`OpChange`/`OpRemove`（Remove+Create 合并为 Change）。
   - **polling**：按间隔遍历目录树，比较 `(size, mtime)` 快照产生事件；只记录未被忽略的 `.md` 文件和目录。
   - **过滤**：默认忽略 `.git`、`node_modules`、`.venv`、`dist`、`build`、`.cache` 及所有点目录，外加 `settings.ignore`；文件只上报 `.md`、`.markdown`；编辑器临时文件（`*.swp`、`*~`、`4913`、`.#*`）永不上报。
   - **ENOSPC**（inotify 监听数耗尽）：打印修复指引（`sudo sysctl fs.inotify.max_user_watches=524288`），自动切到 polling，`Mode()` 随之改变并通知 `onError`。
2. **挂载探测**（`platform/mounts`）：解析 `/proc/self/mounts`，最长前缀匹配；失败返回错误，调用方按 `native` 处理。
3. **打开浏览器**（`platform/browser`），依次尝试直到成功：`wslview <url>` → `cmd.exe /c start "" <url>` → `explorer.exe <url>` → 非 WSL 时 `xdg-open` / `open`。全部失败返回 `false`，由 app 打印 URL。
4. **环境**（`platform/sysenv`）：`WSL_DISTRO_NAME` 非空或 `/proc/sys/kernel/osrelease` 含 `microsoft` ⇒ WSL；`ConfigDir` 遵循 `XDG_CONFIG_HOME`。
5. **测试替身**（`platform/fake`）：`fake.FS`（基于 `testing/fstest.MapFS` 扩展可写）与 `fake.Watcher`（测试中手动 `Emit`）。**features 的单元测试禁止触碰真实文件系统**；真实文件系统只在 `platform/*` 自己的测试里用 `t.TempDir()`。

## 8. 安全约束

1. **路径沙箱（两道）**：
   - `core/relpath.Parse(input)`：拒绝绝对路径、`..` 段、NUL、反斜杠、空段；输出规范化 POSIX 路径。
   - feature 读文件前：`EvalSymlinks(root/rel)` 结果必须等于 root 或以 `root + "/"` 开头（防符号链接逃逸），否则 `OUTSIDE_ROOT`。
2. **渲染**：goldmark **不启用** `html.WithUnsafe()`（原始 HTML 被省略）；链接协议白名单 `http https mailto` 与相对路径，图片额外允许 `data:image/*`。`allowHtml=true` 时启用 `WithUnsafe` 并对输出做 bluemonday UGC 策略净化。
3. **标题 id** 统一前缀 `h-`，防 DOM clobbering。
4. 前端除预览容器外禁止 `dangerouslySetInnerHTML` / `innerHTML`。
5. 默认只绑定 `127.0.0.1`；`--host` 改绑时打印警告；WS 校验 `Origin`（见 6.2）。

## 9. 渲染管线（`internal/core/render`）

```text
[]byte ─► goldmark.Parser ─► AST ─► ASTTransformer 扩展 ─► goldmark.Renderer ─► { HTML, Toc, Features }
```

签名（纯函数，可并发调用）：

```go
type Input struct {
    Source  []byte
    DocPath relpath.RelPath
    AllowHTML bool
}
type Output struct {
    HTML     string
    Toc      []protocol.TocItem
    Features protocol.DocFeatures
}
func Render(in Input) (Output, error)
```

扩展（`render/ext/`，每个一个文件，互不依赖，可单独测试）：

| 扩展 | 作用 |
|---|---|
| `sourceline` | 预先计算换行偏移表；为每个块级节点设置属性 `data-line="<1-based 行号>"`。容器节点（列表、引用）自身无 `Lines()` 时取第一个子孙块的起始行 |
| `anchor` | 标题 `id="h-<slug>"`（重名追加 `-2`、`-3`），同时收集 `TocItem` |
| `assetlink` | 相对图片 → `/files/<RelPath>`；相对 `.md` 链接 → `/?path=<RelPath>`（保留 `#hash`）；越界路径保持原样并加 `data-broken="1"` |
| `diagram` | ` ```mermaid ` 代码块输出 `<pre class="mermaid" data-line>`（源码转义），`Features.Mermaid = true` |
| `math`（第二版） | `$$…$$` / `$…$` 输出占位元素，`Features.Math = true` |

- 每次调用创建新的 `goldmark.Markdown`（或确保复用实例无共享可变状态），保证并发安全。
- 快照测试：`testdata/render/*.md` ↔ `*.golden.html`，`go test ./internal/core/render -update` 更新。

前端滚动恢复：记录视口顶部第一个 `[data-line]` 的行号；内容替换后找 `data-line <= 该行` 的最后一个元素并滚动到它。

## 10. 必须独立的模块

以下模块必须**可以脱离其他模块单独编译、运行和测试**，禁止为方便引入反向依赖：

| 模块 | 独立性要求 | 验证方式 |
|---|---|---|
| `core/render` | 输入字节输出结果，零 I/O、零全局状态 | golden 快照测试；`go test -race` |
| `core/relpath` | 纯字符串，覆盖穿越/编码边界 | 表驱动测试 + `go test -fuzz` |
| `core/protocol` | 只有类型与常量 | tygo 生成无 diff |
| `platform/watch` | 只依赖 `platform` + fsnotify；可写一个 30 行的 `cmd` 单独跑 | 集成测试：真实临时目录，覆盖 vim 式原子保存、目录新增/删除、polling 模式 |
| `livesync` | 通过接口拿 feature，用假实现测试 | `httptest` + WS 客户端测试 |
| `web` | 只依赖 HTTP/WS 协议 | `vite dev` 对接 mock（MSW）即可开发 |

## 11. 命名与代码约定

**Go**

- 包名小写单词，与目录同名；不使用 `util`、`common`、`helpers` 这类包名。
- 接口在 `platform` 集中定义；其他地方"接受接口、返回结构体"。
- 错误用 `fmt.Errorf("...: %w", err)` 包装；领域错误用 `domainerr.New(code, msg)`。
- 不直接用 `log`/`fmt.Println` 打日志，统一注入 `*slog.Logger`。
- 测试与源码同目录 `xxx_test.go`；跨模块 fixtures 放 `testdata/`。

**TypeScript / React**

- 文件名 `kebab-case.ts(x)`；组件 `PascalCase`；禁止 `export default`（`main.tsx` 与配置文件除外）。
- 预览容器用 `ref` + 手动设置 HTML，React 不参与其子树渲染。
- `web/src/gen/` 禁止手改。

## 12. 命令约定

| 命令 | 作用 |
|---|---|
| `make dev` | 启动 Go 服务（`-dev` 模式，静态资源代理到 Vite）+ Vite dev server |
| `make gen` | tygo 生成 `web/src/gen/protocol.ts` |
| `make build` | `npm --prefix web run build` → `CGO_ENABLED=0 go build -o bin/mdview ./cmd/mdview`（附带 `linux/amd64`、`linux/arm64`） |
| `make test` | `go test -race ./...` + `npm --prefix web test` |
| `make lint` | `golangci-lint run` + `go test ./internal/archtest` + `npm --prefix web run lint`（含 dependency-cruiser）+ 检查 `make gen` 无 diff |
| `mdview <path> [-port 47631] [-poll\|-no-poll] [-no-open] [-host 127.0.0.1]` | 运行 |

端口：服务默认 `47631`，被占用时依次 +1 尝试 10 次；Vite dev server 固定 `47632`，把 `/api`、`/files`、`/ws` 代理到 Go 服务。
