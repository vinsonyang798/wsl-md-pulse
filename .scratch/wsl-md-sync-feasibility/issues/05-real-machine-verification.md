Type: task
Status: open
Blocked by: 03, 04

# 真机实测：WSL2 监听与访问通道

## Question

研究无法确定的事实，需要在一台真实的 Windows 11 + WSL2 机器上测出来（云端 agent 环境不是 WSL，测不了）。本票在"WSL2 文件变更检测的事实边界"和"Windows 侧访问 WSL 内服务与画面通道"关闭后，由 agent 根据其中列出的"待真机验证"项整理成一份可复制执行的检查清单（尽量是一条脚本），交给用户运行并回填结果。

预期覆盖（以研究结论为准再增删）：ext4 与 `/mnt/c` 上的 inotify 事件（WSL 内与 Windows 侧各改一次、含 vim 原子保存）；Windows 侧对 `\\wsl.localhost` 的变更通知；`localhost:<port>` 在 NAT/mirrored 下的 HTTP 与 WebSocket 连通性；`wslview`/`cmd.exe` 打开浏览器。

完成条件：结果（WSL 版本、Windows 版本、每项通过/失败/延迟）记录在本票答案中。
