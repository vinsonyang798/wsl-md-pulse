# wsl-md-pulse 架构设计

> 本文档是**约束性文档**：后续代码必须符合这里的目录划分、依赖方向和接口定义。
> 需要打破约束时，先改这份文档（写明原因），再改代码。

## 0. 产品边界

- **做什么**：在 WSL2 里运行的 Markdown **只读**预览服务。`mdview <文件或目录>` 启动，Windows 浏览器打开 `http://localhost:<port>`，左侧目录树列出根目录下所有 `.md`，右侧渲染预览；文件变化后实时推送刷新，保留滚动位置。
- **不做什么**：编辑、多用户、鉴权、远程访问、云同步、数据库。
- **运行环境**：服务端 Node.js ≥ 20（ESM、TypeScript），运行在 WSL2（也应能在普通 Linux/macOS 运行）；前端运行在 Windows 浏览器（Chromium 系 / Firefox 最新版）。
- **只监听本机**：HTTP 默认绑定 `127.0.0.1`（WSL2 的 localhost 转发会把它暴露给 Windows）。

## 1. 技术选型（已定，不随意替换）

| 用途 | 选型 | 依据 |
|---|---|---|
| 文件监听 | `chokidar` v5 | 已处理原子保存（rename）、awaitWriteFinish、轮询回退、资源释放 |
| Markdown 渲染 | `markdown-it` v15 + 自有插件 | Token 带源码行号 `map`，插件机制成熟，默认安全（`html:false`） |
| 代码高亮 | `highlight.js`（通过 `options.highlight` 注入） | 服务端完成，前端零成本 |
| HTML 净化 | `sanitize-html`（仅在开启 `allowHtml` 时使用） | 默认不允许原始 HTML，无需净化 |
| HTTP | `node:http` + 极薄路由（或 `hono` 的 node adapter） | 路由很少，不引入 express/connect |
| WebSocket | `ws`，**与 HTTP 共用端口**（upgrade） | 避免 markserv 双端口问题 |
| CLI 参数 | `node:util` 的 `parseArgs` | 零依赖 |
| 前端 | Vite + React + TypeScript + Tailwind + shadcn/ui | 目录树、布局、空/加载/错误状态足够用 |
| 懒加载渲染 | Mermaid、KaTeX 仅在文档出现对应块时由前端动态 `import()` | 控制首屏体积 |
| 测试 | `vitest` | 服务端与前端统一 |
| 依赖约束检查 | `dependency-cruiser` | 把第 3 节的依赖规则变成 CI 检查 |

## 2. 目录结构

