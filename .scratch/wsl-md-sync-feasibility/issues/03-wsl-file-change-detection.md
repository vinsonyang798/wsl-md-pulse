Type: research
Status: resolved
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

## Answer

**唯一可靠的原生通知路径是：在 WSL 内监听 ext4 上的*目录*（inotify）。所有跨越 WSL/Windows 边界的路径都收不到原生通知，只能轮询。** 详细来源、置信度，以及 E1–E7 真机实验命令见 [研究笔记](../research/03-wsl-file-change-detection.md)。

- **ext4 + WSL 内 inotify：完全可用（高）。** Linux 5.11 起 `max_user_watches` 按内存动态计算（8192 到 1048576 之间）。监听数耗尽时，添加监听那一刻会同步报 `ENOSPC`，可以据此降级到轮询；真正会静默丢事件的是 `IN_Q_OVERFLOW`。推论（中）：Windows 编辑器经 `\\wsl.localhost` 保存文件时，写入由发行版内的 plan9 服务器进程完成，所以 WSL 内的 inotify 应该能收到。
- **`/mnt/c`（9p）：Windows 侧修改收不到（高）。** 添加监听成功，但一个事件都没有（microsoft/WSL#4739，至今未关）。WSL 内程序修改 `/mnt/c` 能收到（中）。
- **Windows 侧监听 `\\wsl.localhost`：不支持（高）。** `ReadDirectoryChangesW` 在这类路径上失败（#7674，至今未关；#4581 未修复就被自动关闭）。VS Code、JetBrains 的做法都是把监听放在 Linux 一侧。
- **原子保存（高）。** vim 默认把原文件改名为备份再写新文件，inode 会变，还会临时创建 `4913` 探测文件；VS Code 是先截断再原地写。所以必须监听目录、做防抖，并能处理"先读到 0 字节"的中间状态。
- **轮询。** ext4 上开销很小（单次 stat 约 µs 级）。`/mnt/c` 不缓存元数据，每次 stat 都要多次往返宿主，估计慢一到两个数量级（低置信度，需真机测）。
- **近年变化。** mirrored 只影响网络，与文件无关；virtiofs 仍是实验特性、默认关闭，预计不会改变 `/mnt/c` 收不到通知的结论。
