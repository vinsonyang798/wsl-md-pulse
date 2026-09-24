Type: grilling
Status: claimed
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

## Comments

### 第 1 轮（用户回答）

- **文件在哪**：只在 WSL 自己的文件系统里（如 `~/notes`，ext4），不涉及 `/mnt/c`。
- **谁在改文件**：主要是装在 WSL 里的 agent 工具，例如 codex cli。
- **同步定义**：保存后 1 秒内刷新，并保留滚动位置。
- **在哪看**：用户试过 VS Code，但"默认看不到 md 渲染"，问有没有办法（agent 答复见下）。
- **Markdown 特性**：GFM、代码高亮、Mermaid、本地图片、文档间相对链接、目录树都要；数学公式不需要。
- **硬约束**：WSL 里零运行时依赖，Windows 上不装任何东西。

agent 答复"在哪看"（据 VS Code 官方文档 https://code.visualstudio.com/docs/languages/markdown）：VS Code 自带 Markdown 预览，只是默认打开 `.md` 时显示的是源码。
- 打开预览：`Ctrl+Shift+V`；在旁边分栏打开：`Ctrl+K V`。
- 想双击 `.md` 就直接显示渲染结果，在设置里加 `"workbench.editorAssociations": {"*.md": "vscode.markdown.preview.editor"}`。
- 内置预览已支持 Mermaid。
- 前提是 VS Code 以 WSL 模式连接：在 WSL 终端里运行 `code ~/notes`，左下角显示 `WSL: <发行版>`。如果从 Windows 侧打开 `\\wsl.localhost\...` 路径，Windows 收不到文件变更通知（见"WSL2 文件变更检测的事实边界"），codex 改了文件后预览不会自动刷新。
- 没开"预览锁定"时，预览跟随*当前激活的编辑器*，不会自动跳到 agent 刚改的文件。

新暴露的问题见第 2 轮。
