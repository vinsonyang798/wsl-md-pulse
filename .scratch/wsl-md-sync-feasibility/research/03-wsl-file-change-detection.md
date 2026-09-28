# 研究：WSL2 文件变更检测的事实边界

对应票据：`issues/03-wsl-file-change-detection.md`
调研日期：2026-09-24。只采信一手来源：Microsoft Learn、microsoft/WSL 仓库（issue 和已开源的源码）、Linux 内核源码与 man-pages、fsnotify / chokidar / watchdog / VS Code / Vim 的官方文档或源码。每条结论后面都附了来源和置信度（高 / 中 / 低）。置信度不是"高"的项，在第 7 节给出了命令级的真机实验。

## 0. 结论速览

| 路径（谁在监听 → 文件在哪里 → 谁在改） | 能否收到原生通知 | 置信度 |
| --- | --- | --- |
| WSL 进程 inotify → WSL ext4 → WSL 进程修改 | 能，和普通 Linux 一样 | 高 |
| WSL 进程 inotify → WSL ext4 → Windows 程序经 `\\wsl.localhost` 修改 | 能：这类写入最终由发行版内一个 Linux 进程（plan9 服务器）执行 | 中（机制明确，需真机确认） |
| WSL 进程 inotify → `/mnt/c`（9p）→ Windows 程序修改 | **不能**：`inotify_add_watch` 成功，但不会有任何事件 | 高 |
| WSL 进程 inotify → `/mnt/c`（9p）→ 同一 WSL 实例内的进程修改 | 能（事件由本机 VFS 产生） | 中 |
| Windows 进程 `ReadDirectoryChangesW` / `FileSystemWatcher` → `\\wsl.localhost` / `\\wsl$` → WSL 进程修改 | **不能**：API 直接报错，或者静默不返回 | 高 |
| 轮询（stat / mtime+size 对比） | 所有路径都可用；ext4 上约 1 µs/次，跨 9p 每次 stat 都要往返宿主，慢一到两个数量级 | 高（定性）/ 中（定量） |

对"Windows 端实时预览 WSL 内 Markdown"的直接含义：**监听必须在 WSL 内、在 ext4 上用 inotify 做**，结果再通过其他通道（比如 HTTP/WebSocket）推给 Windows。Windows 侧程序直接监听 `\\wsl.localhost` 不可行，只能轮询。

---

## 1. WSL 内进程监听 WSL 自身 ext4

### 1.1 inotify 是否完全可用 —— 可用（置信度：高）

- WSL2 的发行版根文件系统是 VHD 里的 ext4，运行在真实的 Linux 内核中。Microsoft 成员 SvenGroot 的原话："With WSL2, the Linux file system is now an ext4 partition in a VHD. It cuts Windows out of the loop"。来源：https://github.com/microsoft/WSL/issues/4197#issuecomment-604592340
- Learn 上说明 WSL2 是完整的 Linux 内核，系统调用完全兼容（"Full system call compatibility"）。来源：https://learn.microsoft.com/en-us/windows/wsl/compare-versions
- 内核的 inotify 事件在 VFS 通用层产生，和具体文件系统无关：`vfs_write` 等路径调用 `fsnotify_modify()`（`fs/read_write.c`），创建类操作调用 `fsnotify_create()`（`fs/namei.c`）。来源：https://github.com/torvalds/linux/blob/master/fs/read_write.c 、https://github.com/torvalds/linux/blob/master/fs/namei.c
- VS Code 文档把"WSL1 下的文件监听问题"明确排除在 WSL2 之外："WSL 2 does not have that file watcher problem"。来源：https://github.com/microsoft/vscode-docs/blob/main/docs/remote/wsl.md
- inotify 本身的通用限制（和 WSL 无关，设计时要考虑）：
  - 不递归，每个子目录都要单独加 watch；新建子目录时，里面可能已经有文件，需要补扫描。
  - 相同事件在未读取前会被合并，不能用来计数。
  - mmap 写入不产生事件。
  - 队列溢出时产生 `IN_Q_OVERFLOW`（上限是 `max_queued_events`），需要全量重扫。

  来源：inotify(7)，https://man7.org/linux/man-pages/man7/inotify.7.html

**补充：Windows 程序经 `\\wsl.localhost` 修改 WSL 文件，WSL 内能否收到 inotify？（置信度：中）**
WSL 官方技术文档写明，`\\wsl.localhost` 背后的 plan9 服务器是"a Linux process that hosts a plan9 filesystem server… created by init in each distribution"。Windows 端 `p9rdr.sys` 通过 hvsocket 连到这个进程。来源：https://github.com/microsoft/WSL/blob/master/doc/docs/technical-documentation/plan9.md
因此 Windows 编辑器（比如 Windows 版 Typora 或 VS Code 本地窗口）通过 `\\wsl.localhost\...` 保存文件时，实际的 `write` / `rename` 由发行版内的 Linux 进程发出，应当经过 VFS 触发 inotify。这与 Microsoft 在 #4739 中给出的变通建议一致："using `\\wsl.localhost\` to access the files from the Linux file system"（https://github.com/microsoft/WSL/issues/4739 ，craigloewen-msft，2024-10-25）。
这是从机制推出来的，我没有找到直接的实测记录，所以列为待真机验证（实验 E2-b）。

