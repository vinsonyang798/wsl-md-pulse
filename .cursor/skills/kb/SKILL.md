---
name: kb
description: 项目知识库工具。支持子命令：(1) 搜索 - `kb s <关键词>` 在知识库中搜索；(2) 更新 - `kb u` 更新知识库内容；(3) 生成 - `kb g <内容>` 或 `kb r <内容>` 生成指定内容；(4) 索引 - `kb` 无参数时自动加载知识库索引到上下文。当用户请求："创建项目知识库"、"生成项目 kb"、"建一个 skill"、"项目本地文档"、"更新知识库"、"加载知识库"、"索引"、或显式提到 `kb`/`$kb` 时触发。
---

# 项目知识库工具

支持知识库搜索和管理。

## 文件关系（核心概念）

```
项目根目录/
└── .agents/skills/<name>/
    ├── SKILL.md                     ← 唯一入口（元数据 + 导航 + 更新日志）
    └── references/                  ← 详细内容目录
        ├── overview.md, commands.md  → 项目级文档
        ├── api/                     → API 接口文档（按模块拆分）
        │   ├── auth.md
        │   └── salon-admin.md
        └── *.md                     → 专题文档
```

**`SKILL.md` 是唯一入口** — 包含元数据（frontmatter）、项目概览、文档导航、更新日志。
**`references/` 是内容** — 所有详细文档按分类存放，按需读取。

## SKILL.md 索引文件规范

SKILL.md 是知识库的唯一入口和导航中心，位于 `.agents/skills/<name>/SKILL.md`。

### 核心原则

- **单一入口** — 不需要 `.kb` 或其他元数据文件，SKILL.md 包含一切
- **只存导航，不存详细内容** — 所有详细内容放在 `references/` 下
- **frontmatter 承载元数据** — name、description、version、updated_at、created_at、更新日志
- **参考文档使用表格** — 方便快速浏览

### 完整结构模板

```markdown
---
name: my-project
description: <触发描述>。当用户请求：(1) ... (2) ... 时触发。
---

# 项目名称 知识库

## 项目概览

- **技术栈**: <主要技术>
- **用途**: <核心功能>

## 参考文档

| 文档 | 说明 |
|------|------|
| [overview.md](references/overview.md) | 项目概览与架构 |
| [commands.md](references/commands.md) | 开发命令与构建流程 |
```

### Frontmatter 字段

| 字段 | 必填 | 说明 |
|------|------|------|
| `name` | 是 | 知识库名称，对应目录名 |
| `description` | 是 | 触发描述，用于 skill 系统识别 |

---

## 子命令（最高优先级）

当用户显式提到 `kb`、`$kb`，或输入 `kb <ARGUMENTS>` / `$kb <ARGUMENTS>` 时，首先判断子命令：

| 子命令 | 模式 | 操作 |
|--------|------|------|
| `s` 或 `search` | **搜索模式** | 在知识库中搜索关键词 |
| `u` 或 `update` | **更新模式** | 增量更新知识库内容 |
| `g` 或 `gen` 或 `generate` | **生成模式** | 生成指定内容到知识库 |
| `r` 或 `rebuild` | **重建模式** | 重新生成指定内容（同 generate） |
| `c` 或 `create` | **创建模式** | 首次创建项目知识库 |
| `i` 或 `index` | **索引模式** | 加载知识库索引到上下文 |
| 无子命令 | **索引模式** | **自动加载知识库索引到上下文** |
| 其他 | **搜索模式** | 根据参数智能搜索 |

### 索引模式: `kb` 或 `kb i`

**用法**:
- `kb` - 自动加载当前项目知识库索引到上下文
- `kb i` - 同上（显式索引命令）
- `kb index` - 同上（完整命令）

