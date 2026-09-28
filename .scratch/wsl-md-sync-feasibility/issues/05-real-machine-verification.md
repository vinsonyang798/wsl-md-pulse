Type: task
Status: claimed
Blocked by: 01, 03, 04, 07

# 真机实测：WSL2 监听与访问通道

## Question

研究无法确定的事实，需要在一台真实的 Windows 11 + WSL2 机器上测出来（云端 agent 环境不是 WSL，测不了）。由 agent 把下面的实验整理成一份可复制执行的检查清单（尽量是 WSL 侧一条脚本 + PowerShell 侧一条脚本），交给用户运行并回填结果。清单要能在不装任何东西的前提下运行：WSL 侧只用发行版自带工具（`inotifywait` 不一定预装，需要一个替代方案），Windows 侧只用 PowerShell 和浏览器。

实验来源（命令已写在研究笔记里）：

- [WSL2 文件变更检测的事实边界](../research/03-wsl-file-change-detection.md) 第 7 节：
  - **E2-b**：Windows 经 `\\wsl.localhost` 修改 ext4 上的文件，WSL 内 inotify 是否收到（决定"Windows 编辑器 + ext4"能否走原生通知）。
  - **E3**：`/mnt/c` 上 Windows 侧与 WSL 侧修改的事件情况。
  - **E5**：ext4、`/mnt/c`、`\\wsl.localhost` 上单次 stat 与一轮扫描的耗时（决定轮询间隔是否可接受）。
  - **E7**：vim、VS Code 保存时的事件序列。
  - 可选：E1（`max_user_watches` 实际值）、E4、E6（virtiofs）。
- [Windows 侧访问 WSL 内服务与画面通道](../research/04-windows-to-wsl-display-channel.md) 第 6 节：
  - **E1**：不同绑定地址 × 不同访问地址的连通性矩阵（含 VPN）。
  - **E3**：WebSocket/SSE 在空闲、睡眠、Wi-Fi 重连后的恢复。
  - **E6**：`cmd.exe`/`powershell.exe` 打开 URL 的效果（含 `&` 截断）。
  - **E9**：关闭所有终端后服务是否存活，以及 `instanceIdleTimeout=-1` 的效果。
  - 可选：E2、E4、E5（mirrored）、E7、E8、E10。
- [现成工具对照验收标准的差距](../research/07-existing-tools-vs-acceptance.md) 的待真机验证项（取代原先对 go-grip、markserv 的实测）。

按"使用场景与'同步显示'的验收标准"裁剪（文件只在 ext4，写入方是 WSL 内的 agent，Windows 不装东西）：

- **必做**：
  - 文件检测研究：E1（`max_user_watches` 实际值）；E7（改为：codex cli 写文件时的 inotify 事件序列，外加 vim 对照）；以及在 ext4 上连续快速改多个文件时，事件是否完整、防抖后能否在 1 秒内完成。
  - 访问通道研究：E1、E3、E6、E9。
  - 现成工具：Vantage 在 ext4 上被 codex 修改后的刷新延迟与滚动表现。重点看 agent 连续改多篇时，两级合并窗口是否超过 1 秒；以及打开浏览器是否需要 `--no-open` 再手动打开（见"现成工具对照验收标准的差距"研究笔记的待验证项）。
  - codex cli 的写文件方式：原地截断后写入、分块写入，还是写临时文件再改名。这决定"文件短暂为空、预览跳回顶部"的情况会不会出现。
- **可选**：
  - 用户的 VS Code 预览为什么不刷新（WSL 模式下重测一次）。
  - 访问通道研究的 E2、E4、E5（mirrored）。
- **删除**：
  - 文件检测研究的 E2-b、E3、E4、E6，以及 E5 中 `/mnt/c` 和 `\\wsl.localhost` 的部分。
  - 访问通道研究的 E8、E10（Windows 侧程序与 WSLg 方案已排除）。

完成条件：结果（WSL 版本、Windows 版本、每项通过/失败/延迟）记录在本票答案中。

## 执行步骤

脚本在 [`probe/`](../probe/)：`wsl-probe.sh`（WSL 侧，只用 bash 和 python3 标准库）和 `windows-probe.ps1`（Windows 侧，只用 PowerShell 5.1、`curl.exe` 和浏览器）。两者都不安装任何东西；唯一的下载是 `vantage` 子命令把 Vantage 的发布包解压到 `~/wsl-md-probe/bin/`。

在 WSL 终端里，进入本仓库的 `.scratch/wsl-md-sync-feasibility/probe/` 目录：

