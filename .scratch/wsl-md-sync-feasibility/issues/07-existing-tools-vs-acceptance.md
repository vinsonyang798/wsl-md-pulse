Type: research
Status: resolved
Blocked by: 01, 02

# 现成工具对照验收标准的差距

## Question

以"使用场景与'同步显示'的验收标准"为尺子，逐条评估最接近的现成工具（至少 go-grip、markserv，以及盘点中遗漏但满足"单文件静态二进制 + 浏览器页 + 目录树 + Mermaid"的工具）：

1. 每条验收标准：原生满足 / 靠配置满足 / 需要改源码 / 做不到。尤其是**跟随模式**（自动切到最近修改的文档）和**阅读位置**（刷新后停在原标题段落、不整页跳动）。
2. 需要改源码的部分：改动落在哪些文件/模块、侵入程度（在刷新机制上加一层，还是要重写前端）、许可证是否允许 fork。
3. 安全默认值：是否只绑 `127.0.0.1`、WebSocket 是否校验 Origin、是否能读到根目录外的文件（路径穿越、符号链接）。
4. 分发：是否提供 linux amd64/arm64 静态二进制发布物，还是必须 `go install`/`cargo install`（需要工具链，违反零依赖）。

产出：一张差距表 + "fork/贡献现成工具"与"自己做"两种方式各自的改动面。

## Answer

**没有工具满足全部验收标准。最接近的是 Vantage，缺口集中在前端的两处：跟随模式，以及按阅读位置恢复。** 差距表、源码引用和实测过程见 [研究笔记](../research/07-existing-tools-vs-acceptance.md)。实测在 Linux 云主机上完成，不是 WSL2。

- **Vantage**（[mschulkind-oss/vantage](https://github.com/mschulkind-oss/vantage)；Go 单二进制，内嵌 React；Apache-2.0；v0.7.0）。
  - 原生满足：递归监听 ext4；局部刷新，不整页 reload；侧栏目录树；Mermaid 离线可用；本地图片和相对链接可用；amd64/arm64 静态二进制。
  - 安全默认值合格：只绑 `127.0.0.1`，WebSocket 校验 Origin，读文件前做 `EvalSymlinks` 根目录校验。
  - 缺口：没有跟随模式（推送消息已带变更路径，只需改前端）；刷新后按像素偏移恢复，不按标题；写接口没有 CSRF 防护；约 28k 行代码，功能远超只读预览（git、评审批注等）。
  - 另外：项目小众（14★），长期维护有风险（agent 于 2026-09-24 核对 GitHub API 得到）。
- **go-grip** 要达标接近重写：整页 reload；没有侧栏树；无论 `--host` 设什么都监听所有网卡；WebSocket 不校验 Origin；符号链接能逃出根目录；新建子目录中的文件不触发刷新；amd64 发布物是动态链接。可复用的只有 goldmark 渲染管线（MIT）。
- **markserv**、**mdserve** 排除：
  - markserv 需要 Node，存在路径穿越，WebSocket 不校验 Origin。
  - mdserve 已归档，只监听根目录一层，`CORS: *`。
- **阅读位置（按标题段落恢复）没有任何工具实现**，所以不论 fork 还是自己做，这部分都得写。

研究的倾向是：先以 Vantage 为基线做真机验证，再把跟随模式和按标题恢复做成前端补丁（提给上游或 fork）；自己做作为退路。最终取舍在"选定路线"里由用户决定。
