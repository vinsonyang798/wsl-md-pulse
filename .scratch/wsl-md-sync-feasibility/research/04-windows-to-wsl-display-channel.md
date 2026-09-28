# 研究：画面怎么从 WSL 到 Windows（localhost 转发、打开浏览器、反向方案）

对应票据：`issues/04-windows-to-wsl-display-channel.md`
调研日期：2026-09-24。按要求从零推导，没有参考仓库里已有的设计文档。

来源只用一手资料：Microsoft Learn（WSL、Windows 防火墙、cmd 命令参考）、microsoft/WSL 的 issue / PR / release notes，以及已经开源的 WSL 源码（`src/linux/init`）、Microsoft Command Line 博客、wslu 仓库源码与 README、Ubuntu 官方包索引和 WSL 镜像 manifest、microsoft/wslg README。每条结论都附来源 URL 和置信度（高 / 中 / 低）。置信度不是"高"的项，在第 6 节给出命令级的真机实验。

写作时的版本快照（来自 GitHub Releases API）：WSL 稳定版 **2.7.14**（2026-09-11），预发布版 **2.9.12**（2026-09-14）。来源：https://github.com/microsoft/WSL/releases

## 0. 结论速览

| 问题 | 结论 | 置信度 | 适用版本 |
| --- | --- | --- | --- |
| NAT 模式下，WSL 监听 `127.0.0.1` 或 `0.0.0.0`，Windows 浏览器能否用 `localhost:<port>` 访问 | **能**。`localhostForwarding` 默认为 true，由 Windows 侧进程 `wslrelay.exe` 在 Windows 回环地址上代理监听 | 高 | Win10 19041+（`.wslconfig` 可用）/ Win11；WSL2 |
| NAT 模式下，WSL 只监听 `::`（双栈）或 `::1` | **有坑**：relay 只在 Windows 的 `[::1]` 上建监听，`127.0.0.1` 连不上；浏览器能否访问 `localhost` 取决于它先解析到哪个地址。上游确认是已知 bug（#4851，未修） | 高 | 截至 WSL 2.7.x 仍存在 |
| NAT 模式已知的失效场景 | 端口被 Windows 保留或占用时**静默失败**；Fast Startup / 休眠唤醒后 relay 或整个 WSL 失去响应；双向同时大流量时 relay 死锁（#10688 / #41680，修复 PR #41458 尚未合入） | 高（现象）/ 中（触发条件） | 各版本；死锁在 2.7.14 上仍能复现 |
| `networkingMode=mirrored` | 仅 Win11 22H2+，WSL 2.0.0+。Windows 与 WSL 直接用 `127.0.0.1` 互通，`localhostForwarding` 被忽略；**只支持 IPv4 回环**，`::1` 不通。Hyper-V 防火墙默认阻止入站，但 `LoopbackEnabled` 放行本机回环 | 高 | Win11 22H2+ |
| mirrored 的风险 | 可能**静默回退到 NAT**；部分机器上 host→WSL 回环被改写成错误的目标端口（#41137，2026 年仍 open） | 中 | WSL 2.5–2.9 均有报告 |
| WebSocket / SSE 经过转发 | 常规使用可行（VS Code Remote-WSL 本身就是 WebSocket over localhost）。风险有三：NAT relay 在双向大流量下死锁；休眠唤醒后连接失效；mirrored 回环 bug。没有找到 SSE 专属的问题 | 中 | — |
| 从 WSL 打开 Windows 浏览器 | `cmd.exe /c start "" "<url>"` 或 `powershell.exe Start-Process` 依赖 interop，最可靠。**wslu（wslview）已归档**，当前 Ubuntu WSL 镜像**既不带 wslu 也不带 xdg-utils** | 高 | — |
| interop 被禁用 / `appendWindowsPath=false` | 前者：所有 `.exe` 都无法启动，只能打印 URL。后者：用绝对路径 `/mnt/c/Windows/System32/cmd.exe` 仍然可用 | 高（文档）/ 中（具体报错形态） | — |
| 反向：Windows 程序直接读 `\\wsl.localhost` | 读文件可行，访问时会**自动拉起** WSL2 VM。但 `ReadDirectoryChangesW` 不支持（#7674），只能轮询；跨系统 I/O 慢，偶发卡顿 | 高（功能）/ 中（性能） | Win10 1903+（`\\wsl$`） |
| 反向：WSLg 在 WSL 内开 GUI 窗口 | 可行但只适合当备选：Win10 19044+ / Win11；镜像里没有 CJK 字体，中文会显示成方框；HiDPI 缩放和休眠后缩放丢失都有未关闭 issue | 中 | Win10 19044+ / Win11 |

**对路线选择的直接含义（推论，不是某个来源的原话）**：如果渲染放在 WSL 内，服务**显式绑定 IPv4 `127.0.0.1`**，给用户的 URL 用 `http://127.0.0.1:<port>`（不要用 `localhost`，也不要绑 `::`）。这样在 NAT 和 mirrored 两种模式下都走被验证最多的 IPv4 回环路径，也不会暴露到局域网。前端必须自带断线重连（休眠唤醒、relay 卡死都会发生），推送尽量保持"服务端→浏览器"的单向小消息，避开 relay 的双向死锁条件。打开浏览器按 `cmd.exe`（绝对路径）→ `powershell.exe`（绝对路径）→ 打印 URL 的顺序降级，不能依赖 wslview 或 xdg-open。

---

## 1. 默认 NAT 模式下的 localhost 转发

### 1.1 基本行为：`127.0.0.1` 和 `0.0.0.0` 都能用 `localhost:<port>` 访问（高）

- Learn 官方文档说明，在默认 NAT 模式下，Linux 里的网络应用可以从 Windows 应用（Edge / Chrome）"using `localhost` (just like you normally would)"访问。来源：https://learn.microsoft.com/en-us/windows/wsl/networking#accessing-linux-networking-apps-from-windows-localhost
- `.wslconfig` 的 `[wsl2]` 节中，`localhostForwarding` 默认为 `true`，含义是："ports bound to wildcard or localhost in the WSL 2 VM should be connectable from the host via `localhost:port`"。也就是说绑通配地址（`0.0.0.0`）和绑回环地址（`127.0.0.1`）都会转发。`.wslconfig` 要求 Windows Build 19041 及以上。来源：https://learn.microsoft.com/en-us/windows/wsl/wsl-config#main-wsl-settings
- 实现方式：Windows 侧的 `wslrelay.exe` 为每个 WSL 监听端口在 Windows 的 `127.0.0.1` 上建立监听，再经过 VSOCK 转进 VM。#41680 的实测输出：`127.0.0.1:45999 -> 0.0.0.0:0 Listen wslrelay`，命令行为 `wslrelay.exe --mode 1`，"it holds a `127.0.0.1` listener for every WSL listening port"。`wslrelay.exe` 从 1.1.6 起引入（"Introduce wslrelay.exe which replaces wslhost.exe"）。来源：https://github.com/microsoft/WSL/issues/41680 、https://github.com/microsoft/WSL/releases/tag/1.1.6
- 绑 `127.0.0.1` 和绑 `0.0.0.0` 的区别：两者都能从 Windows 用 localhost 访问，但只有 `0.0.0.0` 能通过 VM 的虚拟 IP（`wsl hostname -I`）访问。#8905 的实测表：`--bind 127.0.0.1` 时 `<wsl_ip>:port` 不通、`localhost:port` 可通。来源：https://github.com/microsoft/WSL/issues/8905 。Learn 同时提醒，用远程 IP 连接时会被当作 LAN 连接，需要绑 `0.0.0.0`，并注意安全。来源：https://learn.microsoft.com/en-us/windows/wsl/networking#connecting-via-remote-ip-addresses
- NAT 模式下，WSL2 默认**不能**被局域网访问，需要 `netsh interface portproxy` 手动转发。所以即便绑了 `0.0.0.0`，在 NAT 模式下也不会直接暴露到 LAN。来源：https://learn.microsoft.com/en-us/windows/wsl/networking#accessing-a-wsl-2-distribution-from-your-local-area-network-lan