```text
/
├─ AGENTS.md                 # 给 AI / 协作者的硬性规则（摘要本文件）
├─ docs/architecture.md      # 本文件
├─ package.json
├─ .dependency-cruiser.cjs   # 依赖方向检查
├─ src/                      # 服务端（运行在 WSL）
│  ├─ app/                   # 组装层：CLI、配置、HTTP 路由、启动/关闭
│  │  ├─ cli.ts
│  │  ├─ config.ts
│  │  ├─ http/               # HTTP 适配器（路由 → features 调用）
│  │  └─ main.ts             # composition root：唯一 new 各模块并注入依赖的地方
│  ├─ core/                  # 纯领域逻辑：无 I/O、无 Node 内置模块
│  │  ├─ paths.ts            # RelPath 模型、规范化、根目录沙箱判断（纯字符串）
│  │  ├─ tree.ts             # DocTree 数据结构与增量更新（纯函数）
│  │  ├─ render/             # markdown-it 实例与插件
│  │  │  ├─ renderer.ts
│  │  │  └─ plugins/         # source-line、asset-rewrite、heading-anchor、toc、diagram-placeholder
│  │  ├─ protocol.ts         # HTTP/WS 的请求与消息类型（前后端共享）
│  │  └─ errors.ts           # 领域错误码
│  ├─ features/              # 用例层：把 core 与 platform 端口组合成业务能力
│  │  ├─ tree/               # 维护目录树索引（扫描 + 增量）
│  │  ├─ preview/            # 读取 + 渲染 + 缓存某篇文档
│  │  ├─ assets/             # 安全地提供 md 引用的图片等静态文件
│  │  └─ settings/           # 读写用户设置（经 storage）
│  ├─ platform/              # 平台能力封装：所有系统调用只能在这里
│  │  ├─ ports.ts            # 端口接口定义（FileSystem / Watcher / MountProbe / BrowserOpener / Env）
│  │  ├─ node-fs.ts          # FileSystem 实现
│  │  ├─ watcher.ts          # Watcher 实现（chokidar + 监听策略选择）
│  │  ├─ mounts.ts           # 解析 /proc/self/mounts，判定 9p/drvfs
│  │  ├─ browser.ts          # 打开 Windows 浏览器
│  │  ├─ env.ts              # WSL 检测、发行版名
│  │  └─ fake/               # 测试用内存实现（FakeFileSystem、FakeWatcher）
│  ├─ storage/               # 持久化：JSON 文件存储（无数据库）
│  │  ├─ schema.ts           # 存储结构 + 版本号 + 迁移
│  │  └─ json-store.ts
│  └─ sync/                  # 实时通道：WebSocket hub、订阅、推送
│     ├─ hub.ts
│     └─ session.ts
├─ web/                      # 前端（运行在 Windows 浏览器）
│  ├─ index.html
│  └─ src/
│     ├─ app/                # 入口、路由（URL ↔ 当前文档）、全局布局
│     ├─ features/
│     │  ├─ tree/            # 左侧目录树
│     │  ├─ preview/         # 右侧预览、滚动恢复、TOC
│     │  └─ settings/        # 主题等
│     ├─ sync/               # WS 客户端：连接、重连、消息分发
│     ├─ api/                # HTTP 客户端（fetch 封装）
│     ├─ components/ui/      # shadcn/ui 生成的原子组件（不写业务）
│     └─ lib/                # 纯工具（无业务）
└─ test/                     # 跨模块集成测试、fixtures（md 样例目录）
```

### 2.1 每个目录的职责

| 目录 | 负责 | 明确不负责 |
|---|---|---|
| `src/app` | 解析 CLI 和配置；创建 platform 实现并注入 features/sync；注册 HTTP 路由；进程信号与优雅退出 | 任何业务判断（例如"哪些文件算 md"、"如何渲染"） |
| `src/app/http` | 把 HTTP 请求翻译成 feature 调用，把结果/错误翻译成 HTTP 响应；静态托管 `web/dist` | 访问文件系统、渲染 markdown |
| `src/core` | 纯数据结构与纯函数：路径模型、目录树、渲染管线、协议类型、错误码 | 任何 I/O（fs、网络、时间、随机数除外可注入） |
| `src/features/tree` | 启动时扫描根目录生成 `DocTree`；消费 Watcher 事件做增量更新；对外发出 `tree:changed` | 推送给浏览器（交给 sync） |
| `src/features/preview` | 按 `RelPath` 读取文件、调用 core 渲染、维护渲染缓存；对外发出 `doc:changed` / `doc:removed` | 决定推给哪些客户端 |
| `src/features/assets` | 校验并解析 md 引用的相对资源路径，返回可读流与 MIME | 目录列表 |
| `src/features/settings` | 设置的读取、校验、默认值、更新 | 文件格式细节（交给 storage） |
| `src/platform` | 所有与操作系统打交道的代码；对上只暴露 `ports.ts` 里的接口 | 业务规则 |
| `src/storage` | 设置文件的读写、原子写入、schema 版本迁移 | 设置的业务含义 |
| `src/sync` | WS 连接管理、客户端订阅表、把 feature 事件按订阅路由给客户端、心跳 | 渲染、读文件 |
| `web/src/app` | 根组件、布局、URL 状态同步 | 直接发 fetch / 直接操作 WebSocket |
| `web/src/features/*` | 各自 UI 与本地状态 | 跨 feature 直接互相 import |
| `web/src/sync` | 唯一的 WebSocket 客户端，指数退避重连，按消息类型分发 | UI |
| `web/src/api` | 唯一的 HTTP 客户端 | UI |
| `web/src/components/ui` | shadcn/ui 原子组件 | 业务逻辑 |

