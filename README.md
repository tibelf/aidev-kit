# ai_project_init

Claude Code best practices registry — agents, skills, commands, MCP servers, git hooks, and CLAUDE.md templates in one repo.

## Quick Start

```bash
# Clone and run setup
git clone https://github.com/tibelf/ai_project_init.git ~/.ai_project_init
cd ~/.ai_project_init
./setup.sh
```

Or run directly (clones to temp dir):

```bash
curl -fsSL https://raw.githubusercontent.com/tibelf/ai_project_init/main/setup.sh | bash
```

## What's Included

| Category | Count | Description |
|----------|-------|-------------|
| **Agents** | 13 | Specialized agents (frontend, backend, Python, TypeScript, code reviewer, etc.) |
| **Skills** | 6 bundled + 8 external | React best practices, web design, CLAUDE.md generator, and more |
| **Commands** | 5 | Refactor CLAUDE.md, worktree merge, Twitter automation |
| **MCP Servers** | 12 | filesystem, exa, rednote, browsermcp, rube, composio, chrome-devtools, etc. |
| **Git Hooks** | 3 | pre-commit (secrets), prepare-commit-msg (branch), post-checkout (CLAUDE.md) |
| **CLAUDE.md** | 1 | Universal base template for all projects |

## Interactive Setup

`setup.sh` provides a 6-step TUI wizard (powered by [gum](https://github.com/charmbracelet/gum)):

1. **Agents** — Select which agents to install
2. **Skills** — Select bundled + external skills
3. **Commands** — Select commands
4. **CLAUDE.md** — Copy base CLAUDE.md + create AGENTS.md symlink
5. **MCP Servers** — Select and configure MCP servers
6. **Git Hooks** — Select hooks to install

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
~/.claude/CLAUDE.md          ← Global base (from this repo)
./CLAUDE.md                  ← Project-specific (via generate-claude-md skill)
./AGENTS.md → ./CLAUDE.md   ← Symlink for Cursor compatibility
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