**执行流程**:
1. **发现知识库**：在项目 `.agents/skills/` 下查找包含 `version` frontmatter 的 SKILL.md
2. **加载索引文件**：读取 SKILL.md（frontmatter + 文档导航表）
3. **输出索引摘要**：知识库名称、版本、参考文档导航表、最近更新时间
4. **不预加载 references/** — 具体文档按需读取，避免消耗 context

**示例输出**:
```
已加载知识库索引: my-project (v1.2)

参考文档:
- overview.md - 项目概览与架构
- api/auth.md - 认证模块接口
- commands.md - 开发命令与构建流程

最近更新: 2026-04-17
```

---

### 搜索模式: `kb s <关键词>`

**用法**:
- `kb s IPC通信` - 搜索 IPC 相关内容
- `kb s 微信草稿` - 搜索微信草稿相关内容

**执行流程**:
1. **发现知识库**：同索引模式步骤 1
2. **解析 references 路径**：`SKILL.md 所在目录/references/`
3. **在知识库 references 目录中搜索**关键词：
   - 使用 Grep 在 `references/` 中搜索
   - 同时在项目源码中搜索相关文件和代码
4. **加载并展示**匹配的上下文（知识库段落 + 源码片段）
5. **简洁输出**搜索结果

### 更新模式: `kb u`

**用法**:
- `kb u` - 增量更新知识库（基于 Git 修改记录）
- `kb update` - 同上

**执行流程**:
1. **发现知识库**：同索引模式步骤 1
2. **读取项目变更**：通过 `git diff --name-only` 或最近 commit 获取变更文件列表
3. 分析修改内容，自动更新相应章节：
   - 新增文件 → 更新模块结构
   - 修改核心文件 → 更新说明
   - 新增命令 → 更新开发命令
4. 更新 SKILL.md 中的导航表（如新增/删除 reference 文档）

### 生成模式: `kb g <内容描述>` 或 `kb r <内容描述>`

**用法**:
- `kb g 项目架构` - 生成/重新生成项目架构文档
- `kb r API接口文档` - 生成/重新生成 API 接口文档

**执行流程**:
1. **发现知识库**：同索引模式步骤 1
2. 根据用户描述的内容，分析项目相关代码
3. 生成或更新对应的 reference 文档
4. 更新 SKILL.md 中的导航（如新增文档）

### 创建模式: `kb c` 或 `kb create`

**用法**:
- `kb c` - 在当前项目首次创建知识库

**执行流程**:
1. 检查项目 `.agents/skills/` 下是否已有知识库 SKILL.md，已有则提示使用 `kb u`
2. 分析项目类型和技术栈（从 AGENTS.md、go.mod、package.json 等）
3. 确定知识库名称（使用项目简称）
4. 创建目录：`<项目根目录>/.agents/skills/<name>/references/`（含 `api/` 子目录）— **必须在项目内，严禁写到 `~/.agents/skills/`**
5. 编写 SKILL.md（frontmatter 元数据 + 项目概览 + 参考文档导航表 + 更新日志）
6. 生成初始 reference 文档（至少：overview.md、commands.md）

---

## 自动判断模式（无子命令时）

当用户输入 `kb <内容>`、`$kb <内容>`，或明确要求"使用 kb"但不含子命令时：

| 内容特征 | 执行模式 |
|----------|----------|
| 无参数（仅 `kb` 或 `$kb`） | **索引模式** |
| 包含"索引"、"index"、"i " | 索引模式 |
| 包含"更新"、"update"、"u " | 更新模式 |
| 包含"生成"、"generate"、"gen"、"g " | 生成模式 |
| 包含"重建"、"rebuild"、"重新生成"、"r " | 生成模式 |
| 包含"创建"、"初始化"、"c " | 创建模式 |
| 包含"搜索"、"search"、"s " | 搜索模式 |
| 其他任意内容 | 搜索模式 |

---

## references/ 内容组织

所有详细知识库内容按分类存放在 `references/` 目录：

| 分类 | 文件命名 | 内容 |
|------|----------|------|
| 概览 | `overview.md` | 技术栈、项目用途、整体结构 |
| 规范 | `backend-rules.md` | 后端开发规范 |
| 规范 | `frontend-rules.md` | 前端开发规范 |
| 命令 | `commands.md` | 构建、运行、测试命令 |
| 部署 | `deployment.md` | 部署流程、CI/CD |
| 配置 | `config-pitfalls.md` | 配置踩坑记录 |
| API | `api/<module>-<side>.md` | 接口文档（按模块+端拆分） |
| 业务 | `business-flows.md` | 业务流程线文档 |
| 专题 | `*.md` | 架构说明、工具指南、测试报告等 |

API 文档命名规范：`api/<模块名>-<端>.md`，端分为 `admin`（后台管理）和 `miniapp`（小程序）。

---

## 注意事项

- **知识库必须创建在项目级** — 实际目录是 `<项目根目录>/.agents/skills/<name>/`，**严禁**写到全局 `~/.agents/skills/`
- **SKILL.md 是唯一入口** — 不需要 `.kb` 文件，所有元数据都在 SKILL.md frontmatter 中
- **本地知识库不需要打包** — 只在项目内部使用，无需生成 `.skill` 分发包
- **AGENTS.md 与知识库互补** — AGENTS.md 存架构概要，知识库存详细专题文档
- **更新时保持同步** — SKILL.md frontmatter（version/updated_at）、导航表、references/ 内容必须一致