## 3. 模块依赖规则（谁能调用谁）

依赖只能**自上而下**，箭头表示"可以 import"：

```text
               ┌──────────── src/app ────────────┐
               ▼            ▼          ▼          ▼
          src/sync ──► src/features ──► src/storage
               │            │    │         │
               │            │    ▼         ▼
               │            │  src/platform/ports.ts  ◄── src/platform/*（实现）
               ▼            ▼          │
                     src/core  ◄───────┘
```

| 模块 | 允许 import | 禁止 import |
|---|---|---|
| `core` | 自身；`markdown-it`、`highlight.js` 等纯计算库 | `node:*`、`chokidar`、`ws`、项目内任何其他目录 |
| `platform/ports.ts` | `core`（仅类型） | 其他一切 |
| `platform/*`（实现） | `core`、`platform/ports.ts`、`node:*`、`chokidar` | `features`、`sync`、`storage`、`app` |
| `storage` | `core`、`platform/ports.ts` | `platform/*` 实现、`features`、`sync`、`app` |
| `features/<x>` | `core`、`platform/ports.ts`、`storage` | `platform/*` 实现、`sync`、`app`、**其他 feature 的内部文件**（只能通过其 `index.ts` 公开 API） |
| `sync` | `core`、`features/*/index.ts`、`ws` | `platform/*`、`storage`、`app` |
| `app` | 全部 | —（但不得包含业务逻辑） |
| `web/src/**` | `src/core/protocol.ts`（仅类型，`import type`） | `src/` 下任何其他文件 |
| `web/src/features/<x>` | `web/src/{api,sync,components,lib}` | 其他 `web/src/features/<y>` |

补充规则：

1. **只有 `src/app/main.ts` 可以 `new` 平台实现**（`NodeFileSystem`、`ChokidarWatcher` 等），其余模块只拿接口。
2. **`node:fs`、`node:child_process`、`node:os`、`chokidar` 只允许出现在 `src/platform/`**（`storage` 通过 `FileSystem` 端口写文件）。
3. 每个 feature 目录必须有 `index.ts` 作为唯一公开入口；外部只能 import `features/<x>/index.ts`。
4. 禁止循环依赖。
5. 以上规则由 `dependency-cruiser` 在 `npm run lint:deps` 中强制执行，CI 失败即不可合并。

## 4. 状态放在哪里

原则：**每份状态只有一个所有者**；其他地方只能读快照或订阅事件。

### 4.1 服务端（内存）

| 状态 | 所有者 | 形态 | 生命周期 |
|---|---|---|---|
| 根目录（绝对路径，已 realpath） | `app/config` | 不可变值，启动时确定 | 进程 |
| 目录树索引 `DocTree` | `features/tree` | `Map<RelPath, TreeNode>` + 版本号 `treeVersion` | 进程；由 Watcher 事件增量更新 |
| 渲染缓存 | `features/preview` | LRU（默认 50 篇），key=`RelPath`，值含 `mtimeMs`、`size`、`docVersion`、`html`、`toc` | 进程；文件变化时失效 |
| 文档版本号 `docVersion` | `features/preview` | 每篇文档单调递增整数 | 进程 |
| 客户端订阅表 | `sync/hub` | `Map<SessionId, { path: RelPath \| null, socket }>` | 连接 |
| 监听句柄 | `platform/watcher` | chokidar 实例 | 进程；`close()` 时释放 |

- 服务端**不保存**任何 UI 状态（滚动位置、展开节点）。
- 所有内存状态都能从文件系统重建；进程重启不丢用户数据。

### 4.2 服务端（持久化）

只有用户设置，见第 5 节。

### 4.3 浏览器