### 1.2 `max_user_watches` 默认值 —— 按内存动态计算（置信度：高）

- 内核提交 `92890123749b`（"inotify: Increase default inotify.max_user_watches limit to 1048576"，2020-11，首次出现在 v5.11）把默认值从固定的 8192 改为按内存计算："use no more than 1% of addressable memory within the range [8192, 1048576]"。每个 watch 的成本估算为 `sizeof(inotify_inode_mark) + 2 * sizeof(struct inode)`。来源：https://github.com/torvalds/linux/commit/92890123749bafc317bbfacbe0a62ce08d78efb7
  - 对比 v5.10 与 v5.11 的 `fs/notify/inotify/inotify_user.c`：v5.10 是 `ucount_max[UCOUNT_INOTIFY_WATCHES] = 8192`；v5.11 是 `watches_max = ((totalram - totalhigh)/100 << PAGE_SHIFT) / INOTIFY_WATCH_COST; clamp(watches_max, 8192, 1048576)`。来源：https://raw.githubusercontent.com/torvalds/linux/v5.11/fs/notify/inotify/inotify_user.c
- 当前 WSL 内核都晚于 5.11，所以适用动态值。
  - #4739 在 2026-05 的复现里内核是 `6.6.87.2-microsoft-standard-WSL2`（https://github.com/microsoft/WSL/issues/4739）。
  - WSL PR #40654 已把内核包升到 `Microsoft.WSL.Kernel 6.18.26.3-1`（https://github.com/microsoft/WSL/pull/40654）。
- WSL2 VM 的内存默认是"50% of total memory on Windows"（`.wslconfig` 的 `[wsl2] memory`）。来源：https://learn.microsoft.com/en-us/windows/wsl/wsl-config
- **量级估算（置信度：中）**：我在一台 x86-64、6.12 内核、16.8 GB 内存的 Linux 云主机（不是 WSL）上实测 `max_user_watches = 127946`，约合每 GiB 内存 8k 个 watch。据此推算：
  - Windows 16 GB → WSL VM 8 GB → 约 6.5 万；
  - Windows 32 GB → WSL VM 16 GB → 约 13 万。

  发行版或其他软件可能在 `/etc/sysctl.d` 里覆盖这个值，实际数值待真机读取（实验 E1）。
- 另有 `max_user_instances`（本机实测默认 128），它限制的是每个用户的 inotify 实例数。
- 对 Markdown 笔记库来说，按目录计 watch 通常只需要几百到几千个，远低于上限。风险主要来自同一用户下其他监听者（VS Code Server、Node 开发服务器等）共享同一个配额。

### 1.3 耗尽表现 —— `ENOSPC`（置信度：高）

- `inotify_add_watch(2)`："ENOSPC The user limit on the total number of inotify watches was reached or the kernel failed to allocate a needed resource."。来源：https://man7.org/linux/man-pages/man2/inotify_add_watch.2.html
- fsnotify（Go）README："Reaching the limit will result in a 'no space left on device' or 'too many open files' error."。前者对应 `max_user_watches`，后者对应 `max_user_instances`（`EMFILE`）。来源：https://github.com/fsnotify/fsnotify/blob/main/README.md
- VS Code 的 Linux 文档把这种情况描述为"unable to watch for file changes in this large workspace (error ENOSPC)"，处理方法是先排除大目录，再调高 `fs.inotify.max_user_watches`。来源：https://github.com/microsoft/vscode-docs/blob/main/docs/setup/linux.md
- 要点：`ENOSPC` 在**加 watch 时同步返回**，不是之后静默丢事件，程序可以据此降级到轮询。静默丢事件的情况是 `IN_Q_OVERFLOW`（队列溢出），这时要全量重扫。

---

## 2. WSL 内进程监听 `/mnt/c`（drvfs → WSL2 下实际是 9p）

### 2.1 实现事实（置信度：高）

- WSL2 下 `/mnt/c` 由 `mount.drvfs` 挂载。根据 `.wslconfig`，实际挂载类型是 `plan9`、`virtio-plan9` 或 `virtiofs`。9p 服务器由 Windows 侧的 `wslservice.exe` 启动。来源：https://github.com/microsoft/WSL/blob/master/doc/docs/technical-documentation/drvfs.md
- 默认挂载参数中有 `cache=mmap`，传输方式是 `trans=fd`（hvsocket）或 `trans=virtio`。来源：`src/linux/init/drvfs.cpp`，https://github.com/microsoft/WSL/blob/master/src/linux/init/drvfs.cpp
- 9P 协议本身没有服务器向客户端推送变更的消息。Linux 的 v9fs 客户端（`fs/9p/`）也没有任何 fsnotify 相关代码。来源：https://github.com/torvalds/linux/tree/master/fs/9p 、https://docs.kernel.org/filesystems/9p.html
- inotify(7)："Inotify reports only events that a user-space program triggers through the filesystem API. As a result, it does not catch remote events that occur on network filesystems. (Applications must fall back to polling…)"。来源：https://man7.org/linux/man-pages/man7/inotify.7.html

