# AGENTS.md

本仓库是 **wsl-md-pulse**：在 WSL2 中运行的 Markdown 只读预览服务（单个 Go 二进制，内嵌 Vite + TypeScript + React 前端），Windows 浏览器访问，文件变化实时刷新。

**当前路线**：原样使用 Vantage v0.7.1，入口是 `scripts/mdv`（决策见 `.scratch/wsl-md-sync-feasibility/issues/06-choose-route.md`）。下面的规则约束的是暂不实施的自研备选设计；只有决定转为自研后，才开始写 `cmd/`、`internal/`、`web/` 下的代码。

完整设计见 [`docs/architecture.md`](docs/architecture.md)。本文件是**必须遵守的硬规则摘要**；两者冲突时以 `docs/architecture.md` 为准。要打破规则，先改文档并写明原因，再改代码。

## 范围

- 只读预览。不做编辑、鉴权、数据库（含 SQLite）、远程访问、云同步。
- 运行时依赖只允许 `docs/architecture.md` 第 1 节列出的库；新增依赖先更新该表。
- WSL 运行时不得依赖 Node.js；Node 只用于构建前端。

## 目录与依赖方向（服务端）

```text
cmd/mdview                 入口，只调用 app.Run
internal/app               组装层：唯一构造 platform 实现并注入 → 可 import 全部，不写业务逻辑
internal/app/httpapi       HTTP 适配器   → features, livesync, core, web
internal/livesync          WebSocket hub → features, core, coder/websocket
internal/features/<x>      用例          → platform（仅接口）, storage, core, 其他 feature 包根
internal/storage           JSON 状态文件 → platform（仅接口）, core
internal/platform          ports.go 接口 → core
internal/platform/<impl>   系统调用实现  → platform, core, 标准库, fsnotify
internal/core/...          纯逻辑        → 仅无 I/O 的标准库与 goldmark/bluemonday
```

硬规则：

1. `os`、`os/exec`、`path/filepath`、`io/fs`、`fsnotify` **只能**出现在 `internal/platform/<impl>`（`internal/app`、`cmd` 仅限信号/退出处理）。
2. 只有 `internal/app` 可以构造 `platform/<impl>`；其他包只接收 `internal/platform` 中的接口。
3. `internal/core` 无 I/O、无 goroutine、无全局可变状态、不调用 `time.Now`。
4. 禁止包级可变全局变量、禁止 `init()` 副作用、禁止全局事件总线。
5. 所有可能阻塞的函数首参为 `context.Context`；长期 goroutine 必须随 ctx 退出并被等待。
6. `go test ./internal/archtest` 与 `golangci-lint`（depguard）会检查以上规则，必须通过。

## 目录与依赖方向（前端 `web/src`）

- `features/<x>` 之间禁止互相 import；只能用 `api`、`sync`、`components`、`lib`、`gen`。
- 只有 `api/` 发 HTTP、只有 `sync/` 用 WebSocket。
- `gen/protocol.ts` 由 `make gen`（tygo）生成，禁止手改。
- 预览容器用 `ref` 手动设置 HTML，React 不渲染其子树；除此之外禁止 `dangerouslySetInnerHTML`/`innerHTML`。
- UI 原子组件用 shadcn/ui（`components/ui`），不手写 Button/Dialog 等。
- `npm --prefix web run lint`（含 dependency-cruiser）必须通过。

## 状态

- 服务端内存：目录树归 `features/tree`（不可变快照 + 原子指针替换），渲染缓存与 `docVersion` 归 `features/preview`，会话订阅归 `livesync.Hub`。其他模块只读快照或订阅。
- 持久化只有 `~/.config/wsl-md-pulse/state.json`（`internal/storage/schema.go`）；改字段必须升 `SchemaVersion` 并写迁移与测试。
- 前端：当前文档在 URL（`/?path=`）；滚动位置按**源码行号**存 `sessionStorage`；服务端不存 UI 状态。

## 接口

- 所有 HTTP/WS 类型的唯一来源是 `internal/core/protocol`。改接口：改 Go 结构体 → `make gen` → 同步 `docs/architecture.md` 第 6 节。
- WebSocket 与 HTTP 同端口 `/ws`；前端用 `location.host` 连接，禁止写死主机/端口；服务端校验 `Origin`。
- 文档更新只替换预览容器内容并按行号恢复滚动，禁止整页刷新。
- 领域错误用 `domainerr.New(code, msg)`，由 HTTP/WS 层翻译成 `APIError`。

## 平台

- 根目录为 `9p`/`drvfs`/网络或 FUSE 文件系统、或位于 `/mnt/` 下 ⇒ 轮询；否则 fsnotify（监听**目录**，150ms 防抖，Remove+Create 合并为 Change）。`ENOSPC` 时降级轮询并提示。
- 打开浏览器：`wslview` → `cmd.exe /c start` → `explorer.exe` → `xdg-open`/`open`，全部失败只打印 URL。
- features 单元测试用 `internal/platform/fake`，不碰真实文件系统。

## 安全（不可省略）

- 请求中的路径先过 `core/relpath.Parse`，读文件前再做 `EvalSymlinks` 根目录校验。
- goldmark 默认不启用 `WithUnsafe`；`allowHtml` 开启时必须经 bluemonday。标题 id 加 `h-` 前缀。
- 默认只绑定 `127.0.0.1`。

## 代码约定

- Go ≥ 1.24，`CGO_ENABLED=0`；日志用注入的 `*slog.Logger`；错误用 `%w` 包装；测试与源码同目录。
- TypeScript strict；文件名 kebab-case；禁止 `export default`（`main.tsx` 与配置文件除外）。

## 提交前必须通过

```bash
make gen && git diff --exit-code   # 生成的 TS 类型已提交
make lint
make test
make build
```