| 状态 | 位置 | 说明 |
|---|---|---|
| 当前打开的文档 | **URL**（`/?path=<RelPath>`） | 可刷新、可分享给本机其他标签；是前端当前文档的唯一真相 |
| 目录树数据 | `features/tree` 内存 store | 来自 `GET /api/tree` + `tree:changed` 推送；不写入 storage |
| 目录展开状态 | `sessionStorage`：`mdpulse:expanded` | 标签页级 |
| 每篇文档滚动位置 | `sessionStorage`：`mdpulse:scroll:<RelPath>` = 源码行号 | 存"行号"不存像素，内容变化后仍能对齐 |
| 主题 / 字号 | 服务端设置（第 5 节），前端 `localStorage` 仅作首屏缓存 | 服务端为准 |
| WS 连接状态 | `web/src/sync` store | `connecting / open / reconnecting / offline` |

前端状态管理：React 内置 `useSyncExternalStore` + 每个 feature 一个小 store 模块；不引入 Redux/MobX。

## 5. 数据存储（"数据库表"）

**本项目不使用数据库。** 理由：数据只有少量用户设置；目录树与渲染结果都能从文件系统实时重建，持久化它们只会带来一致性问题。

持久化使用单个 JSON 文件：

- 路径：`$XDG_CONFIG_HOME/wsl-md-pulse/state.json`（默认 `~/.config/wsl-md-pulse/state.json`）
- 写入：先写 `state.json.tmp`，`fsync` 后 `rename`（原子替换）
- 读取失败或 JSON 损坏：备份为 `state.json.corrupt-<ts>`，使用默认值继续运行，不崩溃

逻辑上的"表"如下（新增字段必须同步更新本节与 `storage/schema.ts`，并提升 `schemaVersion` 写迁移）：

```ts
// src/storage/schema.ts
interface StateFileV1 {
  schemaVersion: 1;

  /** 表 settings：单行 */
  settings: {
    theme: 'system' | 'light' | 'dark';
    fontSize: number;            // px，12–24
    allowHtml: boolean;          // 默认 false；开启后经 sanitize-html
    pollIntervalMs: number;      // 轮询模式间隔，默认 300
    ignore: string[];            // 额外忽略的目录名，默认 []
  };

  /** 表 recent_roots：最近打开的根目录，最多 20 条，按 lastOpenedAt 倒序 */
  recentRoots: Array<{
    path: string;                // 绝对路径（Linux 形式）
    lastOpenedAt: string;        // ISO 8601
    lastDoc: string | null;      // 上次打开的 RelPath
  }>;
}
```

## 6. 接口定义

所有类型定义在 `src/core/protocol.ts`，前后端共用；**改接口先改这个文件**。

### 6.1 基础类型

```ts
/** 相对根目录的 POSIX 路径，不以 / 开头，不含 . 或 .. 段。例：'docs/intro.md' */
type RelPath = string & { readonly __brand: 'RelPath' };

interface TreeNode {
  path: RelPath;                 // 根节点为 ''
  name: string;
  kind: 'dir' | 'file';
  children?: TreeNode[];         // 仅 dir；按 目录优先 + 名称自然排序
}

interface TocItem { level: 1 | 2 | 3 | 4 | 5 | 6; id: string; text: string; line: number }

interface RenderedDoc {
  path: RelPath;
  version: number;               // docVersion
  mtimeMs: number;
  html: string;                  // 已安全处理的 HTML 片段（不含 <html>/<body>）
  toc: TocItem[];
  features: { mermaid: boolean; math: boolean };  // 前端据此懒加载
}

interface ApiError { code: ErrorCode; message: string }
type ErrorCode =
  | 'NOT_FOUND' | 'OUTSIDE_ROOT' | 'NOT_MARKDOWN'
  | 'TOO_LARGE' | 'READ_FAILED' | 'BAD_REQUEST';
```

### 6.2 HTTP

