# 05: 打开浏览器的降级链

**What to build:** `mdv` 尽力打开 Windows 浏览器，失败了也不影响预览本身。降级顺序如下：

1. 用 `cmd.exe` 打开，在 Windows 路径下执行，避开 UNC 当前目录的警告；
2. 失败则改用 `powershell.exe Start-Process`；
3. 仍然失败就只打印 URL，并提示用户手动打开，退出码仍为 0。

设置 `MDV_NO_BROWSER` 时跳过打开浏览器。PATH 里找不到这两个程序时，按 Windows 默认安装位置的绝对路径去找。

**Blocked by:** 01

**Status:** ready-for-agent

- [ ] 假 `cmd.exe` 返回失败时，假 `powershell.exe` 被调用，参数是 `-NoProfile -NonInteractive -Command "Start-Process '<url>'"`
- [ ] 两者都不存在或都失败时，stdout 仍有 `Preview: <url>`，stderr 提示手动打开，退出码为 0，预览可用
- [ ] 设置 `MDV_NO_BROWSER=1` 时，两个假程序都没有被调用
- [ ] `cmd.exe` 执行时的工作目录是 `/mnt/c`（该目录存在时）
- [ ] PATH 里没有 `cmd.exe`、但 Windows 默认绝对路径上有时，仍能调用到它（测试可以只覆盖逻辑，不要求真的存在 `/mnt/c`）
