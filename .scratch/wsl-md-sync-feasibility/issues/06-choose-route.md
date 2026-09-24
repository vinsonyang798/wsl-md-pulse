Type: grilling
Status: open
Blocked by: 01, 02, 03, 04, 05

# 选定路线（go / no-go 与拓扑）

## Question

对照"使用场景与'同步显示'的验收标准"，在以下候选中作出决定，并写明取舍理由与已知风险：

- **A. 直接用现成工具**（不自己做）。
- **B. WSL 内服务 + Windows 浏览器**：WSL 内监听与渲染，通过 localhost 转发访问。
- **C. Windows 侧程序读 `\\wsl.localhost`**：Windows 侧监听与渲染（桌面应用或本地服务）。
- **D. 编辑器扩展**：寄生在 VS Code Remote-WSL / Neovim 等编辑器里。
- **E. no-go**：事实表明无法达到验收标准。

若选 B/C/D，还要确定：变化感知方式（原生事件 / 轮询 / 按路径类型切换）以及不同文件位置（ext4 与 `/mnt/c`）下各自的策略。