| 方法 路径 | 返回 | 说明 |
|---|---|---|
| `GET /api/health` | `{ ok: true, version, root, watchMode: 'native' \| 'polling' }` | 启动探测 |
| `GET /api/tree` | `{ version: number, root: TreeNode }` | 完整目录树 |
| `GET /api/doc?path=<RelPath>` | `RenderedDoc` | 渲染单篇文档 |
| `GET /api/settings` | `Settings` | |
| `PUT /api/settings` | `Settings` | body 为 `Partial<Settings>`，服务端校验 |
| `GET /files/<RelPath>` | 原始文件流 | md 引用的图片等；**仅限根目录内、白名单扩展名** |
| `GET /*` | `web/dist` 静态资源，未命中回退 `index.html` | |

- 错误统一返回 `ApiError` JSON，状态码：400 / 403（`OUTSIDE_ROOT`）/ 404 / 413（`TOO_LARGE`，默认上限 5 MB）/ 500。
- `/files/` 白名单：`png jpg jpeg gif webp svg avif bmp ico pdf mp4 webm`；`svg` 响应加 `Content-Security-Policy: sandbox`。
- 所有 HTML 响应带 CSP：`default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; connect-src 'self'`。

### 6.3 WebSocket（`/ws`，与 HTTP 同端口）

客户端用 `new WebSocket(`ws://${location.host}/ws`)` 连接，**不得写死主机名或端口**。

```ts
// 客户端 → 服务端
type ClientMsg =
  | { type: 'hello'; protocol: 1 }
  | { type: 'subscribe'; path: RelPath }        // 切换当前文档；同一连接只订阅一篇
  | { type: 'unsubscribe' }
  | { type: 'ping' };

// 服务端 → 客户端
type ServerMsg =
  | { type: 'welcome'; protocol: 1; treeVersion: number; watchMode: 'native' | 'polling' }
  | { type: 'tree:changed'; version: number; root: TreeNode }   // 第一版推全量；> 5000 节点时再做增量
  | { type: 'doc:changed'; doc: RenderedDoc }                   // 仅发给订阅了该 path 的连接
  | { type: 'doc:removed'; path: RelPath }
  | { type: 'error'; error: ApiError }
  | { type: 'pong' };
```

约定：

- 协议版本不一致时服务端发 `error` 后关闭连接，前端提示刷新页面。
- `subscribe` 之后服务端立即推一次当前 `doc:changed`，前端不必再调 `GET /api/doc`（首屏除外）。
- 前端收到 `doc:changed` 只替换预览容器的 `innerHTML`，然后按"保存的源码行号"恢复滚动，**禁止整页刷新**。
- 重连：1s 起指数退避，上限 30s，无限重试；重连成功后重新 `hello` + `subscribe` 并拉一次 `/api/tree`。

### 6.4 模块内部接口（服务端）

feature 对外只暴露如下形式的 API（位于各自 `index.ts`）：

```ts
// features/tree
interface TreeService {
  start(): Promise<void>;
  snapshot(): { version: number; root: TreeNode };
  has(path: RelPath): boolean;
  onChange(listener: (s: { version: number; root: TreeNode }) => void): Unsubscribe;
  stop(): Promise<void>;
}

// features/preview
interface PreviewService {
  render(path: RelPath): Promise<RenderedDoc>;                    // 失败抛 DomainError
  onDocChange(listener: (e: { path: RelPath; kind: 'changed' | 'removed' }) => void): Unsubscribe;
}

// features/assets
interface AssetService {
  open(path: RelPath): Promise<{ stream: Readable; mime: string; size: number }>;
}
```

- feature 之间的事件通过构造时注入的回调/订阅完成，不使用全局 EventEmitter 单例。
- 抛出的错误必须是 `core/errors.ts` 里的 `DomainError(code, message)`；HTTP/WS 层只负责翻译。

## 7. 平台能力封装

所有系统调用经 `src/platform/ports.ts` 定义的端口：