### 2.2 Windows 侧程序修改 → WSL 内收不到 inotify（置信度：高）

- **microsoft/WSL#4739**：《[WSL2] File changes made by Windows apps on Windows filesystem don't trigger notifications for Linux apps》。2019-12 开启，**截至 2026-05 仍是 open**，标签为 `feature` 和 `wsl2`。
  - Microsoft 在被关闭的重复 issue #4701 里的定性："We need to add file watch capabilities to the Plan9 server that serves files **to** a WSL2 distro"（issue 内 therealkenc 转引）。
  - craigloewen-msft 2024-10-25："We're still tracking this as a known issue"，并建议把文件放进 Linux 文件系统，或经 `\\wsl.localhost\` 访问。
  - 2026-05-24 的一条复现（Windows build 26200，WSL 内核 6.6.87.2）显示：`fs.watch` 注册成功，但一个事件都没有；`fs.watchFile`（轮询）三次写入都检测到了。

  来源：https://github.com/microsoft/WSL/issues/4739
- 重复或相关的 issue：#4064、#4169、#4224、#4701、#5424（《WSL2 Inotify not working》，已作为重复关闭）。来源：https://github.com/microsoft/WSL/issues/5424
- 表现为**静默失败**：Zed 的 issue 描述"`inotify_add_watch()` succeeds without error, but no events are ever delivered"，并建议用 `statfs` 的 `V9FS_MAGIC` (0x01021997) 识别这类挂载。来源：https://github.com/zed-industries/zed/issues/51340
- 对照：WSL1 的 DrvFs 曾经支持 Windows 侧变更通知（#216 中 Microsoft 表示分两期实现，第二期基于类似 `ReadDirectoryChangesW` 的内部 API，只能给出 delete/rename/modify 这几类事件）。所以 #4739 里称之为"known regress"。来源：https://github.com/microsoft/WSL/issues/216

### 2.3 WSL 内程序修改 `/mnt/c` → 能收到（置信度：中）

- 依据：事件由本机 VFS 在系统调用路径上产生（见 1.1 的内核源码），不依赖文件系统的远程能力。WSL1 时期 #216 中 Microsoft 也说过"we can only report events that are triggered inside WSL"。
- 边界情况：
  - 由**另一个挂载实例**发起的修改不会通知到这里，比如 elevated 和非 elevated 两个 mount namespace（drvfs.md 说明它们是两套挂载），或者另一个发行版、Docker 容器。
  - #4739 的 2026-05 复现声称，Docker Desktop 容器内对 bind mount 的 `touch` 也收不到事件。那条链路还多了一层 Docker Desktop 的挂载，不能直接套用到"同一发行版内直接写 `/mnt/c`"的场景。

  所以这一项列为待真机验证（实验 E3-b）。

---

## 3. Windows 侧进程监听 `\\wsl.localhost\<distro>\...` / `\\wsl$`

### 3.1 结论：收不到 WSL 内修改的通知（置信度：高）

- **microsoft/WSL#7674**：《`ReadDirectoryChangesW` method is unsupported on `\\wsl$` paths》。由 VS Code 文件监听负责人 bpasero 在 2021-11 提交，标签为 `feature`，**至今 open**，WSL2 内核 5.10.x 有人复现。来源：https://github.com/microsoft/WSL/issues/7674
- **microsoft/WSL#4581**：《Unable to watch directory changes via `\\wsl$\` redirector》。
  - `FindFirstChangeNotification("\\\\wsl$\\Ubuntu-18.04\\")` 返回错误 1，也就是 `ERROR_INVALID_FUNCTION`。
  - `.NET FileSystemWatcher` "accepts this path but never returns anything"。
  - 该 issue 因一年无活动被机器人关闭（2024-02），并不是被修复。

  来源：https://github.com/microsoft/WSL/issues/4581
- `ReadDirectoryChangesW` 的官方文档写明："If the network redirector or the target file system does not support this operation, the function fails with ERROR_INVALID_FUNCTION."。它列出的支持技术只有 SMB 3.0、CsvFS、ReFS 等，不包括 9P。来源：https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-readdirectorychangesw
- **源码级佐证**：WSL 于 2025 年开源后，Linux 侧 plan9 服务器的消息集合（`src/linux/plan9/p9defs.h`）只有 9P2000.L 加上 `.W` 扩展的 `Taccess` / `Twreaddir` / `Twopen`，没有任何变更通知消息；`src/linux/plan9/` 中也没有 inotify 或 fanotify 相关代码。也就是说，Windows 端 `p9rdr.sys` 从协议上就拿不到 Linux 侧的变更。来源：https://github.com/microsoft/WSL/blob/master/src/linux/plan9/p9defs.h
- 应用层表现：
  - **Node.js（libuv）**：`fs.watch('\\\\wsl$\\...')` 报 `EISDIR`（https://github.com/nodejs/node/issues/37960）。原因是 libuv 把 `ERROR_INVALID_FUNCTION` 映射成 `UV_EISDIR`（https://github.com/libuv/libuv/blob/v1.x/src/win/error.c），这个错误名有误导性。
  - **VS Code 本地窗口**：打开 `\\wsl$` 目录时报 "File Watcher (parcel) … Failed to read changes (EUNKNOWN)"。bpasero 的说法是 "As it stands, file watching will not be supported if you open `\\$wsl\` paths today"，官方建议改用 Remote-WSL，让监听在 Linux 侧运行。来源：https://github.com/microsoft/vscode/issues/136894 、https://github.com/microsoft/vscode/issues/152537
  - **JetBrains IDE**：历来在 WSL 里单独运行 `fsnotifier`（日志中的 `WslFileWatcher.Ubuntu-18.04`），而不是在 Windows 上监听 UNC 路径。2025.2 起改为在 WSL 内运行 IJent 代理处理文件和进程操作（"The WSL file watcher has not been used by default since 2025.2"）。模式始终是"监听者放在 Linux 侧"。来源：https://youtrack.jetbrains.com/issue/IJPL-2208 、https://platform.jetbrains.com/t/native-mode-for-wsl-is-now-the-recommended-approach-what-does-it-mean-for-plugin-developers/5024
  - Obsidian：没有找到官方的一手说明，不下结论。同类 Electron 编辑器 milkup 在 PR 中记录了实测：`fs.watch` 在 `\\wsl.localhost` 上启动即报 `EISDIR`，改用 `fs.watchFile` 轮询后可靠（https://github.com/Auto-Plugin/milkup/pull/239 ，第三方，仅作旁证）。

### 3.2 不确定处（置信度：低）

- 在 `\\wsl.localhost` 上，`ReadDirectoryChangesW` 是**立即失败**，还是**成功后永不返回**？#4581 和 #7674 的描述不一致（`FindFirstChangeNotification` 报错，而 .NET 表现为挂起），可能与调用方式或 Windows 版本有关。
- 由 Windows 进程**经同一重定向器**写入的变更，重定向器是否会在本地回送通知？没有来源。

  这两点都列入实验 E4。无论结果如何，对方案都没有实质影响，因为 WSL 内修改一定收不到。

---

## 4. 编辑器原子保存的影响

### 4.1 各编辑器实际怎么写（置信度：高）

- **Vim**：
  - `'writebackup'` 在带 `+writebackup` 编译时默认开启，写入前先做备份。
  - `'backupcopy'` 在 Unix 上的 Vim 默认值是 `auto`：
    - `yes` 是复制出备份，再**截断并原地覆写**原文件，inode 不变；
    - `no` 是把原文件 **rename 成备份，再写一个新文件**，inode 改变；
    - `auto` 在"改名没有副作用"（非链接、属性能保留）时选 rename。

    也就是说，普通文件的默认行为通常是 rename 加新建。
  - 帮助文档原文点名这会影响 "several file-watcher daemons like inotify"。
  - 另外，`auto` 模式下 Vim 会在目标目录里创建并删除一个名为 `4913`（以及 `5036` 等，步长 123）的探测文件，监听目录的程序会看到这些 Create/Delete 事件。

  来源：https://vimhelp.org/options.txt.html#%27backupcopy%27 、https://vimhelp.org/options.txt.html#%27writebackup%27 、https://github.com/vim/vim/blob/master/src/bufwrite.c
- **VS Code**：
  - 普通用户文件是**原地写**：先用 `r+` 打开再 `ftruncate(fd, 0)`，失败时退回 `w`。inode 不变，但会出现"截断到 0 字节、再写入"的中间态。
  - 原子写（写 `<name>.vscode-tmp` 再 `rename` 覆盖）只用于 VS Code 自己的用户数据（settings、state 等）。维护者原话："atomic writes are enabled only for application internal data under vscode user data folder"。

  来源：https://github.com/microsoft/vscode/blob/main/src/vs/platform/files/node/diskFileSystemProvider.ts 、https://github.com/microsoft/vscode/issues/182974 、https://github.com/microsoft/vscode/issues/195539
- 其他编辑器（JetBrains 的 "safe write"、Typora、Obsidian 等）的写法没有逐一取证，应假设两种写法都会出现。

### 4.2 监听文件还是监听目录（置信度：高）

- inotify 是**基于 inode** 的："when monitoring a file… an event can be generated for activity on any link to the file"。如果被监听的文件被 rename 覆盖或删除，会先收到 `IN_DELETE_SELF` / `IN_MOVE_SELF`，然后是 `IN_IGNORED`，watch 自动失效，之后写到新 inode 上的内容不会再通知。来源：https://man7.org/linux/man-pages/man7/inotify.7.html
- fsnotify README："Watching individual files (rather than directories) is generally not recommended as many programs (especially editors) update files atomically… The watcher on the original file is now lost"，建议监听父目录再按文件名过滤。来源：https://github.com/fsnotify/fsnotify/blob/main/README.md
- chokidar 为此提供 `atomic` 选项（默认开启）："If a file is re-added within 100 ms of being deleted, Chokidar emits a `change` event rather than `unlink` then `add`"；另有 `awaitWriteFinish` 应对分块写入。来源：https://github.com/paulmillr/chokidar/blob/main/README.md
- 对本场景的含义：
  - **监听目录**：vim 的 rename 式保存会表现为 `IN_MOVED_FROM`/`IN_CREATE`/`IN_MODIFY`/`IN_CLOSE_WRITE`/`IN_MOVED_TO` 等事件序列。需要做**防抖加合并**，以"最终在路径上出现了新内容"为准。
  - **原地截断式写入**（VS Code、`backupcopy=yes`）：可能先读到 0 字节或半截内容。建议以 `IN_CLOSE_WRITE` 为主触发，或者防抖几十到上百毫秒后再读。
  - 监听单个文件在 rename 式保存后会失效，必须在收到 `IN_IGNORED` 后重新 add。所以直接监听目录更简单。
- 对 `/mnt/c` 和 `\\wsl.localhost`：原生通知本身就不可用，这些路径只能轮询，所以原子保存的影响只剩一个问题：轮询的判定依据要能识别换 inode。见第 5 节，建议比较 mtime + size（必要时加 inode）。

---

## 5. 轮询兜底的开销量级

### 5.1 ext4（置信度：定性高，定量中）

- 在一台 6.12 内核、ext4、2000 个小文件的云主机（不是 WSL）上实测：Python `os.stat` 约 **1.1 µs/次**，扫描 2000 个文件约 **2.3 ms**（dentry/inode 已缓存）。WSL2 的 ext4 同样是 VM 内的本地内核调用，量级应该相近，待实验 E5 确认。
- 推论：对上万个 Markdown 文件做 1 s 间隔的全量 stat 轮询，CPU 占用在 1% 以下的量级，完全可行，只是比 inotify 多出最多一个轮询周期的延迟。

### 5.2 跨边界 9p（`/mnt/c`，以及 Windows 侧读 `\\wsl.localhost`）（置信度：定性高，定量低）

- Microsoft 官方说明：
  - "Performance across OS file systems" 这一项，WSL1 打勾而 WSL2 不打勾；建议"store your project files on the same operating system as the tools you are running"。来源：https://learn.microsoft.com/en-us/windows/wsl/compare-versions
  - "For the fastest performance speed, store your files in the WSL file system if you are working in a Linux command line"。来源：https://learn.microsoft.com/en-us/windows/wsl/filesystems
- Microsoft 成员 SvenGroot 对原因的一手解释（#4197，2020-03）："every operation has to send data to the host, exit the VM, wait for the host to perform the operation…, send data back to the VM, trigger an interrupt…"；"to ensure the same behavior as WSL1, we don't use any caching"；"every 'stat' operation has to make a round-trip to the host (multiple, actually…)"。来源：https://github.com/microsoft/WSL/issues/4197#issuecomment-604592340
  - 含义：`cache=mmap` 下元数据**不缓存**，所以轮询**能正确看到** Windows 侧的修改（#4739 的复现也证实了 `fs.watchFile` 有效）。代价是每次 stat 都要多次跨 VM 往返。
  - 可以用 `cache=loose` 加速，但 SvenGroot 明确说那样 "all bets are off"，会看不到宿主侧的修改，不能用于监听。内核文档对 loose 模式也有同样警告：https://docs.kernel.org/filesystems/9p.html
- 用户侧数据（同一 issue，仅作量级参考）：
  - 小仓库的 `git status`：`/mnt` 上"nearly a minute"，WSL ext4 上"about a tenth of a second"；
  - 另一例是 `git.exe` 0.3 s，而 WSL 内 git 在 `/mnt` 上要 15 s。

  这些是 git 的整体耗时，不是单次 stat 的耗时。
- #4739 中也有用户反馈，`CHOKIDAR_USEPOLLING=true` 在大项目中导致"CPU usage will increase significantly (30% on my system)"。这取决于文件数量和间隔（chokidar 默认 `interval` 为 100 ms），只能作为数量级提示。来源：https://github.com/microsoft/WSL/issues/4739 、https://github.com/paulmillr/chokidar/blob/main/README.md
- 我没有找到 Microsoft 公布的单次 9p stat 延迟数字。**单次跨 9p stat 的绝对延迟列为待真机验证（实验 E5）**。推测为几十到几百微秒，比 ext4 慢一到两个数量级，这是低置信度的推断。

### 5.3 轮询实现要点（来自各库文档）

- chokidar：`usePolling` "typically necessary… to successfully watch files over a network"，默认间隔 100 ms（二进制文件 300 ms），可以用 `CHOKIDAR_USEPOLLING` / `CHOKIDAR_INTERVAL` 环境变量覆盖。
- watchdog：原生 API 不可用时使用 "OS Independent Polling"，做法是周期性比较目录快照。来源：https://python-watchdog.readthedocs.io/en/stable/installation.html
- fsnotify（Go）：**没有内置轮询**，README 的 Polling 一栏标注为 "Not yet"（#9）；NFS/SMB/FUSE 不工作的原因也写在 FAQ 中。需要自己实现轮询。来源：https://github.com/fsnotify/fsnotify/blob/main/README.md

---

## 6. 近年变化：WSL 2.x、mirrored、virtiofs

- **mirrored 网络模式**：`networkingMode` 只影响网络（NAT / mirrored / Consomme 等），与文件系统和变更通知无关。来源：https://learn.microsoft.com/en-us/windows/wsl/wsl-config ，置信度：高。
- **virtiofs**：
  - `.wslconfig` 的 `[wsl2] virtiofs` 是实验性开关，默认值为 `false`（"An experimental setting to use VirtioFS for Windows filesystem shares"）。来源：https://learn.microsoft.com/en-us/windows/wsl/wsl-config
  - WSL 2.7.1 增加了 virtiofs 目录挂载、`statx` 等支持，共享创建失败时回退到 Plan9。来源：https://github.com/microsoft/WSL/releases/tag/2.7.1 、https://github.com/microsoft/WSL/pull/14073
  - 2026-05 的 #40654 进一步改善了 virtiofs 的性能。来源：https://github.com/microsoft/WSL/pull/40654
  - WSL 的 release notes 和文档中**没有任何一处**声称 virtiofs 带来了宿主到 WSL 的 inotify。
  - 内核层面：主线 FUSE 的通知码只有 `POLL`、`INVAL_INODE`、`INVAL_ENTRY`、`STORE`、`RETRIEVE`、`DELETE`、`RESEND`、`INC_EPOCH`、`PRUNE`，没有 fsnotify 转发（`include/uapi/linux/fuse.h`）。2021 年的 "[RFC PATCH 0/7] Inotify support in FUSE and virtiofs" 没有合入主线。来源：https://github.com/torvalds/linux/blob/master/include/uapi/linux/fuse.h 、https://lkml.indiana.edu/hypermail/linux/kernel/2110.3/02106.html
  - 结论：virtiofs 改善的是吞吐和延迟，**预计不改变"Windows 侧修改收不到 inotify"的结论**。置信度：中，因为 WSL 内核可能带有私有补丁，需真机确认（实验 E6）。
- **`\\wsl.localhost` 方向**：plan9 服务器已开源，其协议中没有通知消息（见 3.1），#7674 仍然 open。置信度：高，截至 2026-09。
- **#4739 仍然 open**：最近一次有实质内容的复现是 2026-05，使用 Windows build 26200、WSL 内核 6.6.87.2。置信度：高。

---

## 7. 待真机验证实验（命令级）

前置信息采集（Windows PowerShell 和 WSL 各执行一次，结果附在实验记录开头）：

```powershell
wsl --version            # WSL / 内核 / WSLg / Windows 版本
Get-Content $env:USERPROFILE\.wslconfig -ErrorAction SilentlyContinue
```

```bash
uname -r; cat /etc/os-release | head -2
mount | grep -E ' /mnt/c | / ' ; stat -f -c '%T' ~ /mnt/c   # 期望 ext2/ext3 与 v9fs(或 fuseblk/virtiofs)
sudo apt-get install -y inotify-tools
```

### E1：ext4 上的 inotify 默认值与 ENOSPC 表现（对应第 1 节）

```bash
free -b | head -2
cat /proc/sys/fs/inotify/max_user_watches /proc/sys/fs/inotify/max_user_instances /proc/sys/fs/inotify/max_queued_events
grep -r inotify /etc/sysctl.conf /etc/sysctl.d /usr/lib/sysctl.d 2>/dev/null   # 是否被覆盖
# 人为触发 ENOSPC（结束后恢复原值）
OLD=$(cat /proc/sys/fs/inotify/max_user_watches)
mkdir -p /tmp/w/d{1..300}
sudo sysctl fs.inotify.max_user_watches=100
inotifywait -r -m /tmp/w ; echo "exit=$?"     # 期望提示 upper limit on inotify watches reached
sudo sysctl fs.inotify.max_user_watches=$OLD
```

预期：数值约等于"VM 内存 GiB × 8k"。人为调小上限后，加 watch 时报 ENOSPC。

### E2：ext4 目录，WSL 内修改与 Windows 经 `\\wsl.localhost` 修改（对应第 1 节）

```bash
mkdir -p ~/mdtest && echo a > ~/mdtest/a.md
inotifywait -m -e modify,close_write,create,delete,moved_from,moved_to,attrib ~/mdtest --timefmt '%T' --format '%T %e %f'
```

- E2-a（另开一个 WSL 终端）：`echo b >> ~/mdtest/a.md`，预期立即出现 `MODIFY` 和 `CLOSE_WRITE`。
- E2-b（Windows PowerShell，发行版名以 `wsl -l` 为准）：

  ```powershell
  Add-Content \\wsl.localhost\Ubuntu\home\<user>\mdtest\a.md 'from-windows'
  notepad \\wsl.localhost\Ubuntu\home\<user>\mdtest\a.md   # 手动改一行并保存
  ```

  预期：WSL 内能看到事件，从而验证 1.1 的"补充"结论。

### E3：`/mnt/c`（9p）两个方向（对应第 2 节）

```bash
W=/mnt/c/Users/<winuser>/mdtest; mkdir -p $W && echo a > $W/a.md
inotifywait -m $W --timefmt '%T' --format '%T %e %f'
```

- E3-a（Windows 侧写入）：执行 `powershell.exe -c "Add-Content C:\Users\<winuser>\mdtest\a.md 'win'"`，或者用记事本打开 `C:\Users\<winuser>\mdtest\a.md` 修改保存。预期：**无事件**。同时运行 `stat -c '%y %s' $W/a.md`，确认 mtime 和 size 已经变化，说明轮询可以检测到。
- E3-b（WSL 侧写入）：分别执行 `echo b >> $W/a.md` 和 `vim $W/a.md`（修改后 `:wq`）。预期：**有事件**。
- E3-c（elevated 与非 elevated 挂载）：在"以管理员身份运行"的终端里启动的 WSL 中执行 `echo c >> $W/a.md`，看普通终端里的 `inotifywait` 是否收到。结果未知。

### E4：Windows 侧监听 `\\wsl.localhost`（对应第 3 节）

在 PowerShell 中执行：

```powershell
$p = '\\wsl.localhost\Ubuntu\home\<user>\mdtest'
$w = New-Object IO.FileSystemWatcher $p; $w.IncludeSubdirectories = $true
Register-ObjectEvent $w Error   -Action { Write-Host "ERROR: $($EventArgs.GetException().Message)" } | Out-Null
Register-ObjectEvent $w Changed -Action { Write-Host "CHANGED: $($EventArgs.FullPath)" } | Out-Null
try { $w.EnableRaisingEvents = $true; 'armed' } catch { "arm failed: $_" }
# 另开 WSL：echo x >> ~/mdtest/a.md   → 观察 30 秒
# 再在另一个 PowerShell：Add-Content "$p\a.md" 'y'   → 观察是否回送本地通知
```

另可对照 Node：`node -e "require('fs').watch(String.raw\`\\\\wsl.localhost\\Ubuntu\\home\\<user>\\mdtest\`, (e,f)=>console.log(e,f))"`。预期结果是报 `EISDIR`。

记录三种结果之一：启用时直接报错、Error 事件触发、或者静默无事件。

### E5：轮询开销（对应第 5 节）

```bash
cat > /tmp/statbench.py <<'EOF'
import os, sys, time
d = sys.argv[1]; os.makedirs(d, exist_ok=True)
for i in range(2000): open(f'{d}/f{i}.md', 'w').write('x')
t = time.perf_counter()
for _ in range(10):
    for e in os.scandir(d): os.stat(e.path)
