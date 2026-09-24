Type: research
Status: resolved
Blocked by:

# Windows 侧访问 WSL 内服务与画面通道

## Question

如果渲染在 WSL 内完成，画面能否稳定地到达 Windows？需要有来源的事实：

1. WSL2 默认 NAT 模式下的 localhost 转发：WSL 内监听 `127.0.0.1` / `0.0.0.0` 时 Windows 浏览器能否用 `localhost:<port>` 访问？`localhostForwarding` 配置、已知失效场景（VPN、休眠唤醒、端口冲突、IPv6 `::1`）。
2. `networkingMode=mirrored`（Windows 11 22H2+）下的行为差异、Hyper-V 防火墙影响。
3. WebSocket / Server-Sent Events 经过转发是否有已知问题（长连接断开、代理）。
4. 从 WSL 打开 Windows 浏览器的方式：`wslview`（wslu）、`cmd.exe /c start`、`explorer.exe`；WSL interop 被禁用时的表现。
5. 反方向的替代：Windows 侧程序直接读 `\\wsl.localhost` 文件自己渲染，是否可行、性能如何；WSLg 在 WSL 内开 GUI 窗口是否是可接受的备选。

每条结论标注来源（Microsoft Learn、microsoft/WSL issue、wslu 文档）和适用的 Windows/WSL 版本。

## Answer

**"在 WSL 内渲染 + Windows 浏览器经 localhost 访问"能走通，但要满足几条约束才稳定：显式绑定 IPv4 回环、客户端必须能自动重连、打开浏览器不依赖 wslview、要考虑 WSL 空闲自动停机。** 详细来源、版本适用范围，以及 E1–E10 真机实验命令见 [研究笔记](../research/04-windows-to-wsl-display-channel.md)。

- **NAT 模式（默认）（高）。** WSL 内绑 `127.0.0.1` 或 `0.0.0.0`，Windows 都能用 `localhost:<port>` 访问（由 `wslrelay.exe` 转发）。但如果绑双栈 `::`，relay 只在 `[::1]` 上监听，`127.0.0.1` 连不上（已确认未修，#4851、#41196）。所以应显式绑 `127.0.0.1`，给用户的 URL 也写 `127.0.0.1`。
- **静默失效场景（高）。** 端口冲突时 relay 不报错（#6953）；休眠唤醒后可能失去响应（#8696）；NAT relay 在双向大流量下会死锁（#10688、#41680，修复尚未合入）。应对：推送通道只发小通知，正文走单独的 HTTP GET，客户端自动重连。
- **mirrored 模式不能当前提（高/中）。** 需要 Win11 22H2+ 与 WSL 2.0+，只支持 IPv4 回环；可能静默回退成 NAT，部分机器上端口会被改写（#41137）。Hyper-V 防火墙默认放行本机回环，所以本机浏览器不受影响。
- **打开浏览器（高）。** wslu 仓库已归档，当前 Ubuntu 的 WSL 镜像里既没有 wslu 也没有 xdg-utils。可用的降级顺序：用绝对路径调用 `cmd.exe /c start "" <url>`，再试 `powershell.exe Start-Process`，最后打印 URL。interop 被禁用时所有 `.exe` 都起不来，因此必须兜底打印 URL。
- **反向方案只适合当备选（高/中）。** Windows 程序可以读 `\\wsl.localhost`（访问时会自动拉起 VM），但收不到变更通知、只能轮询，而且跨边界读写慢。WSLg 下开 Linux 浏览器，默认镜像缺中文字体，HiDPI 缩放也有未关闭的 issue。
- **影响常驻服务（中）。** 关闭所有 WSL 终端后实例会自动停止，后台服务也跟着停（#9968）。可设置 `instanceIdleTimeout=-1`（需要 WSL 2.5.4+）。