```ts
interface FileSystem {
  realpath(abs: string): Promise<string>;
  stat(abs: string): Promise<{ kind: 'file' | 'dir' | 'other'; size: number; mtimeMs: number } | null>;
  readText(abs: string, maxBytes: number): Promise<string>;       // 超限抛 TOO_LARGE
  openRead(abs: string): Promise<Readable>;
  readDir(abs: string): Promise<Array<{ name: string; kind: 'file' | 'dir' | 'other' }>>;
  writeFileAtomic(abs: string, data: string): Promise<void>;
}

type WatchEvent =
  | { type: 'add' | 'change' | 'unlink'; abs: string }
  | { type: 'addDir' | 'unlinkDir'; abs: string };

interface Watcher {
  readonly mode: 'native' | 'polling';
  watch(rootAbs: string, opts: { ignore: (abs: string, isDir: boolean) => boolean }): Promise<void>;
  onEvent(listener: (e: WatchEvent) => void): Unsubscribe;
  onError(listener: (err: Error) => void): Unsubscribe;
  close(): Promise<void>;
}

interface MountProbe {
  fsTypeOf(abs: string): Promise<string | null>;   // 例：'ext4' | '9p' | 'drvfs' | 'fuse' ...
}

interface BrowserOpener { open(url: string): Promise<boolean> }  // 失败返回 false，不抛错

interface Env {
  isWSL: boolean;
  distro: string | null;          // WSL_DISTRO_NAME
  configDir: string;              // XDG 配置目录
}
```

实现要点（只写在 `src/platform/`）：

1. **监听策略**（`watcher.ts`）：
   - 用 `MountProbe` 查根目录挂载类型；`9p`、`drvfs`、`cifs`、`nfs`、`fuse*` 或路径以 `/mnt/` 开头 ⇒ `usePolling: true`，间隔 `settings.pollIntervalMs`；否则原生 inotify。
   - CLI `--poll` / `--no-poll` 可强制覆盖。
   - chokidar 固定参数：`atomic: true`、`ignoreInitial: true`、`awaitWriteFinish: { stabilityThreshold: 150, pollInterval: 50 }`、`followSymlinks: false`。
   - 默认忽略：`.git`、`node_modules`、`.venv`、`dist`、`build`、`.cache` 及所有点目录；文件只保留 `.md`、`.markdown`（资源文件不需要监听）。
   - 遇到 `ENOSPC`（inotify 监听数耗尽）时：打印修复指引（调大 `fs.inotify.max_user_watches`），并自动降级为轮询，`mode` 变为 `polling`。
2. **挂载探测**（`mounts.ts`）：解析 `/proc/self/mounts`，取最长前缀匹配；读取失败返回 `null`。
3. **打开浏览器**（`browser.ts`），按顺序尝试直到成功：`wslview <url>` → `cmd.exe /c start "" <url>` → `explorer.exe <url>` → 非 WSL 时 `xdg-open` / `open`。全部失败只打印 URL。
4. **WSL 检测**（`env.ts`）：`WSL_DISTRO_NAME` 环境变量存在，或 `/proc/version` 含 `microsoft`。
5. `platform/fake/` 提供内存版 `FakeFileSystem`、`FakeWatcher`（可手动 `emit` 事件），供 features 单元测试使用；**features 的单元测试禁止触碰真实文件系统**。

## 8. 安全约束

1. **路径沙箱**（两道）：
   - `core/paths.ts`：`toRelPath(input)` 拒绝绝对路径、`..` 段、NUL、反斜杠；输出规范化 POSIX 路径。
   - `features` 在读文件前：`realpath(root + rel)` 后必须仍以 `realpath(root) + '/'` 开头（防符号链接逃逸），否则 `OUTSIDE_ROOT`。
2. **渲染**：markdown-it 使用 `default` 预设、`html: false`；`validateLink` 保持默认（拒绝 `javascript:`、`vbscript:`、`file:`、非图片 `data:`）。开启 `allowHtml` 时输出必须经 `sanitize-html`。
3. **标题 id** 统一加前缀 `h-`，防止与页面元素 id 冲突（DOM clobbering）。
4. 目录树中文件名只作为文本节点渲染（React 默认转义），**禁止** `dangerouslySetInnerHTML` 用于除预览 HTML 以外的任何地方。
5. 服务只绑定 `127.0.0.1`；`--host` 参数改绑其他地址时打印警告。

