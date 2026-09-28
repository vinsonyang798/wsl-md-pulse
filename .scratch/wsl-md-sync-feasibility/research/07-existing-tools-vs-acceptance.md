# 现成工具对照验收标准的差距

- 对应票据：`issues/07-existing-tools-vs-acceptance.md`
- 尺子：`issues/01-usage-scenario-and-acceptance.md` 的 `## Answer`（下文用"标准 1–7"指代其 7 条），术语见 `CONTEXT.md`
- 调研日期：2026-09-24
- 方法：
  - 读源码：在 `/tmp` 下 clone 各仓库，结论引用到文件与行号（链接固定到具体 commit）。
  - 查发布物：用 GitHub API 列 release 资产，下载 linux 二进制，用 `file` 与 `go version -m` 检查链接方式。
  - 实测：在 Linux 云 VM 上跑发布版二进制（内核 6.12，**不是 WSL2**，没有 Windows 浏览器），用 headless Chrome 148 + puppeteer-core 测刷新行为，用 curl / Node `ws` 测绑定地址、Origin 校验和路径越界。标"实测"的结论都来自这些运行；标"推断"的只基于源码阅读。
- 被测版本：go-grip v0.10.0、markserv 1.20.0（npm）、Vantage v0.7.0、mdserve v1.1.0。

图例：✅ 原生满足 · ⚙️ 靠配置满足 · 🔧 需改源码 · ❌ 做不到（不重写就不行）

## 0. 结论前置

