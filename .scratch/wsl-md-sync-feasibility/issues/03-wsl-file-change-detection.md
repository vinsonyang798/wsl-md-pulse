Type: research
Status: open
Blocked by:

# WSL2 文件变更检测的事实边界

## Question

在 WSL2 下，"文件变了"能被可靠、及时地感知吗？分情况给出有来源的事实：

1. WSL 内进程监听 WSL 自身文件系统（ext4）：inotify 是否完全可用？`max_user_watches` 默认值与耗尽表现？
2. WSL 内进程监听 `/mnt/c` 等 Windows 盘（drvfs / 9p / Plan 9）：Windows 侧程序修改文件时，WSL 内能否收到 inotify 事件？WSL 内程序修改时呢？
3. Windows 侧进程监听 `\\wsl.localhost\<distro>\...`（`ReadDirectoryChangesW` / .NET `FileSystemWatcher`，走 Plan 9 服务器）：能否收到 WSL 内修改产生的通知？
4. 编辑器原子保存（写临时文件再 rename，如 vim、VS Code）对上述各路径的影响。
5. 轮询作为兜底：在 ext4 与跨边界路径上的开销与延迟量级。

每条结论标注来源（Microsoft Learn、microsoft/WSL GitHub issue、内核文档等）以及不确定程度；不确定的地方写成可在真机上验证的实验。