1. `bash wsl-probe.sh files --root ~/notes`：inotify 上限、各种写入方式的事件序列、连续写入、新建目录的竞态、vim 对照、**codex 写文件的方式**（可以让脚本自动调用 `codex exec`，也可以自己在另一个终端操作）。
2. `bash wsl-probe.sh browser`：从 WSL 打开 Windows 浏览器的各种方式（每一步要看一眼浏览器地址栏）。
3. `bash wsl-probe.sh vantage`：Vantage 的推送延迟（自动）和 Windows 浏览器里的阅读位置（要看屏幕）。
4. `bash wsl-probe.sh serve`：启动探测服务并保持运行。它会把 `windows-probe.ps1` 复制到 `%USERPROFILE%\wsl-md-probe\`，并打印在 PowerShell 里要运行的命令。
5. 在 Windows PowerShell 里运行上一步打印的命令。脚本最后一步会让你运行 `bash wsl-probe.sh serve-bg`，然后关闭所有 WSL 终端。

把 WSL 里的 `~/wsl-md-probe/results/` 和 Windows 上的 `%USERPROFILE%\wsl-md-probe\windows-*.log` 发回来。

## Comments

### 云主机预跑（Linux 6.12，不是 WSL，只能说明脚本能跑通；数字仅供参考）

- 原地覆盖写和"先清空再写"都会出现 0 字节的中间状态；写临时文件再改名则不会，但 inode 会变。
- 5 个文件 × 20 轮连续写入，没有丢事件，也没有 `Q_OVERFLOW`。
- **新建子目录后立刻写文件：20 次里有 9 次文件事件丢失**。递归监听补加 watch 之后，必须重新扫描新目录。
- Vantage 0.7.1：单次写入约 101ms 后推送；每 150ms 写一次时每次都是约 101ms；**每 50ms 写一次时最坏 1002ms**（碰到了它 1 秒的最长等待窗口）。加上浏览器端 150–500ms 的合并，画面更新可能超过 1 秒。需要真机确认 codex 的实际写入频率会不会触发这种情况。

### 第 1 批真机结果（2026-09-28，用户机器；`serve` + `windows-probe.ps1 -SkipSleep`）

环境：Windows 10 专业版 22H2（build 19045.2604）；WSL 2.7.14.0，内核 6.18.33.2-2；网络模式 `nat`；没有 `.wslconfig`；没有代理；启用的网卡只有有线网卡和 `vEthernet (WSL)`，看起来没有连 VPN（用户没有明确回答）。
**Windows 10 不支持 mirrored 模式**（需要 Win11 22H2+），所以这台机器上只有 NAT 一条路，访问通道研究里的 E5 对它不适用。

**绑定地址 × 访问地址（访问通道研究 E1）**：

| WSL 内绑定 | `127.0.0.1` | `[::1]` | `localhost` | Windows 侧 `wslrelay` 监听在 |
|---|---|---|---|---|
| `127.0.0.1` | ✅ | ❌ | ✅ | `127.0.0.1` |
| `0.0.0.0` | ✅ | ❌ | ✅ | `127.0.0.1` |
| `::` 双栈 | ❌ | ✅ | ✅（慢约 200ms） | `::1` |
| 只绑 `::1` | ❌ | ✅ | ✅（慢约 200ms） | `::1` |

- 证实了"绑双栈 `::` 时 relay 只在 `::1` 上监听、`127.0.0.1` 连不上"（#4851）。`localhost` 同时解析出 `::1` 和 `127.0.0.1`，客户端会回退，所以都能通，但要多花一次失败连接的时间。
- 浏览器实际打开了 `localhost:8801` 和 `localhost:8803`（WSL 侧日志里有浏览器的 GET 和 favicon 请求），两页都加载成功。
- 结论：**服务绑 `127.0.0.1`，打印给用户的 URL 也写 `127.0.0.1`**，与研究结论一致。
- 注：表中的 150–400ms 包含启动 `curl.exe` 进程的时间，不代表转发延迟；转发延迟看下面 WebSocket 的连接耗时。

**WebSocket / SSE（访问通道研究 E3 的基本部分）**：通过 `127.0.0.1` 和 `localhost` 访问都成功，WebSocket 建连 7–20ms，消息每秒一条、没有丢。浏览器探测页加载后 `ws open` 和 `sse open` 都回报给了 WSL（请求带的 Origin 是 `http://127.0.0.1:8820`）。
（`sse gone` / `ws gone` 是 PowerShell 测试客户端读完 3 条后主动断开，属于正常现象。日志里的 `GET /undefined` 来自浏览器侧，与本测试无关。）

**尚未完成**：睡眠、断网、空闲后的恢复（这次跳过了）；关闭所有终端后服务是否存活（E9，没做）；`files`（**codex 写文件的方式**）、`browser`、`vantage` 三个 WSL 子命令的结果。
