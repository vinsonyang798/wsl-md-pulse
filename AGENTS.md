# AGENTS.md

本仓库是 **wsl-md-pulse**：在 WSL2 中运行的 Markdown 只读预览服务，Windows 浏览器访问，文件变化实时刷新。

完整设计见 [`docs/architecture.md`](docs/architecture.md)。本文件是其中**必须遵守的硬规则摘要**；两者冲突时以 `docs/architecture.md` 为准。要打破规则，先改文档并写明原因，再改代码。

## 范围

- 只读预览。不做编辑、鉴权、数据库、远程访问、云同步。
- 不引入未在 `docs/architecture.md` 第 1 节列出的运行时依赖；需要新依赖先更新该表。

## 目录与依赖方向

```text
src/app       组装层（CLI、配置、HTTP 路由、main.ts）→ 可 import 全部，但不写业务逻辑
src/sync      WebSocket hub       → core, features/*/index.ts, ws
src/features  用例（tree/preview/assets/settings）→ core, platform/ports.ts, storage
src/storage   JSON 设置文件       → core, platform/ports.ts
src/platform  系统调用封装        → core, node:*, chokidar
src/core      纯逻辑（paths/tree/render/protocol/errors）→ 不 import 项目内其他目录，不 import node:*
web/src       前端                → 只能 `import type` 自 src/core/protocol.ts
```

硬规则：

1. `node:fs`、`node:child_process`、`node:os`、`chokidar` **只能**出现在 `src/platform/`。
2. 只有 `src/app/main.ts` 可以实例化 platform 实现；其他模块只依赖 `src/platform/ports.ts` 的接口。
3. 跨 feature 只能通过 `features/<x>/index.ts`；前端 `web/src/features/<x>` 之间禁止互相 import。
4. `src/core` 必须是纯函数/纯数据：无 I/O、无全局可变状态。
5. 禁止循环依赖。`npm run lint:deps` 会检查以上规则，必须通过。

## 状态

- 服务端内存状态：目录树归 `features/tree`，渲染缓存与 `docVersion` 归 `features/preview`，订阅表归 `sync/hub`。其他模块只读快照或订阅事件。
- 持久化只有 `~/.config/wsl-md-pulse/state.json`（schema 在 `src/storage/schema.ts`，改字段必须升 `schemaVersion` 并写迁移）。**不使用数据库。**
- 前端：当前文档在 URL（`/?path=`）；滚动位置按**源码行号**存 `sessionStorage`；服务端不存 UI 状态。

## 接口

- 所有 HTTP/WS 类型定义在 `src/core/protocol.ts`，前后端共用。改接口先改这个文件，再同步更新 `docs/architecture.md` 第 6 节。
- WebSocket 与 HTTP 同端口，路径 `/ws`；前端用 `location.host` 连接，禁止写死主机/端口。
- 文档更新只替换预览容器内容并按行号恢复滚动，禁止整页刷新。
- 错误统一用 `DomainError(code)`（`src/core/errors.ts`），由 HTTP/WS 层翻译。

## 安全（不可省略）

- 所有来自请求的路径先过 `core/paths.toRelPath`，读文件前再做 `realpath` 根目录校验。
- markdown-it 保持 `html: false` 与默认 `validateLink`；标题 id 加 `h-` 前缀。
- 除预览 HTML 外禁止使用 `dangerouslySetInnerHTML`。
- 服务默认只绑定 `127.0.0.1`。

## 平台

- 根目录挂载类型为 `9p`/`drvfs`/网络文件系统或路径在 `/mnt/` 下 ⇒ 轮询；否则 inotify。`ENOSPC` 时降级轮询并提示。
- 打开浏览器：`wslview` → `cmd.exe /c start` → `explorer.exe` → `xdg-open`/`open`，全部失败只打印 URL。

## 代码约定

- TypeScript strict，ESM，Node ≥ 20。文件名 kebab-case，禁止 `export default`（入口文件除外）。
- 测试与源码同目录 `*.test.ts`；features 单元测试使用 `src/platform/fake/`，不碰真实文件系统。
- 不直接 `console.*`，使用注入的 `Logger`。
- 前端 UI 原子组件用 shadcn/ui（`web/src/components/ui`），不手写 Button/Dialog 等。

## 提交前必须通过

```bash
npm run lint      # eslint + dependency-cruiser
npm test
npm run build
```
