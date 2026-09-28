# 01: 一条命令打开当前目录的预览页（含自动化测试骨架）

**What to build:** 用户在 ext4 上的某个目录里运行 `mdv`，就能拿到一个预览页：终端打印 `Preview: http://127.0.0.1:8000/` 后立即返回提示符，Windows 浏览器被要求打开这个地址，该地址上的 Vantage 以这个目录为笔记根目录提供服务。

这是第一颗曳光弹，同时搭好 spec 定下的唯一测试接缝：一个纯 bash 的测试脚本，放在 `mdv` 旁边，一条命令就能运行，只依赖 tmux、curl 和 python3 标准库。脚本要能做到：

- 把 `HOME` 和 `XDG_RUNTIME_DIR` 隔离到临时目录；
- 通过 `MDV_VANTAGE` 注入真实的 Vantage v0.7.1；
- 在 PATH 里放一个假的 `cmd.exe`，把收到的参数和工作目录记进文件；
- 在 tmux 会话里以交互式 shell 运行 `mdv`。

后续各票都在这个脚本里追加用例。仓库里已有一版 `mdv` 实现：先让测试跑起来，再按测试结果修正实现。

**Blocked by:** None (can start immediately)

**Status:** ready-for-agent

- [ ] 在临时目录里运行 `mdv`，退出码为 0，stdout 打印 `Preview: http://127.0.0.1:<端口>/`，提示符立即返回（交互式 shell 可以马上执行下一条命令）
- [ ] 该 URL 上 `/api/content` 能读到目录里的 md 文件；`/api/tree` 列出了子目录
- [ ] 修改笔记根目录下（含子目录）的文件后，约 1 秒内通过 `/api/ws` 收到带该路径的 `files_changed`
- [ ] 假 `cmd.exe` 恰好被调用一次，参数依次是 `/c`、`start`、空字符串、URL
- [ ] `mdv <目录>` 预览指定目录，效果与先 `cd` 再运行 `mdv` 相同
- [ ] 服务只绑 `127.0.0.1`
- [ ] 测试脚本结束时清理自己启动的所有 Vantage 进程和临时目录，重复运行结果一致
