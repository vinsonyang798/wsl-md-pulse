Type: task
Status: open
Blocked by: 01, 03, 04

# 真机实测：WSL2 监听与访问通道

## Question

研究无法确定的事实，需要在一台真实的 Windows 11 + WSL2 机器上测出来（云端 agent 环境不是 WSL，测不了）。由 agent 把下面的实验整理成一份可复制执行的检查清单（尽量是 WSL 侧一条脚本 + PowerShell 侧一条脚本），交给用户运行并回填结果。

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
- [现成方案盘点](../research/02-existing-solutions-survey.md) 第 4 节：go-grip（可再加 markserv）在 ext4 与 `/mnt/c` 上的实际刷新表现、刷新后是否保留滚动位置。

哪些必做、哪些可选，要等"使用场景与'同步显示'的验收标准"讨论完再定。例如文件从不放 `/mnt/c`，E3/E5 的 `/mnt/c` 部分就可以省掉。

完成条件：结果（WSL 版本、Windows 版本、每项通过/失败/延迟）记录在本票答案中。