### 1.2 IPv6 / `::1` / "localhost 解析到 `::1`"（高）

有两个互相独立的问题。

1. **WSL 服务只监听 IPv6（`::` 双栈或 `::1`）时，relay 只在 Windows 的 `[::1]` 上监听，不建 `127.0.0.1`**
   - #4851 "Localhost relay does not support dual-mode sockets"（open，标签 bug/feature/network）：`nc :: 8080 -l` 之后，Windows 访问 `127.0.0.1:8080` 失败，访问 `localhost:8080` 却可以，因为浏览器把 `localhost` 解析成了 `::1`。2024-01-31 微软成员回复："We are able to reproduce it and know the source of the issue. It's just a question of priorities." 来源：https://github.com/microsoft/WSL/issues/4851
   - #41196（2026-07，WSL 2.7.10，Win11 26200）：k3s 只有 `*:6443` 的 IPv6 监听，Windows 上 `Get-NetTCPConnection` 只能看到 `::1 6443 Listen`，`Test-NetConnection 127.0.0.1 -Port 6443` 失败。微软成员 shuaiyuanxx 确认："This matches #4851 … WSL creates `::1:6443` but not `127.0.0.1:6443`"，建议的规避方法是显式监听 IPv4。来源：https://github.com/microsoft/WSL/issues/41196
   - #14154（open，2026-02；2026-09 在 WSL 2.7.12 上再次复现）：在 WSL 内部，对 `::` 双栈 socket 发起的 IPv4 连接也会被拒绝。Go 的 `http.ListenAndServe(":8000")`、Next.js 默认的 `::` 绑定都会中招。评论者给的规避方法是显式绑 IPv4。来源：https://github.com/microsoft/WSL/issues/14154
   - **对设计的影响**：Go 的 `":port"`、Node 的默认 host 往往是双栈 `::`，必须改成显式的 `127.0.0.1:port`。
2. **WSL 服务只监听 IPv4，而 Windows 客户端把 `localhost` 解析成 `::1` 并且只尝试 `::1`**
   - #5298 的评论（2020）：WSL 的 `/etc/hosts` 把 localhost 映射到 127.0.0.1，而 Windows 19041 上 `localhost` 解析为 `::1`，导致服务端听 127.0.0.1、浏览器却去连 ::1。来源：https://github.com/microsoft/WSL/issues/5298
   - #4851 中 therealkenc（社区维护者）指出，不同浏览器对 `localhost` 的解析偏好不同，"The client (a browser or otherwise) matters"。2026-03 的评论补充了另一种现象：Docker 转发端口上，`wslrelay.exe` 在 `[::1]` 接受了 TCP 握手，随后又立即重置连接。这让 Happy Eyeballs 不会回退到 IPv4，规避方法是"Use `127.0.0.1` instead of `localhost`"。来源：https://github.com/microsoft/WSL/issues/4851
   - 结论：**给用户的 URL 用 `127.0.0.1`，比用 `localhost` 更确定**。现代浏览器在"只绑 IPv4"时访问 `localhost` 实际能否成功，没有找到一手的权威说明，列入真机验证（实验 E1）。
- 另外，2.0.0 修复了"localhost relay failing if ipv6 is disabled"。如果 Windows 用注册表禁用了 IPv6，Learn 提示 WSL 网络可能失效。来源：https://github.com/microsoft/WSL/releases/tag/2.0.0 、https://learn.microsoft.com/en-us/windows/wsl/troubleshooting#wsl-has-no-network-connection-when-disabling-ipv6

### 1.3 端口冲突：静默失败（高）

- #6953：端口落在 Windows `winnat` 自动保留的动态端口范围里（用 `netsh int ip show excludedportrange protocol=tcp` 查看）时，Windows 访问不到 WSL 服务，"it silently ignored the port conflict"。规避方法是重启 winnat，再把这个端口加入持久排除。来源：https://github.com/microsoft/WSL/issues/6953
- release notes 1.1.0："Make the localhost relay ignore conflicting binds"；1.3.10："Change localhost relay creation to be non-fatal"。也就是说，如果 Windows 上已经有进程占了同一个 `127.0.0.1:<port>`，relay 不会报错，WSL 内的服务照常启动，但 Windows 访问到的是另一个进程。来源：https://github.com/microsoft/WSL/releases/tag/1.1.0 、https://github.com/microsoft/WSL/releases/tag/1.3.10
- **对设计的影响**：WSL 内的服务启动成功，不代表 Windows 能访问到它。启动后应该从 Windows 侧自检一次（例如由浏览器端的页面回报握手令牌），或者至少在文档里提示用户换端口。自检方法本身待验证（实验 E2）。

### 1.4 休眠 / 唤醒 / Fast Startup（现象：高；当前版本的触发率：中）

- #5298（2020，Win10 19041）：冷启动后（Fast Startup 实际是混合休眠），localhost 转发失效，普通重启则正常。规避方法是关闭 Fast Startup 或执行 `wsl --shutdown`。微软打了 fixinbound 标签，"conservatively /fixed 20180"。来源：https://github.com/microsoft/WSL/issues/5298 、https://github.com/microsoft/WSL/issues/5317
- #8696 "WSL is non-responsive after waking from hibernate"（2022 年开，**截至 2026-08 仍 open**，500+ 评论）：唤醒后终端卡住，`wsl --shutdown` 也卡住。2026-04-28 微软成员 chemwolf6922 表示 2.7.3 预发布版里有"a partial fix"。2026-08 还有评论指出，Windows 新的自适应休眠策略会让这类问题出现得更频繁。该 issue 还关联了 #41286（"Relay processes stick in accept … after Modern Standby resume"，这里只读了标题）。来源：https://github.com/microsoft/WSL/issues/8696
- #41481（2026-08，WSL 2.6.3，默认 NAT）：localhost 转发在运行中途失效，访问 WSL 虚拟 IP 却正常，触发条件未知。报告者认为这是 #5317 在新版本上的复发。该 issue 因作者没有继续提供信息而被自动关闭。来源：https://github.com/microsoft/WSL/issues/41481
- **对设计的影响**：必须能自动重连，并在界面上明确提示"连接断开"。如果 localhost 持续不通，提示用户先执行 `wsl --shutdown` 再重试。当前版本上休眠唤醒的实际表现待测（实验 E3）。

