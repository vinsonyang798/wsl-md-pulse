Type: research
Status: open
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