dt = time.perf_counter() - t
print(f'{d}: {dt/20000*1e6:.1f} us/stat, {dt/10*1e3:.1f} ms/scan(2000)')
EOF
python3 /tmp/statbench.py ~/statbench
python3 /tmp/statbench.py /mnt/c/Users/<winuser>/statbench
```

Windows 侧读 WSL 文件的开销：

```powershell
Measure-Command { 1..10 | % { Get-ChildItem \\wsl.localhost\Ubuntu\home\<user>\statbench | % { $_.LastWriteTimeUtc } } }
```

预期：ext4 约 1 µs/次；`/mnt/c` 和 `\\wsl.localhost` 慢一到两个数量级。记录实际倍数和轮询 1 次的总耗时。

### E6：virtiofs 是否改变结论（对应第 6 节）

1. 在 `%USERPROFILE%\.wslconfig` 中加入：

   ```ini
   [wsl2]
   virtiofs=true
   ```

   Learn 文档说还需要 `virtio` 与 `hostFileSystemAccess` 两项，按当前文档补齐。
2. 执行 `wsl --shutdown`，然后重新进入 WSL，运行 `mount | grep /mnt/c`，确认挂载类型是 `virtiofs`。
3. 重复 E3-a 和 E5。预期：E3-a 仍然无事件，E5 的耗时下降。

### E7：原子保存的事件序列（对应第 4 节）

```bash
cd ~/mdtest && echo a > b.md && stat -c '%i' b.md
inotifywait -m b.md . --format '%w %e %f' &
vim -c 'set backupcopy=no'  -c 'normal Ax' -c wq b.md; stat -c '%i' b.md   # 期望 inode 变、文件 watch 收到 DELETE_SELF/IGNORED、目录 watch 收到 4913 与 MOVED/CREATE
vim -c 'set backupcopy=yes' -c 'normal Ay' -c wq b.md; stat -c '%i' b.md   # 期望 inode 不变、MODIFY/CLOSE_WRITE
kill %1
```

如果可以，再用 VS Code（Remote-WSL 窗口）和计划支持的 Windows 编辑器（经 `\\wsl.localhost`）各保存一次，记录事件序列。

---

## 8. 来源清单

- Microsoft Learn：
  - [Working across file systems](https://learn.microsoft.com/en-us/windows/wsl/filesystems)
  - [Comparing WSL versions](https://learn.microsoft.com/en-us/windows/wsl/compare-versions)
  - [Advanced settings configuration (.wslconfig)](https://learn.microsoft.com/en-us/windows/wsl/wsl-config)
  - [ReadDirectoryChangesW](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-readdirectorychangesw)
- microsoft/WSL 的 issue 与 PR：
  - [#4739](https://github.com/microsoft/WSL/issues/4739)、[#4197](https://github.com/microsoft/WSL/issues/4197)（及其中 [SvenGroot 的说明](https://github.com/microsoft/WSL/issues/4197#issuecomment-604592340)）
  - [#7674](https://github.com/microsoft/WSL/issues/7674)、[#4581](https://github.com/microsoft/WSL/issues/4581)、[#5424](https://github.com/microsoft/WSL/issues/5424)、[#216](https://github.com/microsoft/WSL/issues/216)
  - [Release 2.7.1](https://github.com/microsoft/WSL/releases/tag/2.7.1)、[PR #14073](https://github.com/microsoft/WSL/pull/14073)、[PR #40654](https://github.com/microsoft/WSL/pull/40654)
- microsoft/WSL 的源码与技术文档：
  - [plan9.md](https://github.com/microsoft/WSL/blob/master/doc/docs/technical-documentation/plan9.md)、[drvfs.md](https://github.com/microsoft/WSL/blob/master/doc/docs/technical-documentation/drvfs.md)
  - [src/linux/plan9/p9defs.h](https://github.com/microsoft/WSL/blob/master/src/linux/plan9/p9defs.h)、[src/linux/init/drvfs.cpp](https://github.com/microsoft/WSL/blob/master/src/linux/init/drvfs.cpp)
- Linux 内核与 man-pages：
  - [inotify(7)](https://man7.org/linux/man-pages/man7/inotify.7.html)、[inotify_add_watch(2)](https://man7.org/linux/man-pages/man2/inotify_add_watch.2.html)
  - [commit 92890123749b](https://github.com/torvalds/linux/commit/92890123749bafc317bbfacbe0a62ce08d78efb7)、[v5.11 inotify_user.c](https://github.com/torvalds/linux/blob/v5.11/fs/notify/inotify/inotify_user.c)
  - [9p 文档](https://docs.kernel.org/filesystems/9p.html)、[fs/read_write.c](https://github.com/torvalds/linux/blob/master/fs/read_write.c)、[fs/namei.c](https://github.com/torvalds/linux/blob/master/fs/namei.c)、[uapi fuse.h](https://github.com/torvalds/linux/blob/master/include/uapi/linux/fuse.h)
  - [RFC: Inotify support in FUSE and virtiofs](https://lkml.indiana.edu/hypermail/linux/kernel/2110.3/02106.html)
- 各监听库：
  - [fsnotify README](https://github.com/fsnotify/fsnotify/blob/main/README.md)
  - [chokidar README](https://github.com/paulmillr/chokidar/blob/main/README.md)
  - [watchdog 平台说明](https://python-watchdog.readthedocs.io/en/stable/installation.html)
  - [libuv win/error.c](https://github.com/libuv/libuv/blob/v1.x/src/win/error.c)
  - [nodejs/node#37960](https://github.com/nodejs/node/issues/37960)
- 编辑器与 IDE：
  - [Vim 'backupcopy' / 'writebackup'](https://vimhelp.org/options.txt.html#%27backupcopy%27)、[vim bufwrite.c](https://github.com/vim/vim/blob/master/src/bufwrite.c)
  - [VS Code diskFileSystemProvider.ts](https://github.com/microsoft/vscode/blob/main/src/vs/platform/files/node/diskFileSystemProvider.ts)、[vscode#182974](https://github.com/microsoft/vscode/issues/182974)、[vscode#195539](https://github.com/microsoft/vscode/issues/195539)、[vscode#136894](https://github.com/microsoft/vscode/issues/136894)、[vscode#152537](https://github.com/microsoft/vscode/issues/152537)
  - [VS Code WSL 文档](https://github.com/microsoft/vscode-docs/blob/main/docs/remote/wsl.md)、[VS Code Linux 文档](https://github.com/microsoft/vscode-docs/blob/main/docs/setup/linux.md)
  - [JetBrains IJPL-2208](https://youtrack.jetbrains.com/issue/IJPL-2208)、[JetBrains Native Mode for WSL](https://platform.jetbrains.com/t/native-mode-for-wsl-is-now-the-recommended-approach-what-does-it-mean-for-plugin-developers/5024)
- 第三方旁证（非一手来源，只作佐证）：[zed#51340](https://github.com/zed-industries/zed/issues/51340)、[milkup PR #239](https://github.com/Auto-Plugin/milkup/pull/239)
