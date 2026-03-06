# aidev_kit

[中文](README.zh-CN.md)

Claude Code best practices registry — agents, skills, commands, MCP servers, git hooks, and CLAUDE.md templates in one repo.

## Quick Start

```bash
# Clone and run setup
git clone https://github.com/tibelf/aidev_kit.git ~/.aidev_kit
cd ~/.aidev_kit
./setup.sh
```

Or run directly (clones to temp dir):

```bash
curl -fsSL https://raw.githubusercontent.com/tibelf/aidev_kit/main/setup.sh | bash
```

## What's Included

| Category | Count | Description |
|----------|-------|-------------|
| **Agents** | 13 | Specialized agents (frontend, backend, Python, TypeScript, code reviewer, etc.) |
| **Skills** | 11 | React best practices, web design, CLAUDE.md generator, browser automation, SEO audit, and more |
| **Commands** | 5 | Refactor CLAUDE.md, worktree merge, Twitter automation |
| **MCP Servers** | 12 | filesystem, exa, rednote, browsermcp, rube, composio, chrome-devtools, etc. |
| **Git Hooks** | 1 | post-commit (auto-update docs via Claude after code changes) |
| **CLAUDE.md** | 1 | Universal base template for all projects |

## Interactive Setup

`setup.sh` provides a 6-step TUI wizard (powered by [gum](https://github.com/charmbracelet/gum)):

1. **Agents** — Select which agents to install
2. **Skills** — Select skills to install
3. **Commands** — Select commands
4. **CLAUDE.md** — Copy base CLAUDE.md + create AGENTS.md symlink
5. **MCP Servers** — Select and configure MCP servers
6. **Git Hooks** — Select hooks to install (offers `git init` if not a git repo)

Each step lets you choose the install target:
- **User** (`~/.claude/`) — available in all projects
- **Project** (`.claude/`) — only the current project

## Content Management

```bash
./manage.sh
```

- **Add** — Scan your environment for new agents/skills/commands, add to repo
- **Update** — Edit existing content in $EDITOR
- **Remove** — Remove content from repo
- **Sync** — Pull latest changes and re-install

## Non-Interactive Mode

```bash
./setup.sh --all --user      # Install everything to ~/.claude/
./setup.sh --all --project   # Install everything to .claude/
./setup.sh --dry-run         # Preview without installing
```

## CLAUDE.md Architecture

```
~/.claude/CLAUDE.md          ← User-level (available in all projects)
./CLAUDE.md                  ← Project-level (setup.sh copies here when target=project)
./AGENTS.md → ./CLAUDE.md   ← Symlink for Cursor/OpenAI Agents compatibility
```

See [docs/CLAUDE-MD-GUIDE.md](docs/CLAUDE-MD-GUIDE.md) for writing guidelines.

## Documentation

- [Skills Guide](docs/SKILLS.md) — Bundled skills, external skills, creating your own
- [CLAUDE.md Guide](docs/CLAUDE-MD-GUIDE.md) — How to write effective CLAUDE.md files

## Dependencies

- [gum](https://github.com/charmbracelet/gum) — Interactive TUI (auto-installed via brew)
- [jq](https://jqlang.github.io/jq/) — JSON processing (auto-installed via brew)

## License

MIT