### 1.5 VPN（中）

- #8905 的标题是"Can't access ports via `localhost` when using VPN"，但复现步骤实际说明的是：`docsify` 只监听 `tcp6 :::3000` 时 `localhost` 不通，改成 Python 的 `0.0.0.0` 或 `127.0.0.1` 后就通了。这更像 1.2 节的 IPv6 问题，不是 VPN 本身的问题。该 issue 因不活跃被自动关闭。来源：https://github.com/microsoft/WSL/issues/8905
- Learn 故障排查页中的 VPN 条目主要讲的是 **WSL 出站**（DNS、Cisco AnyConnect 改路由导致 NAT 失效），没有提到 Windows→WSL 的 localhost 转发。来源：https://learn.microsoft.com/en-us/windows/wsl/troubleshooting#wsl-has-no-network-connectivity-once-connected-to-a-vpn
- #41680 的报告者在连着分流 VPN 时，mirrored 被**静默回退成了 NAT**（见 2.4 节）。
- 结论：**没有找到**"VPN 直接导致 Windows→WSL localhost 转发失效"的一手证据。VPN 更可能通过改变网络模式、路由或防火墙策略间接产生影响。列入真机验证（实验 E1 在 VPN 连接状态下再跑一遍）。

### 1.6 NAT 失败时的回退：Consomme（原名 VirtioProxy）（中）

- 从 WSL 2.3.25 起，"if NAT network mode fails, it falls back to using Consomme network mode"。2.9.3 把 VirtioProxy 更名为 Consomme。来源：https://learn.microsoft.com/en-us/windows/wsl/wsl-config#main-wsl-settings 、https://github.com/microsoft/WSL/releases/tag/2.3.25 、https://github.com/microsoft/WSL/releases/tag/2.9.3
- 这个模式下的 localhost relay 也有自己的 IPv6 问题（#40900 "support ipv6 localhost relay in Consomme networking mode"，已关闭；#40598，已关闭；这里只读了标题）。#14154 的评论者就是在 virtioproxy 模式下复现的。
- **对设计的影响**：诊断信息里应该输出 `wslinfo --networking-mode` 的结果。#41680 正是靠这条命令，才发现 mirrored 实际上没有生效。

---

## 2. `networkingMode=mirrored`

### 2.1 版本要求（高）

- Learn："On machines running Windows 11 22H2 and higher you can set `networkingMode=mirrored` under `[wsl2]`"。`.wslconfig` 表中 `networkingMode`、`firewall`、`dnsTunneling` 都标注了"Require Windows 11 version 22H2 or higher"。**Windows 10 不可用。** 来源：https://learn.microsoft.com/en-us/windows/wsl/networking#mirrored-mode-networking 、https://learn.microsoft.com/en-us/windows/wsl/wsl-config
- WSL 版本：2.0.0（2023-09-18，预发布）首次以 `experimental.networkingMode` 的形式引入；2.0.5 把它迁移为 `wsl2.networkingMode`。来源：https://github.com/microsoft/WSL/releases/tag/2.0.0 、https://github.com/microsoft/WSL/releases/tag/2.0.5 、https://devblogs.microsoft.com/commandline/windows-subsystem-for-linux-september-2023-update/

### 2.2 与 NAT 的行为差异；`127.0.0.1` 在 mirrored 下的含义（高）

- Learn："When the WSL2 is running with the new mirrored mode, the Windows host and WSL2 VM can connect to each other using `localhost` (127.0.0.1)"。mirrored 模式的收益包括 IPv6、VPN 兼容性、组播、LAN 直连。同一页也写明"IPv6 localhost address `::1` is not supported"。来源：https://learn.microsoft.com/en-us/windows/wsl/networking
- `localhostForwarding` 在 mirrored 下**被忽略**（release 2.1.1 "Ignore localhostForwarding setting in mirrored mode"；Learn 示例注释 "Setting is ignored when networkingMode=mirrored"）。来源：https://github.com/microsoft/WSL/releases/tag/2.1.1 、https://learn.microsoft.com/en-us/windows/wsl/wsl-config#example-wslconfig-file
- #10803（open）的实测表：mirrored 下，WSL 监听 `::`（双栈）时，Windows 通过 `127.0.0.1` 和 `localhost` 的 IPv4 路径**可以**访问；通过 `[::1]` 和本机 IPv6 地址**不行**。微软成员 CatalinFetoiu 的说法："mirrored mode currently supports loopback communication only using IPv4"。`hostAddressLoopback`（让 Windows 通过本机分配的 IP 访问 WSL）只支持 IPv4，默认关闭。来源：https://github.com/microsoft/WSL/issues/10803 、https://learn.microsoft.com/en-us/windows/wsl/wsl-config#experimental-settings
- **端口空间与 Windows 共享**：`ignoredPorts` 的说明是"Specifies which ports Linux applications can bind to, even if that port is used in Windows"。反过来说，默认情况下 Windows 已占用的端口，Linux 侧不能再绑定。这和 NAT 下的"静默冲突"不同，冲突会直接体现为 bind 失败（推论，待验证，实验 E5）。来源：https://learn.microsoft.com/en-us/windows/wsl/wsl-config#experimental-settings
- 在 mirrored 下，Windows 主机收到的部分入站端口永远不会转给 VM（UDP 68、TCP 135/1900/2869/5004/3702/5357/5358）。选端口时应避开。来源：https://learn.microsoft.com/en-us/windows/wsl/troubleshooting#issues-with-steering-the-inbound-traffic-received-by-the-windows-host-to-the-wsl-virtual-machine

### 2.3 Hyper-V 防火墙对入站的影响（高）

- Learn："On machines running Windows 11 22H2 and higher, with WSL 2.0.9 and higher, the Hyper-V firewall feature will be turned on by default"；`.wslconfig` 中 `firewall` 默认为 `true`。来源：https://learn.microsoft.com/en-us/windows/wsl/networking#wsl-and-firewall 、https://learn.microsoft.com/en-us/windows/wsl/wsl-config
- Hyper-V 防火墙文档：WSL 的 VMCreatorId 是 `{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}`。`LoopbackEnabled` 的含义是"loopback traffic between the host and the container is allowed, without requiring any Hyper-V Firewall rules. **WSL enables it by default**"。来源：https://learn.microsoft.com/en-us/windows/security/operating-system-security/network-security/windows-firewall/hyper-v-firewall
- 默认入站动作是 Block：#41137 中报告者贴出的 ActiveStore 值为 `Enabled True / DefaultInboundAction Block / LoopbackEnabled True`，而且和另一台正常工作的机器完全相同。Learn 给出的放行 LAN 入站的方法是 `Set-NetFirewallHyperVVMSetting … -DefaultInboundAction Allow` 或 `New-NetFirewallHyperVRule`。来源：https://github.com/microsoft/WSL/issues/41137 、https://learn.microsoft.com/en-us/windows/wsl/networking#mirrored-mode-networking
- 结论：**本机 Windows 浏览器 → WSL 的 `127.0.0.1` 不受 Hyper-V 防火墙影响**（走回环豁免）。LAN 入站默认被阻止。对"只在本机预览"的场景来说，这正好是想要的默认行为。企业环境如果通过 GPO / CSP 设置了 `AllowLocalFirewallRules=False`，可能连 WSL 的 DNS 都会被挡（故障排查页有详细说明），回环是否也会受影响没有找到说明，列入实验 E5。来源：https://learn.microsoft.com/en-us/windows/wsl/troubleshooting

