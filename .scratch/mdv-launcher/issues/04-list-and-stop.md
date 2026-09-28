# 04: 列出和手动停止预览

**What to build:** 用户用 `mdv list` 查看正在运行的预览；用 `mdv stop` 停止当前目录的预览，用 `mdv stop <目录>` 停止指定目录的预览，用 `mdv stop --all` 停止全部预览。`stop` 返回时实例已经真正退出，紧接着再运行 `mdv` 能拿回原来的端口。

**Blocked by:** 02

**Status:** ready-for-agent

- [ ] `mdv list` 每行输出一个 `URL<TAB>目录`；没有预览时输出一句提示，退出码为 0
- [ ] `mdv list` 不列出已经失效的实例，并清除它们的记录
- [ ] `mdv stop` / `mdv stop <目录>` 打印 `Stopped <目录>`；返回时该进程已不存在
- [ ] 停止后立刻在同一目录运行 `mdv`，得到与之前相同的端口
- [ ] 对没有预览的目录执行 `mdv stop`：stderr 输出以 `mdv:` 开头的信息，退出码为 1
- [ ] `mdv stop --all` 停止全部预览；没有预览时静默成功