1. **盘点中遗漏了一个最接近的工具：Vantage**（[mschulkind-oss/vantage](https://github.com/mschulkind-oss/vantage)，Go 单二进制 + 内嵌 React 前端，Apache-2.0）。标准 1、2、3、6、7 都原生满足，安全默认值也是所有候选里唯一合格的。缺的正是两条差异化需求：**跟随模式**和**按标题恢复阅读位置**，两处都是前端改动。
2. **go-grip 与需求的差距比盘点估计的大**：
   - 刷新是整页 `location.reload()`；
   - 没有侧栏目录树，只有 `http.FileServer` 的逐级目录列表；
   - 无论 `--host` 设成什么，都监听所有网卡（实测）；
   - 能经符号链接读到根目录外的文件（实测）；
   - 新建子目录里的文件变化不会触发刷新（实测）；
   - linux-amd64 发布物是动态链接（实测 `CGO_ENABLED=1`）。

   要达标，几乎要重写整个 HTTP 层和前端。
3. **markserv 不可用**：
   - 需要 Node 运行时（违反标准 7）；
   - Mermaid 从 jsDelivr CDN 加载；
   - WebSocket 端口监听所有网卡、不校验 Origin，客户端还能指定任意路径。实测：从非回环 IP、带伪造 Origin，读到了根目录外的 `.md`；
   - HTTP 也能用 `..` 和 `%2e%2e` 穿越根目录（实测）。
4. **mdserve**（盘点遗漏，Rust，定位就是"给 AI agent 用的 md 预览"）已于 2026-09 归档：
   - 只监听根目录一层，子目录文件 404（实测）；
   - 刷新是整页 reload；
   - `CorsLayer::permissive()` 让任意网站都能跨域读取渲染后的笔记（实测 `access-control-allow-origin: *`）。
5. **阅读位置没有任何工具实现**。三种实测场景：
   - **上方插入内容**：局部替换的工具（markserv、Vantage）保留的是像素偏移，会漂移一整节。
   - **整页 reload**（go-grip）：中途白屏、回到顶部，再由 Chromium 的恢复机制落回原标题。这是浏览器行为，不是工具实现的。
   - **先截断再写入**：三者都丢失位置，回到文档顶部。
6. **倾向**：先以 Vantage 为基线做真机验证，把"跟随模式"和"标题锚定恢复"作为两个前端补丁提给上游或维护一个 fork。"自己做"作为退路，在满足第 6 节列出的触发条件时启用。理由见第 6 节。

## 1. 候选与筛选

候选来自两处：盘点（`research/02-existing-solutions-survey.md`）里的 go-grip、markserv，以及本次在 GitHub 搜索 API 上补搜的结果。搜索词包括 `markdown preview server language:rust|go`、`markdown live reload mermaid`、`markdown preview agent`、`markdown viewer directory live reload`（2026-09-24）。

入选条件：浏览器页 + 实时刷新 + Mermaid + 目录浏览，且可能以单个二进制发布。

| 工具 | 语言 / 许可证 | 状态（2026-09-24） | 处理 |
|---|---|---|---|
| go-grip | Go / MIT | v0.10.0（2026-09-07） | 详评（§2.1） |
| markserv | Node / MIT | npm 1.20.0（2026-09-23） | 详评（§2.2） |
| **Vantage** | Go + React / Apache-2.0 | v0.7.0（2026-09-23），14★，几乎每天有提交 | 详评（§2.3） |
| **mdserve** | Rust / MIT | v1.1.0（2026-03-08），**2026-09 归档**，422★ | 详评（§2.4） |
| mdprev（naoki-higashi-28） | Go / MIT | v0.5.2（2026-02-11），2★ | 简评（§2.5），只读了源码 |
| markdown-proxy（patakuti） | Go / MIT | v0.4.0（2026-05-23），20★ | 简评（§2.5） |
| mdopen | Rust / BSD-3 | crates 0.6.0，无 GitHub release | 简评（§2.5） |
| Hugo `server` | Go / Apache-2.0 | — | 只作为"跟随模式"的先例（§2.5） |

来源：各仓库的 GitHub API `repos/{owner}/{repo}` 与 `releases` 接口；mdserve 的归档声明见 [README](https://github.com/jfernandez/mdserve/blob/68afb33f6f28870b03139d54073cf6232e93ece0/README.md)。

## 2. 逐工具评估

### 2.1 go-grip v0.10.0

源码基准：[chrishrb/go-grip@591f1ae](https://github.com/chrishrb/go-grip/tree/591f1ae607f4c915c5dbe717b28d3c9ac0c876d4)。刷新依赖 [aarol/reload v1.2.0](https://github.com/aarol/reload/tree/v1.2.0)（`go.mod` 中的版本）。

**刷新实现**
- `server.go:50-58` 建立 `reload.New(directory)`；`server.go:88-89` 把它作为中间件套在所有 handler 外面。([server.go](https://github.com/chrishrb/go-grip/blob/591f1ae607f4c915c5dbe717b28d3c9ac0c876d4/internal/server.go#L50-L94))
- reload 库往每个 HTML 响应末尾注入一段脚本，收到 `"reload"` 就执行 `window.location.reload()`，**整页刷新**。([reload.go `InjectedScript`](https://github.com/aarol/reload/blob/v1.2.0/reload.go))
- 服务端用 `sync.Cond.Broadcast()` 通知所有连接，消息里**不带变更的路径**，所以任何文件变化都会让所有打开的页面刷新。([watch.go:57-65](https://github.com/aarol/reload/blob/v1.2.0/watch.go#L57-L65))
- 防抖用 `bep/debounce` 100ms，是尾沿防抖。([watch.go:55](https://github.com/aarol/reload/blob/v1.2.0/watch.go#L55))
- **Bug**：收到 Create 事件时，代码 `w.Add(filepath.Dir(e.Name))` 加入的是**父目录**（本来就已在监听），而不是新建的那个目录。结果是新建子目录里的文件变化收不到。([watch.go:73-80](https://github.com/aarol/reload/blob/v1.2.0/watch.go#L73-L80))
  - 实测：修改已有的 `a.md`、在已有的 `sub/` 下写文件、新建目录本身、写一个 `junk.log`，都触发了 reload；**在新建的 `sub2/` 里写 `n.md`，不触发**。

**逐条对照**

| 标准 | 判定 | 依据 |
|---|---|---|
| 1 ext4 范围 | ✅ | fsnotify 递归添加监听（实测可用） |
| 2 连续改多个文件、整段重写 | 🔧 | 新建目录内的文件变化收不到（实测）；任何文件（包括非 md）变化都让所有页面整页刷新（实测 `junk.log` 也触发） |
| 3 独立浏览器页 | ✅ | — |
| 4 ≤1s | ✅ | 实测约 120ms 开始刷新 |
| 4 不整页跳动 | 🔧 | 整页 reload；实测中间出现"导航中 → 页面空白 / 顶部"的状态 |
| 4 按阅读位置恢复 | 🔧 | go-grip 自己不做恢复。上方插入内容的场景里，headless Chromium 刷新后落回 S20（浏览器的恢复机制）；先截断再写入的场景里回到顶部（实测，见 §3） |
| 5 跟随模式 | 🔧 | 推送消息不含路径，无从得知哪个文件变了 |
| 6 GFM / 高亮 / Mermaid / 图片 / 相对链接 | ✅ | goldmark：Table、Strikethrough、TaskList、Linkify、footnote、alert；chroma 高亮；Mermaid 以客户端模式渲染，`mermaid.min.js` 内嵌、离线可用。([parser.go:39-61](https://github.com/chrishrb/go-grip/blob/591f1ae607f4c915c5dbe717b28d3c9ac0c876d4/internal/parser.go#L39-L61)、[layout.html:31-32](https://github.com/chrishrb/go-grip/blob/591f1ae607f4c915c5dbe717b28d3c9ac0c876d4/defaults/templates/layout.html#L31-L32))。实测相对链接 `href="sub/s.md"` 原样输出，由服务端渲染 |
| 6 预览页内目录树 | 🔧 | 没有侧栏树。目录请求落到 `http.FileServer`，只返回平铺的 `<pre><a>` 列表，要逐级点进去（[server.go:135-141](https://github.com/chrishrb/go-grip/blob/591f1ae607f4c915c5dbe717b28d3c9ac0c876d4/internal/server.go#L135-L141)，实测） |
| 7 单文件静态二进制 | ⚙️ | 见下方"分发" |

**安全默认值**
- **绑定地址**：`--host` 默认 `localhost`（[root.go:43](https://github.com/chrishrb/go-grip/blob/591f1ae607f4c915c5dbe717b28d3c9ac0c876d4/cmd/root.go#L43)），但只用来拼打印出的 URL。实际监听是 `http.ListenAndServe(fmt.Sprintf(":%d", s.port), …)`，即**所有网卡**（[server.go:94](https://github.com/chrishrb/go-grip/blob/591f1ae607f4c915c5dbe717b28d3c9ac0c876d4/internal/server.go#L94)）。
  - 实测：`netstat` 显示监听 `:::6419`，经非回环 IP `172.30.0.2` 访问返回 200。
  - 影响：WSL2 默认 NAT 模式下，只有 Windows 主机能访问 VM 的 IP。mirrored 模式下可以从局域网直接连到 WSL（受 Hyper-V 防火墙约束）。([Microsoft Learn: WSL networking](https://learn.microsoft.com/en-us/windows/wsl/networking))
- **WebSocket Origin**：`CheckOrigin` 被改成恒返回 true（[server.go:54-57](https://github.com/chrishrb/go-grip/blob/591f1ae607f4c915c5dbe717b28d3c9ac0c876d4/internal/server.go#L54-L57)）。实测：`Origin: http://evil.example` 拿到了 `101 Switching Protocols`。由于通道里只推送 `"reload"`，泄露的仅是"有文件变了"这一信息。
- **路径穿越**：`http.Dir` 挡住了 `..`（实测 `/../outside.txt` 返回 301）。
- **符号链接逃逸**：不防。实测：根目录内的 `etc -> /etc` 让 `/etc/hostname` 可读；`link.txt -> 根外文件` 也能读。
- **HTML**：goldmark 开了 `html.WithUnsafe()`，且没有清洗（[parser.go:58-60](https://github.com/chrishrb/go-grip/blob/591f1ae607f4c915c5dbe717b28d3c9ac0c876d4/internal/parser.go#L58-L60)）。实测：md 里的 `<script>` 和 `<img onerror>` 原样输出。标题 id 没有前缀。

**分发**
- Release 页有 linux 386/amd64/arm64 的 tar.gz。([v0.10.0](https://github.com/chrishrb/go-grip/releases/tag/v0.10.0))
- 实测链接方式：
  - `linux-amd64`：`dynamically linked, interpreter /lib64/ld-linux-x86-64.so.2`，`go version -m` 显示 `CGO_ENABLED=1`，依赖 glibc；
  - `linux-arm64`：`statically linked`，`CGO_ENABLED=0`。
- 原因（推断）：发布用 `wangyoucao577/go-release-action` 在 ubuntu amd64 runner 上原生构建，workflow 没有设置 `CGO_ENABLED`，交叉编译的 arm64 才默认关闭 cgo。([release.yml](https://github.com/chrishrb/go-grip/blob/591f1ae607f4c915c5dbe717b28d3c9ac0c876d4/.github/workflows/release.yml))
- 常见 WSL 发行版自带 glibc，实际能运行，但严格说不算"静态二进制"。改法是在 release.yml 加一行 env，或自行 `CGO_ENABLED=0 go build`。

**要改的源码与侵入程度**：

| 改动 | 位置 | 侵入程度 |
|---|---|---|
| 真正绑定 `--host` | `internal/server.go:94` | 一行 |
| Origin 校验 | `internal/server.go:54-57` | 几行 |
| 符号链接根目录校验 | 替换 `http.Dir`，影响 `readToString`、`isRegularFile`、`fileServer` | 小，但要把静态文件服务改成自己写 |
| 关闭 unsafe HTML 或加清洗 | `internal/parser.go`（加清洗要新增 bluemonday 依赖） | 小 |
| 带路径的推送 + 局部替换 + 标题锚定恢复 + 跟随模式 | 移除 aarol/reload，自写 WS hub（顺带修掉新目录监听 bug）；新增"只返回渲染片段"的端点；重写 `layout.html` 的脚本 | **重写**服务端刷新机制与全部前端脚本 |
| 侧栏目录树 | 新增树 API（服务端）+ 侧栏 UI（前端） | 新功能 |
| 静态发布 | `release.yml` | 一行 |

合计：`internal/server.go` 基本重写，前端从零写。**能复用的主要是 `internal/parser.go` + `pkg/*`（goldmark 扩展管线）**。MIT 许可，允许 fork。

### 2.2 markserv 1.20.0

源码基准：[markserv/markserv@dcc216a](https://github.com/markserv/markserv/tree/dcc216a433e92bccbbd87d18de41bf8d15e2763e)。实测用 npm 上的 1.20.0。

**刷新实现**
- 服务端：`fs.watch(watchDir, {recursive: true})`，按扩展名过滤，尾沿防抖 150ms。([server.js:774-795](https://github.com/markserv/markserv/blob/dcc216a433e92bccbbd87d18de41bf8d15e2763e/lib/server.js#L774-L795))
- 任何一次变化都会把**每个客户端当前所在的文档**重新渲染一遍并推送，不管该文档本身有没有变。([server.js:678-747](https://github.com/markserv/markserv/blob/dcc216a433e92bccbbd87d18de41bf8d15e2763e/lib/server.js#L678-L747))
- 客户端：`document.querySelector('.markdown-body').innerHTML = e.data`，**局部替换**，不整页刷新；替换后重新加载 Mermaid。([markdown.html:159-173](https://github.com/markserv/markserv/blob/dcc216a433e92bccbbd87d18de41bf8d15e2763e/lib/templates/markdown.html#L159-L173))
- 滚动：不做任何处理，保留的是原来的像素位置。

**逐条对照**

| 标准 | 判定 | 依据 |
|---|---|---|
| 1 ext4 | ✅ | 在 Linux 上递归 `fs.watch` 需要 Node ≥ 19.1（盘点 §2.4） |
| 2 连续多文件 | ✅ | 150ms 尾沿防抖；持续写入时可能一直推迟（推断） |
| 3 独立页 | ✅ | — |
| 4 ≤1s | ✅ | 实测约 160–190ms |
| 4 不整页跳动 | ✅ | innerHTML 局部替换，实测没有页面加载 |
| 4 按阅读位置恢复 | 🔧 | 只保留像素偏移。实测上方插入约 700px 后，顶部从 S20 漂到 S18/S19；先截断再写入则回到顶部（§3） |
| 5 跟随模式 | 🔧 | 服务端知道哪个文件变了，但不告诉客户端，要改协议和客户端脚本 |
| 6 GFM / 高亮 / 图片 / 相对链接 | ✅ | markdown-it（表格、删除线）+ task-lists + highlight.js（[server.js:50-62](https://github.com/markserv/markserv/blob/dcc216a433e92bccbbd87d18de41bf8d15e2763e/lib/server.js#L50-L62)） |
| 6 Mermaid | 🔧 | 从 `https://cdn.jsdelivr.net/npm/mermaid@10/…` 懒加载，离线或内网环境下只显示源码（[markdown.html:236-247](https://github.com/markserv/markserv/blob/dcc216a433e92bccbbd87d18de41bf8d15e2763e/lib/templates/markdown.html#L236-L247)） |
| 6 目录树 | 🔧 | 只有逐级的目录索引页，没有侧栏 |
| 7 零运行时依赖 | ❌ | 需要 Node + npm 安装约 30 个依赖（[package.json](https://github.com/markserv/markserv/blob/dcc216a433e92bccbbd87d18de41bf8d15e2763e/package.json)）。GitHub 没有 release 二进制 |

**安全默认值**
- **HTTP 绑定**：`address` 默认 `'localhost'`（[cli-defs.js:14-17](https://github.com/markserv/markserv/blob/dcc216a433e92bccbbd87d18de41bf8d15e2763e/lib/cli-defs.js#L14-L17)）。实测解析成 `::1:8642`，只监听 IPv6 回环。Windows 浏览器经 WSL localhost 转发能否访问 `::1`，待真机验证。
- **WebSocket**：`new WebSocket.Server({port: wsPort})`，单独占一个端口，**不传 host，所以监听所有网卡**；没有 `verifyClient`，不校验 Origin（[server.js:641-665](https://github.com/markserv/markserv/blob/dcc216a433e92bccbbd87d18de41bf8d15e2763e/lib/server.js#L641-L665)）。实测 `:::8643`。
- **客户端可指定任意路径**：客户端发 `{path}` 注册自己在看哪个文件，服务端用 `path.normalize(unescape(dir) + unescape(decodedUrl))` 拼出路径，不做根目录校验（[server.js:723-724](https://github.com/markserv/markserv/blob/dcc216a433e92bccbbd87d18de41bf8d15e2763e/lib/server.js#L723-L724)）。
  - 实测：从非回环 IP、带 `Origin: http://evil.example` 连上，发 `{"path":"/../outside.md"}`。下一次根目录内有任何变化时，**收到了根目录外文件的渲染结果**。
  - 这意味着用户浏览器里打开的任何网页，都可以连 `ws://localhost:8643` 做同样的事（推断，原理同上）。
- **HTTP 路径穿越**：同样的拼接写法（[server.js:431-432](https://github.com/markserv/markserv/blob/dcc216a433e92bccbbd87d18de41bf8d15e2763e/lib/server.js#L431-L432)）。实测 `--path-as-is` 请求 `/../outside.md` 与 `/%2e%2e/outside.txt` 都读到了根目录外的文件，符号链接 `/etc/hostname` 也可读。浏览器会先规范化 URL，所以这条主要是本机其他进程的风险。
- **HTML**：markdown-it `html: true`，没有清洗。
- **启动时联网**：会执行 `isOnline` 检查，然后交互式询问是否 `npm i -g` 升级（[server.js:855-870](https://github.com/markserv/markserv/blob/dcc216a433e92bccbbd87d18de41bf8d15e2763e/lib/server.js#L855-L870)、[L952](https://github.com/markserv/markserv/blob/dcc216a433e92bccbbd87d18de41bf8d15e2763e/lib/server.js#L952)）。

**要改的源码**：要满足标准 7，需要把整个项目改成 Node SEA 或类似方式打包成单文件（上游不做），或者用另一种语言重写，所以判"做不到"。其余缺口（安全、Mermaid 内置、树、阅读位置、跟随）集中在 `lib/server.js` 和 `lib/templates/*.html`。MIT 许可。

### 2.3 Vantage v0.7.0（盘点遗漏，最接近）

源码基准：[mschulkind-oss/vantage@5b019da](https://github.com/mschulkind-oss/vantage/tree/5b019da358b513e1a212bc1beaa4458ebce1e5d0)。

规模（非测试代码）：Go 约 12.7k 行；前端 TS/TSX 约 15.9k 行。功能远超预览，还包括 git 历史与 diff、评审批注（review）、收藏（starred）、多仓库 daemon、性能诊断。README 自述："especially useful for reviewing LLM-generated Markdown output in real time"。([README](https://github.com/mschulkind-oss/vantage/blob/5b019da358b513e1a212bc1beaa4458ebce1e5d0/README.md))

**刷新实现**
- **服务端**：fsnotify，启动时递归加入全部目录（[watcher.go:192](https://github.com/mschulkind-oss/vantage/blob/5b019da358b513e1a212bc1beaa4458ebce1e5d0/internal/live/watcher.go#L192)）。
  - 收到 Create 事件时对新目录递归加入监听（[watcher.go:292-296](https://github.com/mschulkind-oss/vantage/blob/5b019da358b513e1a212bc1beaa4458ebce1e5d0/internal/live/watcher.go#L292-L296)）。
  - 合并窗口：安静 100ms、最长 1s（[watcher.go:29-32](https://github.com/mschulkind-oss/vantage/blob/5b019da358b513e1a212bc1beaa4458ebce1e5d0/internal/live/watcher.go#L29-L32)）。
  - 推送 `{"type":"files_changed","paths":[…]}`，**带路径**。
  - 遇到 ENOSPC 或事件溢出只打日志提示调大 `max_user_watches`，**不会降级为轮询**（[watcher.go:505-517](https://github.com/mschulkind-oss/vantage/blob/5b019da358b513e1a212bc1beaa4458ebce1e5d0/internal/live/watcher.go#L505-L517)）。
  - 实测：先新建 `sub3/deep/`，再写入 `new.md`、追加内容，两次都收到了 `files_changed`。
- **前端**：
  - 客户端再合并一次（150ms，最长 500ms）。
  - 只有当前文档在变更列表里时才 `loadFile(path)` 重新取内容，由 React 重新渲染，**不整页刷新**。
  - 同时刷新已展开的目录树和"最近文件"列表（[useWebSocket.ts:100-125](https://github.com/mschulkind-oss/vantage/blob/5b019da358b513e1a212bc1beaa4458ebce1e5d0/frontend/src/hooks/useWebSocket.ts#L100-L125)）。
  - 只有服务端版本号变化时才 `location.reload()`（[useWebSocket.ts:199](https://github.com/mschulkind-oss/vantage/blob/5b019da358b513e1a212bc1beaa4458ebce1e5d0/frontend/src/hooks/useWebSocket.ts#L199)）。
  - WS 地址用 `location.host` 拼出。

**逐条对照**

| 标准 | 判定 | 依据 |
|---|---|---|
| 1 ext4 | ✅ | 递归 fsnotify（实测） |
| 2 连续多文件、整段重写 | ✅ | 服务端 + 客户端两级合并；新目录能正确加入监听（实测） |
| 3 独立页 | ✅ | SPA |
| 4 ≤1s | ✅（有条件） | 单次写入实测约 300–340ms 后画面更新。持续写入时，理论上最坏约 1s（服务端最长等待）+ 0.5s（客户端最长等待）+ 取数时间，可能超过 1s（推断，待验证） |
| 4 不整页跳动 | ✅ | 实测写入后 `load` 事件数为 0 |
| 4 按阅读位置恢复 | 🔧 | 只保留像素偏移。实测上方插入后从 S20 漂到 S19（标题偏移 56px → 824px）；先截断再写入则回到顶部（§3） |
| 5 跟随模式 | 🔧 | 没有自动切换。现成的基础：推送里带路径；"Recent" 列表按修改时间排序（实测非 git 目录下 `/api/recent/all` 返回 `untracked: true` 的条目和 mtime） |
| 6 GFM / 高亮 / Mermaid / 图片 / 相对链接 / 目录树 | ✅ | 前端依赖 remark-gfm、rehype-highlight、mermaid（打包进前端，离线可用）、rehype-sanitize、KaTeX（[frontend/package.json](https://github.com/mschulkind-oss/vantage/blob/5b019da358b513e1a212bc1beaa4458ebce1e5d0/frontend/package.json)）。实测：图片经 `/api/content?path=sub%2Fp.png` 加载成功；相对链接 `sub/s.md` 点击后在应用内导航；侧栏是懒加载的目录树，Mermaid 渲染出了 SVG |
| 7 单文件静态二进制 | ✅ | 见下方"分发" |

**安全默认值**（所有候选里唯一基本合格的）
- **绑定地址**：默认 `127.0.0.1`。实测 `netstat` 显示 `127.0.0.1:8000`，经非回环 IP 连不上。
- **WS Origin**：只放行 `localhost`、`127.0.0.1`、`::1` 和配置里声明的主机，空 Origin 也放行（[ws.go:50-78](https://github.com/mschulkind-oss/vantage/blob/5b019da358b513e1a212bc1beaa4458ebce1e5d0/internal/live/ws.go#L50-L78)）。实测 evil Origin 返回 `403 Forbidden`。
- **路径**：`pathsafe.Resolve` 是全项目唯一的路径入口，先做词法检查（`..`、绝对路径、`.git`），再用 `EvalSymlinks` 校验物理路径仍在根目录内（[pathsafe.go:58-126](https://github.com/mschulkind-oss/vantage/blob/5b019da358b513e1a212bc1beaa4458ebce1e5d0/internal/pathsafe/pathsafe.go#L58-L126)）。实测 `link.txt`、`etc/hostname`、`../outside.md`、`%2e%2e/outside.md` 全部返回 `Path traversal detected`。
- **CORS**：没有 CORS 头，浏览器会拦下跨域读取。
- **缺口**：有写接口（`POST /api/starred`、`/api/review/comments` 等，见 [routes.go](https://github.com/mschulkind-oss/vantage/blob/5b019da358b513e1a212bc1beaa4458ebce1e5d0/internal/api/routes.go)），但没有 CSRF 或 Origin 校验。实测跨域的 `text/plain` 简单 POST 返回 200。写入位置是 `~/.local/share/vantage/reviews` 和收藏目录，不在笔记根目录里（[review/store.go:80](https://github.com/mschulkind-oss/vantage/blob/5b019da358b513e1a212bc1beaa4458ebce1e5d0/internal/review/store.go#L80)）。
- **不是严格只读**：评审 inbox 会消费（重命名、删除）根目录下 `.vantage/inbox` 里的文件。只有 agent 往里写文件时才会发生（[watcher.go:317](https://github.com/mschulkind-oss/vantage/blob/5b019da358b513e1a212bc1beaa4458ebce1e5d0/internal/live/watcher.go#L317) 附近）。

**分发**
- Release 有 `linux_amd64` / `linux_arm64` tar.gz，各约 46MB。([v0.7.0](https://github.com/mschulkind-oss/vantage/releases/tag/v0.7.0))
- 实测 `vantage` 在两个架构上都是 `statically linked`，`go version -m` 显示 `CGO_ENABLED=0`。压缩包里另有一个动态链接的 `vantage-check`，预览用不到。
- publish workflow 注释写明用 `CGO_ENABLED=0` 构建静态二进制。([publish.yml](https://github.com/mschulkind-oss/vantage/blob/5b019da358b513e1a212bc1beaa4458ebce1e5d0/.github/workflows/publish.yml))
- 实测 `env -i PATH=/nonexistent` 下（没有 git）也能正常提供目录树、内容和最近文件，git 只是可选增强。
- 注意：README 写 "Windows is not supported"（[README.md:15](https://github.com/mschulkind-oss/vantage/blob/5b019da358b513e1a212bc1beaa4458ebce1e5d0/README.md#L15)），指的是原生 Windows。在 WSL 里跑属于 Linux，但上游没有声明测试过 WSL。

**要改的源码与侵入程度**

| 缺口 | 改动位置 | 侵入程度 |
|---|---|---|
| 跟随模式 | `frontend/src/hooks/useWebSocket.ts` 的 `processBatch`：开关打开且变更列表里有别的 `.md` 时，导航到其中最新的那个；再在 `components/SettingsDropdown.tsx` 加开关（默认关，存 localStorage 或 sessionStorage）；配 vitest 用例 | 小：一个 hook 分支 + 一个设置项。服务端不用改 |
| 标题锚定恢复 | `components/MarkdownViewer.tsx`（或 `useRepoStore.loadFile` 周围）：替换内容前记下视口顶部的标题 id 和偏移，渲染完（包括 Mermaid 渲染完）后滚回该标题。空文件或半截文件的中间态要特别处理（例如标题找不到就不动，等下一次） | 中小：一个 hook 加上 e2e 用例（仓库已有 Playwright） |
| 写接口 CSRF（可选） | `internal/server` 加中间件，对非 GET 请求校验 `Origin` / `Sec-Fetch-Site` | 小 |
| 收窄功能面（可选） | 如果要求"严格只读"：关掉 review / inbox / starred | 中：要么动路由，要么加配置开关 |

Apache-2.0，允许 fork，需保留 LICENSE 与 NOTICE。仓库有 `AGENTS.md` 和 `just check` 质量门，也接受外部贡献（[README Development 一节](https://github.com/mschulkind-oss/vantage/blob/5b019da358b513e1a212bc1beaa4458ebce1e5d0/README.md)）。上游是否接受这两个功能未知。

### 2.4 mdserve v1.1.0（盘点遗漏，已归档）

源码基准：[jfernandez/mdserve@68afb33](https://github.com/jfernandez/mdserve/tree/68afb33f6f28870b03139d54073cf6232e93ece0)。

- **状态**：README 顶部声明 2026-09 归档，"no further releases, bug fixes, or security updates. Forks are welcome"。
- **目录模式**：只监听根目录一层，`RecursiveMode::NonRecursive`（[app.rs:290](https://github.com/jfernandez/mdserve/blob/68afb33f6f28870b03139d54073cf6232e93ece0/src/app.rs#L290)）。README 自述 "Only monitors the immediate directory (non-recursive)"。实测 `sub/s.md` 返回 404，侧栏只列出根目录下的 `.md`。
- **刷新**：收到 `Reload` 消息后 `window.location.reload()`，整页刷新（[main.html:618](https://github.com/jfernandez/mdserve/blob/68afb33f6f28870b03139d54073cf6232e93ece0/templates/main.html#L618)）。
- **安全**：
  - 默认 `127.0.0.1`（[main.rs:18](https://github.com/jfernandez/mdserve/blob/68afb33f6f28870b03139d54073cf6232e93ece0/src/main.rs#L18)，实测）。
  - 图片等静态文件经 `canonicalize` + `starts_with` 校验，能防符号链接逃逸（[app.rs:587-589](https://github.com/jfernandez/mdserve/blob/68afb33f6f28870b03139d54073cf6232e93ece0/src/app.rs#L587-L589)）。
  - 但全局套了 `CorsLayer::permissive()`（[app.rs:304](https://github.com/jfernandez/mdserve/blob/68afb33f6f28870b03139d54073cf6232e93ece0/src/app.rs#L304)）。实测响应头 `access-control-allow-origin: *`，即**任意网站都能 fetch 读取渲染后的笔记**。
  - WS 不校验 Origin（实测 101）。
  - `allow_dangerous_html = true`（[app.rs:163](https://github.com/jfernandez/mdserve/blob/68afb33f6f28870b03139d54073cf6232e93ece0/src/app.rs#L163)）。
- **分发**：有 `x86_64/aarch64-unknown-linux-musl` 二进制，实测 `static-pie linked`。
- **判定**：标准 7 ✅。标准 6 的目录树、标准 2 的子目录、标准 4、标准 5 都需改源码，而且没有上游可以贡献，只能 fork。

### 2.5 其他（简评）

- **mdprev**（[naoki-higashi-28/mdprev@c689182](https://github.com/naoki-higashi-28/mdprev/tree/c689182d7352e8f1fde502200bad68d368227b77)，2★）：功能组合与需求很接近，但体量小、最后提交在 2026-02，**没有做运行实测**。
  - README 列出：目录树侧栏、Mermaid、离线、实时刷新。
  - 源码显示：默认 `127.0.0.1`（`cmd/command.go:36`），路径校验中间件用 `EvalSymlinks`（`internal/application/middleware/path_validator_middleware.go:23-51`），推送用 SSE（`web/src/shared/api/watch-api-service.ts`），fsnotify 递归监听。
  - 实测 `mdprev-linux-amd64` 是动态链接的。
- **markdown-proxy**（[patakuti/markdown-proxy@33cab84](https://github.com/patakuti/markdown-proxy/tree/33cab84b75a56713cfc3cf5f8fa5d9342942437a)）：默认 `127.0.0.1`，SSE + fsnotify，但刷新是 `location.reload()`（`internal/template/template.go:185,253`）；release 只有 linux_amd64。
- **mdopen**：没有 GitHub release 二进制，只能 `cargo install`（违反标准 7）；reload 默认关闭（`src/cli.rs:59`）。
- **Hugo**：`hugo server -N/--navigateToChanged` 会在 live reload 时"navigate to changed content file"（[commands/server.go](https://github.com/gohugoio/hugo/blob/master/commands/server.go)、[文档](https://github.com/gohugoio/hugo/blob/master/docs/content/en/commands/hugo_server.md)），是"跟随模式"的现成先例。但 Hugo 需要站点结构（配置、布局），不适合直接预览任意笔记目录，所以不作为候选。

## 3. 实测：刷新时的阅读位置

**方法**（脚本在 `/tmp/r/scrolltest2.js`、`scrolltest3.js`，是临时文件，未入库）：
- 测试文档：`# Doc` + 一个 Mermaid 块 + `## S1`…`## S30`，每节 6 段。
- 视口 1200×800，先把 `## S20` 滚到视口顶部，然后在 WSL 外的普通 ext4 目录里改写文件。
- 每 20ms 采样一次：S20 标题的位置、第一个可见的 h2、是否发生了页面加载。
- 每种组合跑 2 次，结果一致。

**场景 A：在 S5 前插入一整节（约 700–770px）**，模拟 agent 在上方追加内容。

| 工具 | 刷新方式 | 首次变化 | 过程 | 最终 |
|---|---|---|---|---|
| go-grip | 整页 reload（`load` 1 次） | ~120ms | S20 → 导航中 → 页面空白 → S20 | S20 在顶部（Chromium 刷新时的滚动恢复；go-grip 本身没有相关代码） |
| markserv | innerHTML 局部替换（`load` 0 次） | ~160–190ms | 一步到位 | **S20 被推到 702px，顶部变成 S18/S19** |
| Vantage | React 重新渲染（`load` 0 次） | ~300–340ms | 一步到位 | **S20 从 56px 被推到 824px，顶部变成 S19** |

**场景 B：先写空文件，400ms 后写回原内容**，模拟分两步写入或截断后重写。

| 工具 | 最终 |
|---|---|
| go-grip | 刷新 2 次，停在文档顶部（S20 位于 9289px） |
| markserv | 停在顶部（第一个可见的是 S1） |
| Vantage | 停在顶部（第一个可见的是 S1） |

**解读**：三者都没有"按标题恢复"。局部替换的工具避免了白屏，但位置会漂移。整页 reload 在场景 A 里恰好落对，靠的是 Chromium 刷新时的恢复机制，可在真实的 Edge / Chrome 上是否同样成立、中间的白屏闪烁用户能否接受，都要真机确认。场景 B 在真实工作流里会不会出现，取决于 codex cli 写文件的方式（待验证）。

## 4. 差距表

| 标准 | go-grip | markserv | **Vantage** | mdserve |
|---|---|---|---|---|
| 1 ext4 范围 | ✅ | ✅ | ✅ | 🔧 只监听根目录一层 |
| 2 连续多文件、整段重写 | 🔧 新目录漏监听；任何变化都整页刷新全部页面 | ✅ | ✅ | 🔧 子目录不可见 |
| 3 独立浏览器页 | ✅ | ✅ | ✅ | ✅ |
| 4a ≤1s | ✅ ~120ms | ✅ ~170ms | ✅ ~320ms（连续写入待验证） | ✅（推断） |
| 4b 不整页跳动 | 🔧 整页 reload | ✅ | ✅ | 🔧 整页 reload |
| 4c 按阅读位置恢复 | 🔧 | 🔧 | 🔧 | 🔧 |
| 5 跟随模式 | 🔧 协议里没有路径 | 🔧 协议里没有路径 | 🔧 协议里有路径，只差前端 | 🔧 |
| 6 GFM / 高亮 | ✅ | ✅ | ✅ | ✅ |
| 6 Mermaid 离线 | ✅ | 🔧 走 CDN | ✅ | ✅ |
| 6 本地图片 / 相对链接 | ✅ | ✅ | ✅（实测） | ✅ / 仅根目录一层 |
| 6 预览页内目录树 | 🔧 只有逐级目录列表 | 🔧 只有目录索引页 | ✅ 侧栏树 | 🔧 平铺侧栏 |
| 7 静态二进制 amd64 / arm64 | ⚙️ amd64 是动态链接 / arm64 ✅ | ❌ 需 Node | ✅ / ✅ | ✅ musl / ✅ |
| 安全：只绑回环 | ❌ 实际监听所有网卡 | ⚠️ HTTP 回环，WS 所有网卡 | ✅ | ✅ |
| 安全：WS 校验 Origin | ❌ | ❌ | ✅ | ❌（另有 CORS `*`） |
| 安全：路径穿越 / 符号链接 | `..` ✅ / 符号链接 ❌ | ❌ / ❌ | ✅ / ✅ | ✅ / ✅ |
| 安全：原始 HTML | 未清洗 | 未清洗 | 用 rehype-sanitize | 未清洗 |
| 许可证 | MIT | MIT | Apache-2.0 | MIT |
| 上游状态 | 活跃 | 刚恢复发版 | 非常活跃，项目很新（14★） | **已归档** |

## 5. 两种方式的改动面

### 5.1 fork / 向上游贡献现成工具

**首选基线：Vantage。** 缺口只在前端，外加可选的安全收口：

1. **跟随模式**：改 `useWebSocket.ts` 的 `processBatch`，在设置下拉里加一个开关，写单元测试。协议和服务端不用动。
2. **标题锚定的阅读位置恢复**：在 `MarkdownViewer` 的内容替换前后记录并恢复"视口顶部标题 + 偏移"，并处理 Mermaid 异步渲染造成的布局位移，以及空文件或半截文件的中间态。写 e2e 用例。
3. （可选）写接口加 CSRF 或 Origin 校验中间件。
4. （可选）"严格只读"的裁剪：关闭 review、inbox、starred。

风险：
- 要背负约 28k 行（Go + TS），而且大部分与需求无关；
- 上游迭代很快（几乎每天有提交），fork 同步成本高；
- 上游是否接受第 1、2 项未知；
- 上游没有声明测试过 WSL；
- inotify 耗尽时只报错、不降级为轮询。

**不建议作为基线**：
- go-grip：接近重写，见 §2.1 末尾的改动表；
- markserv：Node 运行时这一点无解；
- mdserve：已归档，而且要改递归监听、树、刷新和 CORS，改动面和 go-grip 相当。

### 5.2 自己做

需要从零实现的组件：

| 组件 | 内容 | 可参考 |
|---|---|---|
| 服务端 HTTP 与静态资源内嵌 | 单二进制，`CGO_ENABLED=0` | — |
| 渲染管线 | goldmark：GFM、chroma 高亮、Mermaid 客户端模式、标题 slug 加前缀；关闭 unsafe，或开启时用 bluemonday 清洗 | go-grip 的 `internal/parser.go` 与 `pkg/*`（MIT） |
| 文件监听 | 递归 fsnotify、新目录自动加入、合并窗口、ENOSPC 降级为轮询 | Vantage 的 `internal/live/watcher.go` / `coalescer.go` 思路（Apache-2.0） |
| WS 推送 | 消息带路径、校验 Origin、goroutine 随 ctx 退出 | Vantage `ws.go` 的 Origin 白名单 |
| 路径安全 | 词法检查 + `EvalSymlinks` 根目录校验 | Vantage `pathsafe.go` |
| 目录树 | 快照 + 增量更新 | — |
| 前端：侧栏树 | — | — |
| 前端：预览容器 | 取回片段后局部替换，Mermaid 重新渲染 | — |
| 前端：阅读位置 | 按标题恢复 | — |
| 前端：跟随模式 | 开关 | — |
| 发布流水线 | linux amd64 / arm64 静态二进制 | — |

改动面：以上全部从零写，包括测试。好处是功能面最小、完全可控、严格只读，安全默认值和阅读位置可以按验收标准直接设计。代价是 Vantage 已经做好的部分（监听的边界情况、路径安全、树、GFM 与 Mermaid 渲染、打包）都要重做一遍。

## 6. 倾向与理由

**倾向：先不自己做，以 Vantage 为基线。**

1. 先按第 7 节的清单做真机验证（WSL2 + Windows 浏览器 + codex cli 实际写入）。
2. 验证通过后，把"跟随模式"和"标题锚定恢复"做成两个前端补丁，先提给上游，被拒再维护一个轻量 fork。

理由：
- 在 7 条标准里，Vantage 原生满足 1、2、3、4a、4b、6、7，缺的 4c 和 5 只落在前端两个位置，服务端协议已经带路径，不用改；
- 安全默认值（只绑回环、校验 Origin、符号链接校验）是所有候选里唯一合格的，能省掉自己做时最容易出错的部分；
- 相比之下，改 go-grip 或 mdserve 的工作量接近自己做，markserv 违反零依赖。

**转为"自己做"的触发条件**（满足任一条）：
- 真机验证发现 Vantage 在 WSL2 下有无法用配置绕过的问题；
- 连续写入时延迟稳定超过 1s；
- 上游拒绝上述补丁，且不愿长期维护一个同步约 28k 行的 fork；
- 用户坚持"严格只读 + 最小功能面"，不接受 review、inbox 这类写入功能留在二进制里。

自己做时，渲染管线参考 go-grip（MIT），监听、合并窗口与路径安全参考 Vantage（Apache-2.0，需署名）。

## 7. 待真机验证项

1. **WSL2 + Windows 浏览器实际可达性**：Vantage（`127.0.0.1`）、go-grip（所有网卡）、markserv（HTTP 在 `::1`，WS 在另一个端口）在 NAT 模式和 mirrored 模式下，能否从 Windows 的 Edge / Chrome 用 `localhost` 访问。重点是 markserv 只绑 `::1` 时 localhost 转发是否生效。
2. **codex cli 的写文件方式**：原地截断后写入、分块写入，还是写临时文件再 rename？这决定了 §3 的场景 B（位置丢失）在实际中是否出现，也决定了 fsnotify 事件序列。
3. **持续写入时的延迟**：agent 连续改多个文件时，Vantage 两级合并（服务端最长 1s + 客户端最长 0.5s）是否会让画面更新超过 1s。
4. **真实浏览器（非 headless）的整页 reload 体验**：go-grip 场景 A 在 Edge 上是否同样落回原标题，白屏闪烁是否明显。
5. **大目录的 inotify 上限**：Vantage 递归监听所有目录，超出 `max_user_watches` 时只报错。需要确认用户的笔记根目录规模和 WSL 默认上限。
6. **Vantage 在 WSL 下启动**：打开浏览器用的是 `xdg-open`（`cmd/vantage/serve.go:329`），WSL 里可能不存在，预计要加 `--no-open` 手动打开。另外确认一下"Windows is not supported"对 WSL 没有其他影响。
7. **Mermaid 与阅读位置的相互作用**：局部替换后 Mermaid 异步渲染会改变布局，标题锚定恢复要在 Mermaid 渲染完成后执行，需要在真实文档上验证。
8. **go-grip amd64 动态二进制**：在目标发行版（glibc 版本）上能否直接运行。仅在选 go-grip 时才需要确认。

## 8. 来源清单

- go-grip：https://github.com/chrishrb/go-grip （commit `591f1ae`；release https://github.com/chrishrb/go-grip/releases/tag/v0.10.0 ）
- aarol/reload v1.2.0：https://github.com/aarol/reload/tree/v1.2.0
- markserv：https://github.com/markserv/markserv （commit `dcc216a`；npm `markserv@1.20.0`）
- Vantage：https://github.com/mschulkind-oss/vantage （commit `5b019da`；release https://github.com/mschulkind-oss/vantage/releases/tag/v0.7.0 ）
- mdserve：https://github.com/jfernandez/mdserve （commit `68afb33`；release https://github.com/jfernandez/mdserve/releases/tag/v1.1.0 ）
- mdprev：https://github.com/naoki-higashi-28/mdprev （commit `c689182`；release v0.5.2）
- markdown-proxy：https://github.com/patakuti/markdown-proxy （commit `33cab84`）
- mdopen：https://github.com/immanelg/mdopen
- Hugo `server`：https://github.com/gohugoio/hugo/blob/master/docs/content/en/commands/hugo_server.md
- WSL 网络：https://learn.microsoft.com/en-us/windows/wsl/networking
- GitHub 搜索 API：`https://api.github.com/search/repositories?q=…`（2026-09-24）