### 2.4 mirrored 的已知问题（中）

- **静默回退到 NAT**：在 #41680 中，报告者 `.wslconfig` 里写的是 mirrored，`wslinfo --networking-mode` 却返回 `nat`（当时连着分流 VPN）。release 2.2.2 改进过"mirrored networking cannot be enabled"时的警告信息。来源：https://github.com/microsoft/WSL/issues/41680 、https://github.com/microsoft/WSL/releases/tag/2.2.2
- **host→WSL 回环的目标端口被改写**：#41137（open，bug，WSL 2.7.8 / 2.9.4，Win11 26200）。Windows `curl 127.0.0.1:8765` 超时，guest 内抓包看到 SYN 的目标端口变成了随机值。多名用户复现，其中一人在 VS Code 上看到"WebSocket close with status code 1006"。社区的抓包分析怀疑是校验和卸载的偏移量错位了 14 字节（报告者自己说明"packet-supported hypothesis rather than a confirmed root cause"）。临时规避方法是保持 Npcap 的 loopback 抓包进程一直运行。来源：https://github.com/microsoft/WSL/issues/41137
- 其他 mirrored + localhost 的 issue（这里只读了标题）：#11172（2024，mirrored 下 Windows 访问 localhost 不通，已关闭）、#41102、#40965（Windows→WSL 回环吞吐量明显低于反方向）、#40169（mirrored 锁定大段 localhost 端口，报 WinError 10013）、#10844（访问 localhost 等待 2 分钟）。检索入口：https://github.com/microsoft/WSL/issues?q=mirrored+localhost+in%3Atitle
- 结论：mirrored **不能作为唯一的前提**。它只在 Win11 22H2+ 上可用，还可能静默失效或出 bug，方案必须在 NAT 下也能工作。

---

## 3. WebSocket / SSE 长连接经过转发（中）

- **主流工具在用**：VS Code Remote-WSL 通过 WebSocket 连接 WSL。#7586 由 VS Code 团队成员提交；#41680 也描述了 VS Code 类客户端连接 `127.0.0.1:<port>`。说明 WebSocket over localhost relay 在一般情况下可用。来源：https://github.com/microsoft/WSL/issues/7586 、https://github.com/microsoft/WSL/issues/41680
- **NAT relay 的半双工缺陷，会导致死锁（高）**
  - #10688（2023-10 开，open）：Linux 侧的 relay 用单线程阻塞 I/O 同时处理两个方向，Windows 侧的 `wslrelay.exe` 也会"simulates a similar write-blocking pattern"。"While this will work with a half-duplex request-reply style system (e.g. http/1.1), it will lead to connection hangs when there is a multiplexed protocol and bidirectional traffic (e.g. ssh, http/2, etc)"。症状是 Linux 侧 socket 的 Recv-Q 长期不为 0。在 1.2.5 和 2.0.5 上复现过。规避方法：改用 mirrored，或者直接连 VM 的虚拟 IP。来源：https://github.com/microsoft/WSL/issues/10688
  - #41680（2026-09-23，**WSL 2.7.14，当前稳定版**）：给出了量化的触发条件：大约一个方向 ≥300–600 KB、同时另一个方向 ≥200–300 KB 的并发传输。一旦死锁，连接会永久卡住，FIN 送不到对端，socket 一直停在 ESTABLISHED；客户端超时重连时每次都会泄漏一个 socket（几小时后观察到 640+ 个）；报告者还观察到被卡住的端口此后再也收不到新连接（"poison the port"）。来源：https://github.com/microsoft/WSL/issues/41680
  - 修复 PR #41458（open）："Support full duplex traffic and half close socket in NAT localhost relay"。它还指出旧 relay 在"one side's read is closed"时会关闭两个方向，这会影响 TCP 半关闭（half-close）的场景。来源：https://github.com/microsoft/WSL/pull/41458
  - **对预览场景的含义（推论）**：预览推送基本是"服务端→浏览器"方向，浏览器→服务端只有很小的控制消息。SSE 天然是单向的。正常情况下达不到上面的双向并发阈值，风险低，但不是零：浏览器在同一连接上上传大量数据的同时服务端推送大文档，就可能触发。设计上应该让大块内容走单独的 HTTP GET，WebSocket / SSE 只发"文档已变更"这类小通知。
- **网络变化**：#7586（2021）：通过 **VM 虚拟 IP** 建立的 WebSocket，会在 Wi-Fi 重连时断开，因为 vEthernet (WSL) 适配器会闪断；"Works when using localhost"。来源：https://github.com/microsoft/WSL/issues/7586
- **休眠唤醒**：见 1.4 节。任何长连接都要假设可能断开，并实现重连。
- **mirrored**：见 2.4 节 #41137，WebSocket 会以 1006 断开。
- **SSE**：在 microsoft/WSL 中检索 `"server-sent events"`，结果为 0（2026-09-24）。**没有找到 SSE 专属问题。** SSE 本质上是一个长时间不结束的 HTTP/1.1 响应，在 relay 看来和普通 HTTP 响应没有区别。
- **空闲超时**：没有找到"relay 会主动断开空闲长连接"的一手说明。建议应用层心跳（15–30 s）作为保险，列入实验 E3。

---

## 4. 从 WSL 打开 Windows 默认浏览器

### 4.1 wslu / wslview 的维护状态（高）

- GitHub 仓库 `wslutilities/wslu` 已被**归档（archived）**，最后一次 push 是 2025-03-01，最后一个 release 是 v4.1.3（2024-04-10）。来源：https://api.github.com/repos/wslutilities/wslu 、https://github.com/wslutilities/wslu/releases
- README 原文："Built-in versions of wslu in Ubuntu are no longer supported by me."，并建议改用作者的 PPA。来源：https://github.com/wslutilities/wslu/blob/master/README.md
- Ubuntu 包索引：`wslu 3.2.3-0ubuntu3` 在 jammy（22.04）、noble（24.04）、questing 中存在；**resolute（26.04）中 "Package not available in this suite"**。来源：https://packages.ubuntu.com/noble/wslu 、https://packages.ubuntu.com/resolute/wslu
- **是否预装**：`ubuntu-wsl` 元包在 jammy、noble、resolute 的依赖和推荐列表里都**没有** wslu。官方 WSL 镜像 manifest 中也**没有 `wslu`，也没有 `xdg-utils`**：
  - jammy 镜像（2024-03-05）：https://cloud-images.ubuntu.com/wsl/releases/jammy/current/ubuntu-jammy-wsl-amd64-wsl.manifest
  - noble 每日构建（2026-09-08）：https://cdimages.ubuntu.com/ubuntu-wsl/noble/daily-live/current/noble-wsl-amd64.manifest
  - resolute 每日构建（2026-09-23）：https://cdimages.ubuntu.com/ubuntu-wsl/resolute/daily-live/current/resolute-wsl-amd64.manifest
  - 元包依赖：https://packages.ubuntu.com/noble/ubuntu-wsl
  - 结论：**新装的 Ubuntu WSL 默认既没有 `wslview`，也没有 `xdg-open`**。老用户机器上可能因为历史镜像或手动安装而存在，不能依赖。