## 9. 渲染管线（`core/render`）

```text
source ─► markdown-it.parse ─► tokens ─► core.ruler 插件 ─► renderer ─► { html, toc, features }
```

插件（每个一个文件，互不依赖，可单独测试）：

| 插件 | 作用 |
|---|---|
| `source-line` | 给所有 `nesting === 1 && map` 的块级开标签加 `data-line="<map[0]+1>"` |
| `heading-anchor` | 给 `heading_open` 加 `id="h-<slug>"`（重名追加 `-2`、`-3`），同时收集 `TocItem` |
| `asset-rewrite` | 相对路径的 `image` / 链接：基于当前文档目录解析 → `/files/<RelPath>`；`.md` 链接 → `/?path=<RelPath>`；越界路径保持原样并加 `data-broken` |
| `diagram-placeholder` | `fence` 且 `info === 'mermaid'` ⇒ 输出 `<pre class="mermaid" data-line>`，置 `features.mermaid = true` |
| `math` | `$$…$$` 块 / `$…$` 行内 ⇒ 占位元素，置 `features.math = true`（第一版可不做） |

- 渲染函数签名：`render(source: string, ctx: { docPath: RelPath }): Omit<RenderedDoc, 'version' | 'mtimeMs' | 'path'>`，**纯函数**。
- 前端滚动恢复：记录视口顶部第一个 `[data-line]` 元素的行号，更新后找 `data-line <= 该行` 的最后一个元素并滚动过去。

## 10. 必须独立的模块

以下模块必须**可以脱离其他模块单独运行和测试**，禁止为了方便引入反向依赖：

| 模块 | 独立性要求 | 验证方式 |
|---|---|---|
| `core/render` | 输入字符串输出结果，零 I/O；可直接在浏览器或 worker 中运行 | 快照测试（`test/fixtures/*.md` → `*.html`） |
| `core/paths` | 纯字符串，覆盖所有穿越/编码边界用例 | 单元测试 |
| `core/protocol` | 只有类型和常量，无运行时依赖 | 被 `web` 以 `import type` 使用 |
| `platform/watcher` | 只依赖 `ports.ts` + chokidar；可以写一个 20 行脚本单独跑 | 集成测试（真实临时目录，覆盖 vim 式原子保存） |
| `sync` | 通过接口拿 feature，能用 fake feature 测试 | 单元测试（内存 WS） |
| `web` | 只依赖 HTTP/WS 协议；可对着 mock server 开发 | `vite dev` + MSW/mock |

## 11. 目录与命名约定

- 文件名 `kebab-case.ts`；类型 `PascalCase`；函数/变量 `camelCase`；常量 `UPPER_SNAKE_CASE`。
- 每个目录的公开入口为 `index.ts`；以 `_` 开头或放在 `internal/` 的文件不得被目录外 import。
- 测试与源码同目录：`foo.ts` ↔ `foo.test.ts`；跨模块集成测试放 `test/`。
- 禁止默认导出（`export default`），React 组件也使用具名导出（Vite/React 入口文件除外）。
- 日志统一经 `app` 注入的 `Logger` 接口（`debug/info/warn/error`），其他模块不直接 `console.*`。

## 12. 命令约定

| 命令 | 作用 |
|---|---|
| `npm run dev` | 同时启动服务端（tsx watch）与 Vite dev server |
| `npm run build` | 编译服务端到 `dist/`、前端到 `web/dist/` |
| `npm test` | vitest 全部测试 |
| `npm run lint` | eslint + `lint:deps`（dependency-cruiser） |
| `npx mdview <path> [--port 47631] [--poll\|--no-poll] [--no-open] [--host]` | 运行 |

默认端口 `47631`，被占用时依次 +1 尝试 10 次。
