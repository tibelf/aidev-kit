# aidev_kit

[English](README.md)

Claude Code 最佳实践套件 —— 将 agents、skills、commands、MCP 服务器、git hooks 和 CLAUDE.md 模板集中在一个仓库中管理。

## 快速开始

```bash
# 克隆并运行安装脚本
git clone https://github.com/tibelf/aidev_kit.git ~/.aidev_kit
cd ~/.aidev_kit
./setup.sh
```

或直接运行（克隆到临时目录）：

```bash
curl -fsSL https://raw.githubusercontent.com/tibelf/aidev_kit/main/setup.sh | bash
```

## 包含内容

| 类别 | 数量 | 描述 |
|------|------|------|
| **Agents（智能体）** | 13 | 专用智能体（前端、后端、Python、TypeScript、代码审查等） |
| **Skills（技能）** | 11 | React 最佳实践、Web 设计、CLAUDE.md 生成器、浏览器自动化、SEO 审计等 |
| **Commands（命令）** | 5 | 重构 CLAUDE.md、worktree 合并、Twitter 自动化 |
| **MCP 服务器** | 12 | filesystem、exa、rednote、browsermcp、rube、composio、chrome-devtools 等 |
| **Git Hooks** | 1 | post-commit（代码变更后通过 Claude 自动更新文档） |
| **CLAUDE.md** | 1 | 适用于所有项目的通用基础模板 |

## 交互式安装

`setup.sh` 提供 6 步 TUI 向导（由 [gum](https://github.com/charmbracelet/gum) 驱动）：

1. **Agents** — 选择要安装的智能体
2. **Skills** — 选择要安装的技能
3. **Commands** — 选择命令
4. **CLAUDE.md** — 复制基础 CLAUDE.md 并创建 AGENTS.md 符号链接
5. **MCP 服务器** — 选择并配置 MCP 服务器
6. **Git Hooks** — 选择要安装的 hooks（如果不是 git 仓库则提示执行 `git init`）

每一步都可以选择安装目标：
- **用户级** (`~/.claude/`) — 在所有项目中可用
- **项目级** (`.claude/`) — 仅在当前项目中可用

## 内容管理

```bash
./manage.sh
```

- **Add（添加）** — 扫描你的环境中的新 agents/skills/commands 并添加到仓库
- **Update（更新）** — 在 $EDITOR 中编辑现有内容
- **Remove（删除）** — 从仓库中移除内容
- **Sync（同步）** — 拉取最新变更并重新安装

## 非交互模式

```bash
./setup.sh --all --user      # 将所有内容安装到 ~/.claude/
./setup.sh --all --project   # 将所有内容安装到 .claude/
./setup.sh --dry-run         # 预览而不实际安装
```

## CLAUDE.md 架构

```
~/.claude/CLAUDE.md          ← 用户级（在所有项目中可用）
./CLAUDE.md                  ← 项目级（target=project 时由 setup.sh 复制）
./AGENTS.md → ./CLAUDE.md   ← 为 Cursor/OpenAI Agents 兼容性创建的符号链接
```

详见 [docs/CLAUDE-MD-GUIDE.md](docs/CLAUDE-MD-GUIDE.md) 编写指南。

## 文档

- [技能指南](docs/SKILLS.md) — 内置技能、外部技能、自定义技能
- [CLAUDE.md 指南](docs/CLAUDE-MD-GUIDE.md) — 如何编写高效的 CLAUDE.md 文件

## 依赖

- [gum](https://github.com/charmbracelet/gum) — 交互式 TUI（通过 brew 自动安装）
- [jq](https://jqlang.github.io/jq/) — JSON 处理（通过 brew 自动安装）

## 许可证

MIT