- wslview 的实现（源码 `src/wslview.sh`、`src/wslu-header`）：默认引擎是 `powershell`（配置文件中 `WSLVIEW_DEFAULT_ENGINE="powershell"`），最终执行的是 `<automount root>/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "Start \"<url>\""`；可选引擎是 `cmd.exe /c start` 和 `cmd.exe /c explorer.exe`。它用**绝对路径**调用 Windows 程序，所以不受 `appendWindowsPath=false` 影响。启动时如果读到 wsl.conf 中 `interop enabled=false`，或者 `/proc/sys/fs/binfmt_misc/WSLInterop` 为 disabled，就打印提示并 `exit 1`。来源：https://github.com/wslutilities/wslu/blob/master/src/wslview.sh 、https://github.com/wslutilities/wslu/blob/master/src/wslu-header 、https://github.com/wslutilities/wslu/blob/master/src/etc/conf

### 4.2 各种打开方式（文档层面：高；细节：中）

| 方式 | 一手依据 | 已知注意点 |
| --- | --- | --- |
| `cmd.exe /c start "" "<url>"` | `start` 命令参考："URLs, which are automatically detected and opened in the default browser"；示例 `start "Bing" "https://www.bing.com"`。第一个带引号的参数会被当作窗口标题，所以要先传一个空标题 `""` | ① WSL 当前目录在 Linux 文件系统里时，cmd 不支持 UNC 当前目录（1903 博客："CMD does not support UNC paths as current directories"），会打印警告并回退到 Windows 目录，但不影响打开，可以先 `cd /mnt/c` 规避；② URL 中的 `&` 是 cmd 的元字符，经过 WSL 参数转换后是否仍然被引号包住，**待验证**（实验 E6） |
| `powershell.exe -NoProfile -Command "Start-Process '<url>'"` | wslview 的默认引擎；Learn 的 filesystems 页也用 `powershell.exe /c start .` 作为 `explorer.exe .` 的替代写法 | PowerShell 冷启动较慢（**待测**，E6）；URL 中的单引号需要转义 |
| `explorer.exe "<url>"` | Learn 只给出了 `explorer.exe .` 打开**目录**的用法，**没有找到**微软对"explorer.exe + URL"的文档化保证 | 置信度低；退出码不可靠也只是坊间说法，**待验证**（E6） |
| `xdg-open` / `wslview` | 见 4.1 | 默认没有安装 |
| 打印 URL | — | 永远可用，作为最后兜底 |

来源：https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/start 、https://devblogs.microsoft.com/commandline/whats-new-for-wsl-in-windows-10-version-1903/ 、https://learn.microsoft.com/en-us/windows/wsl/filesystems#view-your-current-directory-in-windows-file-explorer

### 4.3 interop 被禁用、`appendWindowsPath=false` 时的表现

- 文档语义（高）：wsl.conf 的 `[interop] enabled` 决定"whether WSL will support launching Windows processes"；`appendWindowsPath` 决定是否把 Windows 路径加入 `$PATH`。示例文件的注释写道："Setting these to false will block the launch of Windows processes and block adding $PATH environment variables"。要求 Win10 1809（17763）及以上。另外可以用 `echo 0 > /proc/sys/fs/binfmt_misc/WSLInterop` 临时禁用，仅对当前会话有效。来源：https://learn.microsoft.com/en-us/windows/wsl/wsl-config#interop-settings 、https://learn.microsoft.com/en-us/windows/wsl/filesystems#disable-interoperability
- `appendWindowsPath=false`（高）：`cmd.exe` / `powershell.exe` 会报 `command not found`。故障排查页把这当作"命令找不到"的常见原因之一。用绝对路径（默认 `/mnt/c/Windows/System32/cmd.exe`；如果 wsl.conf 的 `automount.root` 改过，前缀也要跟着改）仍然可以调用。来源：https://learn.microsoft.com/en-us/windows/wsl/troubleshooting#running-windows-commands-fails-inside-a-distribution 、https://learn.microsoft.com/en-us/windows/wsl/troubleshooting#command-not-found-when-executing-windows-exe-in-linux
- `interop.enabled=false` 的具体报错形态（中，基于读源码的推断）：
  - WSL2（utility VM）中，`WSLInterop` 这个 binfmt 条目由 `mini_init` 在 **VM 级别**注册（`src/linux/init/main.cpp` 中的 `BINFMT_REGISTER_STRING`），与单个发行版的设置无关。发行版的 `init` 只在 `Config.InteropEnabled` 为真时才创建 interop 服务器、设置 `WSL_INTEROP` 环境变量（`src/linux/init/init.cpp`、`config.cpp`）。执行 `.exe` 时，binfmt 处理程序 `CreateNtProcessUtilityVm` 连不上 interop 服务器，就直接返回退出码 1（`src/linux/init/binfmt.cpp`）。所以**预期表现是 `.exe` 执行失败、退出码为 1，而且可能没有任何明确报错**，而不是 "Exec format error"。来源：https://github.com/microsoft/WSL/blob/master/src/linux/init/main.cpp 、https://github.com/microsoft/WSL/blob/master/src/linux/init/binfmt.cpp 、https://github.com/microsoft/WSL/blob/master/src/linux/init/config.cpp
  - 相关 release notes：0.70.4 "Fix regression where /etc/wsl.conf interop.enabled setting was not respected"；2.3.21 "Don't register the binfmt_late entry when interop is disabled"。说明这里的实现细节在不同版本之间变过，**报错形态必须真机确认**（实验 E7）。来源：https://github.com/microsoft/WSL/releases/tag/0.70.4 、https://github.com/microsoft/WSL/releases/tag/2.3.21
  - **对设计的影响**：不能只看 `.exe` 能不能执行来判断浏览器是否打开了。调用失败（退出码非 0）或检测到 interop 被禁用时，打印 URL 并提示用户手动打开。

---

## 5. 反方向与备选方案

### 5.1 Windows 侧程序直接读 `\\wsl.localhost` 并自行渲染

- **机制（高）**：Windows 通过 9P 协议访问 Linux 文件，文件服务器运行在 WSL 的 init 内，Windows 侧的服务和驱动作为客户端。访问 Linux 文件在 Windows 看来"treated the same as accessing a network resource"。来源：https://devblogs.microsoft.com/commandline/whats-new-for-wsl-in-windows-10-version-1903/ 、https://learn.microsoft.com/en-us/windows/wsl/troubleshooting#cannot-access-wsl-files-from-windows
- **WSL 没运行时会不会自动启动（高，但有历史变化）**：
  - 1903 博客（2019）的已知问题写的是"only be accessible from Windows when the distro is running"。
  - 后来行为变了。微软成员 OneBlue 在 #10007（2023）中说："When a requests comes throw \\wsl.localhost, the WSL2 vm needs to be started, which can take a bit of time and appear like a 'slow connection'"。也就是说，**访问 `\\wsl.localhost` 会自动拉起 VM**，首次访问会有启动延迟。来源：https://github.com/microsoft/WSL/issues/10007
  - 目前还不确定这样拉起的发行版会不会因为 `instanceIdleTimeout`（默认 15 s）或 `vmIdleTimeout`（默认 60 s）被反复停止、再反复启动，从而造成周期性卡顿。列入实验 E8。来源：https://learn.microsoft.com/en-us/windows/wsl/wsl-config
