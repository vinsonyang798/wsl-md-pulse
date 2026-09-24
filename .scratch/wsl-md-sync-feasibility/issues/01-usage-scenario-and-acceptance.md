Type: grilling
Status: open
Blocked by:

# 使用场景与"同步显示"的验收标准

## Question

"同步显示 WSL 下的 md 文档"在用户的真实工作流里具体指什么？需要和用户本人确认：

- **文件在哪**：WSL 自身文件系统（如 `~/notes`，ext4）、Windows 盘挂载（`/mnt/c/...`），还是两者都有？
- **谁在改文件**：WSL 内的 vim/nvim、VS Code Remote-WSL、Windows 侧编辑器经 `\\wsl.localhost\...` 编辑，还是 git pull / 脚本生成？
- **"同步"的定义**：保存后刷新即可，还是要按键级实时、滚动跟随编辑器？可接受延迟是多少（如 ≤1s）？
- **在哪看**：Windows 浏览器、编辑器侧栏、独立桌面窗口——哪些可接受、哪些不行？
- **看什么**：单个文件还是整个目录树；必须支持的 Markdown 特性（GFM 表格、代码高亮、Mermaid、数学公式、本地图片、文档间相对链接）。
- **硬约束**：Windows 侧能否安装软件；WSL 里能否装 Node/Python 等运行时；是否在公司网络/VPN 下。

产出：一份验收标准清单，后续用它评估"现成方案盘点"和"选定路线"。