- **变更通知（高）**：`ReadDirectoryChangesW` 在 `\\wsl$` 路径上不支持（#7674，由 VS Code 团队成员 bpasero 于 2021 年提交，截至 2026-02 仍 open，标签 feature）。VS Code、Node `fs.watch` 的相关 issue 都链接到这里。**Windows 侧程序拿不到文件变化通知，只能轮询。** 来源：https://github.com/microsoft/WSL/issues/7674
- **性能（定性：高；定量：没有一手数据）**：
  - Learn："if you are using Windows applications to access Linux files, you will currently achieve faster performance with WSL 1"；功能对比表中 WSL2 的"Performance across OS file systems"一项为 ❌。来源：https://learn.microsoft.com/en-us/windows/wsl/compare-versions
  - #10007：通过 `\\wsl.localhost` 编辑文件时，偶尔表现得像高延迟的网络盘，保存有时需要约 30 s，编辑器偶尔误以为文件被删除（因作者不活跃被自动关闭）。#4311（这里只读了标题）："Cannot access \\wsl$ after waking computer from sleep"。来源：https://github.com/microsoft/WSL/issues/10007
  - 预览场景下，单次读取几 KB 到几百 KB 的 Markdown，9P 延迟大概率可以接受；但每秒轮询 stat 整棵目录树，成本会随文件数线性增长。定量数据待测（实验 E8）。
- **结论**：可行，但只能靠轮询、有冷启动延迟、需要在 Windows 侧安装程序，还要承受 9P 偶发卡顿。相比"WSL 内 inotify + 推送"要差，适合作为备选，不适合作为首选。

### 5.2 WSLg：在 WSL 内打开 GUI 窗口（Linux 浏览器或桌面预览器）

- **版本要求（高）**：Learn："Windows 10 Build 19044+ or Windows 11"，只支持 WSL 2。WSLg README 推荐使用 Store 版 WSL，也支持 Win10。`guiApplications` 默认为 `true`。来源：https://learn.microsoft.com/en-us/windows/wsl/tutorials/gui-apps 、https://github.com/microsoft/wslg 、https://learn.microsoft.com/en-us/windows/wsl/wsl-config
- **机制（高）**：系统发行版中运行 Weston 与 XWayland，通过 RDP 的 RAIL/VAIL 机制把单个窗口投射到 Windows 上（由 `mstsc.exe` 以静默模式连接）。GPU 驱动是可选项，用来做加速。来源：https://github.com/microsoft/wslg
- **限制**：
  - Learn："does not provide a full desktop experience"（高）。
  - **CJK 字体（高）**：noble 和 resolute 的 WSL 镜像 manifest 里只有 `fonts-dejavu-*` 和 `fonts-ubuntu`，没有 CJK 字体。Linux 侧的浏览器或预览器显示中文时会出现方框，需要用户自己 `apt install fonts-noto-cjk`。来源：见 4.1 节的 manifest 链接。
  - **HiDPI（中）**：wslg #388 "HiDPI Scaling"（2021 年开，仍 open）、#1504 "HiDPI scale lost on suspend"（2026-09，open）、#1481（open）。**IME（中）**：wslg #9 "IME Support"（2021 年开，仍 open）。只读预览基本不需要输入法，影响不大。以上只读了标题。检索入口：https://github.com/microsoft/wslg/issues?q=HiDPI+in%3Atitle 、https://github.com/microsoft/wslg/issues/9
  - **浏览器安装**：Learn 给出了 Chrome 的 `.deb` 安装方式和 Edge 的安装入口。Ubuntu 上的 Firefox 是 snap 包，依赖 snapd 和 systemd（推论，没有单独验证）。
  - **生命周期（高）**：#9968（open）：关闭所有 WSL 终端后，即使有后台进程，实例也会在一段时间后自动关闭。2.5.4 引入了 `[general] instanceIdleTimeout` 来控制这个超时（Learn 说明："Set to -1 to disable auto shutdown"）。**这一条同样影响"WSL 内常驻 HTTP 服务"这条主路线。** 来源：https://github.com/microsoft/WSL/issues/9968 、https://github.com/microsoft/WSL/releases/tag/2.5.4 、https://learn.microsoft.com/en-us/windows/wsl/wsl-config#general-wsl-settings
- **结论**：技术上可行，Windows 侧不用装任何东西，也不涉及网络端口。但窗口不是 Windows 原生的，有字体、缩放、休眠唤醒方面的问题，还要额外安装一个 Linux 浏览器，体验不如 Windows 浏览器。只适合作为备选。

---

## 6. 待真机验证的实验（命令级）

通用准备：一台 Win11 23H2+（最好再加一台 Win10 22H2 做对照），Store 版 WSL（记录 `wsl --version`），Ubuntu 24.04。每个实验都要记录 `wsl --version`、`wslinfo --networking-mode` 和 Windows 版本号（`winver`）。

### E1：NAT 下不同绑定地址 × 不同访问地址（验证 1.2、1.5 节）

WSL：

```bash
wslinfo --networking-mode            # 期望 nat
python3 -m http.server 8801 --bind 127.0.0.1 >/dev/null 2>&1 &
python3 -m http.server 8802 --bind 0.0.0.0   >/dev/null 2>&1 &
python3 -m http.server 8803 --bind ::        >/dev/null 2>&1 &   # 双栈
python3 -c "
import socket,http.server
class S(http.server.ThreadingHTTPServer):
    address_family=socket.AF_INET6
    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1); super().server_bind()
S(('::1',8804), http.server.SimpleHTTPRequestHandler).serve_forever()" >/dev/null 2>&1 &
ss -ltn '( sport >= :8801 and sport <= :8804 )'
```

Windows PowerShell：

```powershell
foreach ($p in 8801..8804) { foreach ($h in '127.0.0.1','[::1]','localhost') {
  $u = "http://${h}:$p/"
  try { $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 $u; "$u -> $($r.StatusCode)" }
  catch { "$u -> FAIL $($_.Exception.Message)" } } }
Get-NetTCPConnection -State Listen -LocalPort 8801,8802,8803,8804 |
  Select-Object LocalAddress,LocalPort,@{n='Proc';e={(Get-Process -Id $_.OwningProcess).ProcessName}}
Resolve-DnsName localhost
```

然后在 Edge 和 Chrome 地址栏里分别打开 `http://localhost:8801` 到 `http://localhost:8804`，记录哪些能打开。连上 VPN 后把 Windows 侧的命令全部重跑一遍。
**判定**：预期 8801 和 8802 在 `127.0.0.1` 与 `localhost` 下都成功；8803 只有 `[::1]` 能通，是否能通过 `localhost` 访问取决于客户端；8804 同理。如果结果不同，就更新 1.2 节。

### E2：端口冲突（验证 1.3 节）

Windows PowerShell（先占住端口）：

```powershell
$l = [System.Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 8810); $l.Start()
netsh int ipv4 show excludedportrange protocol=tcp
```

WSL：

```bash
python3 -m http.server 8810 --bind 127.0.0.1; echo "exit=$?"   # 观察 WSL 侧是否报错
```

Windows PowerShell：

```powershell
curl.exe -m 5 -sS http://127.0.0.1:8810/ ; "curl exit=$LASTEXITCODE"
Get-NetTCPConnection -State Listen -LocalPort 8810 |
  Select-Object LocalAddress,@{n='Proc';e={(Get-Process -Id $_.OwningProcess).ProcessName}}
$l.Stop()
```

**判定**：WSL 服务启动成功、Windows curl 超时（请求被 PowerShell 的 listener 接走），就说明冲突是静默的。

### E3：WebSocket / SSE 长连接、休眠唤醒、空闲（验证 1.4、3 节）

WSL（需要 `sudo apt install -y python3-websockets`）。把下面的脚本保存为 `~/probe.py`，运行 `python3 ~/probe.py 127.0.0.1`：

```python
import asyncio, sys, threading, time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
import websockets

HOST = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
HTTP_PORT, WS_PORT = 8820, 8821
PAGE = f"""<!doctype html><meta charset=utf-8><pre id=log></pre><script>
const log=m=>{{document.getElementById('log').textContent+=new Date().toISOString()+' '+m+'\\n'}};
function sse(){{const es=new EventSource('/sse');es.onopen=()=>log('sse open');
  es.onerror=()=>log('sse error');es.onmessage=e=>{{document.title='sse '+e.data}};}}
function ws(){{const w=new WebSocket('ws://'+location.hostname+':{WS_PORT}/');
  w.onopen=()=>log('ws open');w.onclose=e=>{{log('ws close '+e.code);setTimeout(ws,2000)}};}}
sse();ws();
</script>""".encode()

def ts(): return time.strftime("%H:%M:%S")

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path == "/sse":
            self.send_response(200); self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache"); self.end_headers()
            print(ts(), "sse connect", self.client_address, flush=True); n = 0
            try:
                while True:
                    self.wfile.write(f"data: {n}\n\n".encode()); self.wfile.flush(); n += 1; time.sleep(1)
            except OSError as e:
                print(ts(), "sse gone", e, flush=True)
        else:
            self.send_response(200); self.send_header("Content-Type", "text/html"); self.end_headers()
            self.wfile.write(PAGE)

async def ws_handler(ws):
    print(ts(), "ws connect", ws.remote_address, flush=True); n = 0
    try:
        while True:
            await ws.send(str(n)); n += 1; await asyncio.sleep(1)
    except websockets.ConnectionClosed as e:
        print(ts(), "ws gone", e.code, flush=True)

async def main():
    threading.Thread(target=ThreadingHTTPServer((HOST, HTTP_PORT), H).serve_forever, daemon=True).start()
    async with websockets.serve(ws_handler, HOST, WS_PORT):
        print(ts(), f"http://{HOST}:{HTTP_PORT}/", flush=True); await asyncio.Future()

asyncio.run(main())
```

Windows：在 Edge 中打开 `http://127.0.0.1:8820/`，然后依次执行：
1. 放置 30 分钟不操作，看是否出现 `sse error` 或 `ws close`（验证空闲超时）；
2. 开始菜单 → 睡眠，等 5 分钟后唤醒，记录页面日志和 WSL 终端输出；
3. 休眠：`shutdown /h`，恢复后同上（需要先 `powercfg /hibernate on`）；
4. 断开 Wi-Fi 再重连，同上。

每一步之后在 Windows PowerShell 中执行 `curl.exe -m 5 http://127.0.0.1:8820/`。如果失败，再执行 `wsl -e true` 看 WSL 是否还有响应，然后 `wsl --shutdown`、重启脚本，看能否恢复。
**判定**：记录每种场景下是否断开、多久能恢复、是否需要 `wsl --shutdown`。

### E4：NAT relay 双向死锁（验证 3 节的阈值和对预览流量的影响）

直接使用 #41680 正文中的 `burst_srv.py`（WSL 侧）和 `burst_cli.ps1`（Windows 侧），按其中表格的 A–I 组合跑一遍：

```bash
python3 burst_srv.py 45999 burst 127.0.0.1 1689467        # WSL
```

```powershell
powershell -File burst_cli.ps1 -Port 45999 -BigBytes 852000   # Windows
```

再按"预览流量模型"跑一次：`BigBytes` 设为 2000（客户端只发少量数据），服务端 burst 设为 5 MB，确认不会死锁。
**判定**：如果 A、F、H 组合死锁、预览模型不死锁，就确认"单向推送"的设计能避开这个问题。

### E5：mirrored 模式（验证 2 节）

Windows：编辑 `%UserProfile%\.wslconfig`：

```ini
[wsl2]
networkingMode=mirrored
```

```powershell
wsl --shutdown; Start-Sleep 10; wsl -e wslinfo --networking-mode   # 必须输出 mirrored，否则记录为"静默回退"
Get-NetFirewallHyperVVMSetting -PolicyStore ActiveStore -Name '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'
Get-NetFirewallProfile -PolicyStore ActiveStore | Select-Object Name,AllowLocalFirewallRules,AllowInboundRules
```

然后重跑 E1（重点看 `[::1]`）、E2（看 WSL 侧 bind 是否直接报 `Address already in use`）、E3。再从同一局域网的另一台设备执行 `curl http://<Windows 的 LAN IP>:8802/`，确认默认被 Hyper-V 防火墙阻止。
**判定**：`127.0.0.1` 可通、`[::1]` 不通、LAN 默认不通，和第 2 节一致；如果出现 #41137 那样的超时，要记录下来。

### E6：打开浏览器的各种方式（验证 4.2 节）

WSL（在 Linux 文件系统的目录下执行，以便观察 UNC 警告）：

```bash
cd ~
URL='http://127.0.0.1:8820/?path=docs%2Fa%20b.md&x=1'
command -v wslview xdg-open cmd.exe powershell.exe explorer.exe
time /mnt/c/Windows/System32/cmd.exe /c start "" "$URL"; echo "cmd exit=$?"
time /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile -NonInteractive -Command "Start-Process '$URL'"; echo "ps exit=$?"
time /mnt/c/Windows/explorer.exe "$URL"; echo "explorer exit=$?"
```

**判定**：每种方式是否打开了默认浏览器、地址栏里的 URL 是否完整（`&x=1` 有没有丢）、耗时多少、退出码是多少、是否打印了 "UNC paths are not supported"。如果 cmd 丢了 `&` 后面的部分，就把 `^&` 转义和 `cd /mnt/c` 的效果再测一遍。

### E7：interop 被禁用、`appendWindowsPath=false`（验证 4.3 节）

WSL：

```bash
sudo tee -a /etc/wsl.conf >/dev/null <<'EOF'
[interop]
enabled=false
appendWindowsPath=false
EOF
```

Windows：`wsl --terminate Ubuntu-24.04`，等 8 秒后重新进入 WSL：

```bash
echo "WSL_INTEROP=$WSL_INTEROP"; ls /proc/sys/fs/binfmt_misc/; cat /proc/sys/fs/binfmt_misc/WSLInterop 2>&1 | head -3
command -v cmd.exe; echo "which exit=$?"
/mnt/c/Windows/System32/cmd.exe /c ver; echo "cmd exit=$?"
```

然后只保留 `appendWindowsPath=false`（`enabled=true`），重复上面的步骤。测完恢复原始的 wsl.conf。
**判定**：记录禁用 interop 时的实际报错文本和退出码（源码推断为静默失败、退出码 1）；确认 `appendWindowsPath=false` 时用绝对路径可以正常调用。

### E8：`\\wsl.localhost` 读取、自动启动与性能（验证 5.1 节）

WSL（生成测试树）：

```bash
mkdir -p ~/mdbench && cd ~/mdbench
for i in $(seq 1 2000); do d=d$((i%50)); mkdir -p $d; head -c 15000 /dev/urandom | base64 > $d/f$i.md; done
```

Windows PowerShell（把 `<user>` 和发行版名换成实际值）：

```powershell
$root = '\\wsl.localhost\Ubuntu-24.04\home\<user>\mdbench'
wsl --shutdown; Start-Sleep 10; wsl -l -v                         # 确认 Stopped
Measure-Command { Get-Content "$root\d1\f1.md" -TotalCount 1 }     # 冷启动首次访问
wsl -l -v                                                          # 是否变成 Running
Measure-Command { 1..200 | ForEach-Object { [IO.File]::ReadAllText("$root\d1\f1.md") } }
Measure-Command { Get-ChildItem $root -Recurse -File | Measure-Object Length -Sum }
Copy-Item $root C:\temp\mdbench -Recurse
Measure-Command { Get-ChildItem C:\temp\mdbench -Recurse -File | Measure-Object Length -Sum }  # 本地 NTFS 对照
$w = New-Object IO.FileSystemWatcher $root; $w.IncludeSubdirectories = $true
try { $w.EnableRaisingEvents = $true; 'watch ok' } catch { "watch FAIL: $($_.Exception.Message)" }
Register-ObjectEvent $w Changed -Action { Write-Host "changed $($Event.SourceEventArgs.FullPath)" } | Out-Null
```

WSL 中执行 `echo x >> ~/mdbench/d1/f1.md`，观察 Windows 是否收到事件。之后关闭所有 WSL 终端，在 Windows 上每 10 秒执行一次 `wsl -l -v` 并读一次文件，持续 3 分钟，观察发行版是否在 Stopped 和 Running 之间反复切换，以及读取延迟是否周期性变高。
**判定**：记录冷启动延迟、单文件读取的 P50 和 P95、目录遍历耗时与 NTFS 的倍数、FileSystemWatcher 是否报错或静默。

### E9：WSL 内常驻服务的生命周期（验证 5.2 节中 #9968 对主路线的影响）

WSL：`nohup python3 -m http.server 8830 --bind 127.0.0.1 >/dev/null 2>&1 &`，然后关闭**所有** WSL 终端。
Windows PowerShell：每 15 秒执行一次 `curl.exe -m 3 -s -o NUL -w "%{http_code}\n" http://127.0.0.1:8830/; wsl -l -v`，持续 3 分钟。
然后在 `.wslconfig` 中加入：

```ini
[general]
instanceIdleTimeout=-1
```

执行 `wsl --shutdown` 后重复上面的步骤。另外在 systemd 开启（Ubuntu 24.04 默认）和关闭两种状态下各测一次。
**判定**：服务是否在终端关闭后被连带停止；`instanceIdleTimeout=-1` 是否能让它一直存活。

### E10：WSLg 备选（验证 5.2 节）

WSL：

```bash
echo "DISPLAY=$DISPLAY WAYLAND_DISPLAY=$WAYLAND_DISPLAY"; ls /mnt/wslg
cd /tmp && wget -q https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb && sudo apt install -y ./google-chrome-stable_current_amd64.deb
printf '# 中文标题\n\n测试段落\n' > /tmp/zh.md
google-chrome --no-first-run http://127.0.0.1:8820/ &   # 需要 E3 的脚本在运行
```

观察中文是否显示为方框。执行 `sudo apt install -y fonts-noto-cjk` 后重开浏览器再看。在 150% 或 200% 缩放的显示器上检查清晰度，睡眠唤醒后再检查一次。
**判定**：记录首次启动耗时、中文渲染、HiDPI 下的清晰度、唤醒后窗口是否还在、缩放是否丢失。

---

## 7. 来源清单

Microsoft Learn / 微软博客：
- https://learn.microsoft.com/en-us/windows/wsl/networking
- https://learn.microsoft.com/en-us/windows/wsl/wsl-config
- https://learn.microsoft.com/en-us/windows/wsl/troubleshooting
- https://learn.microsoft.com/en-us/windows/wsl/filesystems
- https://learn.microsoft.com/en-us/windows/wsl/compare-versions
- https://learn.microsoft.com/en-us/windows/wsl/tutorials/gui-apps
- https://learn.microsoft.com/en-us/windows/security/operating-system-security/network-security/windows-firewall/hyper-v-firewall
- https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/start
- https://devblogs.microsoft.com/commandline/windows-subsystem-for-linux-september-2023-update/
- https://devblogs.microsoft.com/commandline/whats-new-for-wsl-in-windows-10-version-1903/

microsoft/WSL issue / PR（正文已读）：
#4436、#4851、#5298、#5317、#6953、#7586、#7674、#8696、#8905、#9968、#10007、#10688、#10803、#11172、#14154、#41137、#41196、#41481、#41680、PR #41458（统一前缀 https://github.com/microsoft/WSL/issues/ 或 https://github.com/microsoft/WSL/pull/）

microsoft/WSL release notes：0.70.4、1.1.0、1.1.6、1.3.10、2.0.0、2.0.5、2.1.1、2.2.2、2.3.21、2.3.25、2.5.4、2.9.3（https://github.com/microsoft/WSL/releases/tag/<版本号>）

WSL 源码：`src/linux/init/main.cpp`、`init.cpp`、`config.cpp`、`binfmt.cpp`、`util.cpp`（https://github.com/microsoft/WSL/tree/master/src/linux/init ，2026-09-24 的 master 分支浅克隆）

wslu：https://github.com/wslutilities/wslu （README、`src/wslview.sh`、`src/wslu-header`、`src/etc/conf`；仓库元数据来自 GitHub API）

Ubuntu：https://packages.ubuntu.com/ （`wslu`、`ubuntu-wsl`、`wsl-setup` 在 jammy/noble/questing/resolute 各版本中的记录）；WSL 镜像 manifest：https://cloud-images.ubuntu.com/wsl/ 、https://cdimages.ubuntu.com/ubuntu-wsl/

WSLg：https://github.com/microsoft/wslg （README）；wslg issue #9、#388、#1481、#1504（只读了标题）
