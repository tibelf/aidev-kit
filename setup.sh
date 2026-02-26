#!/usr/bin/env bash
#
# ai_project_init -- Interactive TUI installer for Claude Code agents, skills,
# commands, MCP servers, and git hooks.
#
# Usage:
#   ./setup.sh                        # Interactive mode (requires gum)
#   ./setup.sh --all --user           # Install everything to ~/.claude/
#   ./setup.sh --all --project        # Install everything to ./.claude/
#   ./setup.sh --dry-run              # Show what would be done
#   ./setup.sh --all --user --dry-run # Combine flags
#
set -euo pipefail

# ── Resolve repo directory (support curl | bash mode) ───────────────────────
if [[ -z "${BASH_SOURCE[0]:-}" ]] || [[ "${BASH_SOURCE[0]}" == "/dev/stdin" ]] || [[ "${BASH_SOURCE[0]}" == "bash" ]]; then
  REPO_URL="https://github.com/tibelf/ai_project_init.git"
  TEMP_DIR=$(mktemp -d)
  trap "rm -rf $TEMP_DIR" EXIT
  echo "Cloning ai_project_init to temp directory..."
  git clone --depth 1 "$REPO_URL" "$TEMP_DIR" 2>/dev/null
  REPO_DIR="$TEMP_DIR"
else
  SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  REPO_DIR="$SCRIPT_PATH"
fi

# ── Defaults ─────────────────────────────────────────────────────────────────
DRY_RUN=false
ALL=false
TARGET=""            # "user" or "project"; empty = ask interactively
INTERACTIVE=true

# ── Parse arguments ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)      ALL=true; INTERACTIVE=false; shift ;;
        --user)     TARGET="user"; shift ;;
        --project)  TARGET="project"; shift ;;
        --dry-run)  DRY_RUN=true; shift ;;
        -h|--help)
            echo "Usage: $0 [--all] [--user|--project] [--dry-run]"
            echo ""
            echo "Flags:"
            echo "  --all       Install everything non-interactively"
            echo "  --user      Target ~/.claude/ (user level)"
            echo "  --project   Target ./.claude/ (project level)"
            echo "  --dry-run   Show what would be done without making changes"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

if [[ "$ALL" == true && -z "$TARGET" ]]; then
    echo "Error: --all requires --user or --project" >&2
    exit 1
fi

# ── Counters for summary ────────────────────────────────────────────────────
COUNT_ADDED=0
COUNT_UPDATED=0
COUNT_SKIPPED=0
COUNT_EXTERNAL=0
declare -a PLAN_LINES=()

# ── Dependency check / auto-install ─────────────────────────────────────────
ensure_deps() {
    local missing=()

    command -v gum  >/dev/null 2>&1 || missing+=(gum)
    command -v jq   >/dev/null 2>&1 || missing+=(jq)

    if [[ ${#missing[@]} -gt 0 ]]; then
        if [[ "$(uname -s)" == "Darwin" ]] && command -v brew >/dev/null 2>&1; then
            echo "Installing missing dependencies via Homebrew: ${missing[*]}"
            brew install "${missing[@]}"
        else
            echo "Error: missing required tools: ${missing[*]}" >&2
            echo "Install them manually (e.g. brew install ${missing[*]}) and re-run." >&2
            exit 1
        fi
    fi
}

ensure_deps

# ── Utility helpers ─────────────────────────────────────────────────────────

# Pretty-print section header
header() {
    if [[ "$INTERACTIVE" == true ]]; then
        gum style --foreground 212 --bold --border double --padding "0 2" "$1"
    else
        echo ""
        echo "=== $1 ==="
    fi
}

info()    { if [[ "$INTERACTIVE" == true ]]; then gum style --foreground 39  "  $1"; else echo "  $1"; fi; }
success() { if [[ "$INTERACTIVE" == true ]]; then gum style --foreground 76  "  $1"; else echo "  $1"; fi; }
warn()    { if [[ "$INTERACTIVE" == true ]]; then gum style --foreground 208 "  $1"; else echo "  $1"; fi; }

timestamp() { date +%Y%m%d%H%M%S; }

# Portable md5 (macOS uses md5, Linux uses md5sum)
file_md5() {
    if command -v md5sum >/dev/null 2>&1; then
        md5sum "$1" | awk '{print $1}'
    else
        md5 -q "$1"
    fi
}

# Extract description from a .md file's YAML frontmatter (field: description)
extract_description() {
    local file="$1"
    local desc=""
    # Try YAML frontmatter first (handles multi-line with |)
    if head -1 "$file" | grep -q '^---'; then
        # Single-line description
        desc="$(awk '/^---$/{n++; next} n==1 && /^description:/{
            sub(/^description:[[:space:]]*/, "");
            # Strip leading pipe for multiline
            if ($0 == "|" || $0 == ">") { getline; sub(/^[[:space:]]+/, ""); }
            print; exit
        }' "$file")"
    fi
    # Fallback to first non-empty, non-frontmatter line
    if [[ -z "$desc" ]]; then
        desc="$(awk '
            /^---$/ { in_fm = !in_fm; next }
            in_fm { next }
            /^#/ { next }
            /^[[:space:]]*$/ { next }
            { print; exit }
        ' "$file")"
    fi
    # Truncate for display
    if [[ ${#desc} -gt 80 ]]; then
        desc="${desc:0:77}..."
    fi
    echo "$desc"
}

# Extract name from a .md file's YAML frontmatter, falling back to filename
extract_name() {
    local file="$1"
    local name=""
    if head -1 "$file" | grep -q '^---'; then
        name="$(awk '/^---$/{n++; next} n==1 && /^name:/{sub(/^name:[[:space:]]*/, ""); print; exit}' "$file")"
    fi
    if [[ -z "$name" ]]; then
        name="$(basename "$file" .md)"
    fi
    echo "$name"
}

# Install a single file with checksum comparison.
# Usage: install_file <source> <dest_dir> [<dest_filename>]
# Respects DRY_RUN. Updates counters.
install_file() {
    local src="$1"
    local dest_dir="$2"
    local dest_name="${3:-$(basename "$src")}"
    local dest="$dest_dir/$dest_name"

    if [[ "$DRY_RUN" == true ]]; then
        if [[ -f "$dest" ]]; then
            local src_md5 dest_md5
            src_md5="$(file_md5 "$src")"
            dest_md5="$(file_md5 "$dest")"
            if [[ "$src_md5" == "$dest_md5" ]]; then
                PLAN_LINES+=("skip (unchanged): $dest_name")
                (( COUNT_SKIPPED++ )) || true
            else
                PLAN_LINES+=("update: $dest_name -> $dest")
                (( COUNT_UPDATED++ )) || true
            fi
        else
            PLAN_LINES+=("add: $dest_name -> $dest")
            (( COUNT_ADDED++ )) || true
        fi
        return
    fi

    mkdir -p "$dest_dir"

    if [[ -f "$dest" ]]; then
        local src_md5 dest_md5
        src_md5="$(file_md5 "$src")"
        dest_md5="$(file_md5 "$dest")"
        if [[ "$src_md5" == "$dest_md5" ]]; then
            success "✓ unchanged: $dest_name"
            (( COUNT_SKIPPED++ )) || true
            return
        fi
        # Backup existing before overwriting
        cp "$dest" "${dest}.bak.$(timestamp)"
        cp "$src" "$dest"
        warn "↑ updated: $dest_name"
        (( COUNT_UPDATED++ )) || true
    else
        cp "$src" "$dest"
        success "+ added: $dest_name"
        (( COUNT_ADDED++ )) || true
    fi
}

# Recursively install a directory tree (preserving structure).
install_dir() {
    local src_dir="$1"
    local dest_dir="$2"

    while IFS= read -r -d '' file; do
        local rel="${file#"$src_dir"/}"
        local reldir
        reldir="$(dirname "$rel")"
        local target_subdir
        if [[ "$reldir" == "." ]]; then
            target_subdir="$dest_dir"
        else
            target_subdir="$dest_dir/$reldir"
        fi
        install_file "$file" "$target_subdir" "$(basename "$file")"
    done < <(find "$src_dir" -type f -print0)
}

# Resolve target base directory from a target name ("user" or "project")
resolve_target() {
    local kind="$1"    # "agents", "skills", "commands"
    local target="$2"  # "user" or "project"
    if [[ "$target" == "user" ]]; then
        echo "$HOME/.claude/$kind"
    else
        echo "./.claude/$kind"
    fi
}

# Ask the user for install target; returns "user" or "project"
ask_target() {
    local label="${1:-items}"
    if [[ "$INTERACTIVE" == false ]]; then
        echo "$TARGET"
        return
    fi
    local choice
    choice="$(gum choose --header "Install $label to:" \
        "User (~/.claude/)" \
        "Project (.claude/)")"
    case "$choice" in
        *User*)    echo "user" ;;
        *Project*) echo "project" ;;
    esac
}

# ── Step 1: Agents ──────────────────────────────────────────────────────────
step_agents() {
    header "Step 1/6 ─ Agents"

    local agents_dir="$REPO_DIR/agents"
    if [[ ! -d "$agents_dir" ]]; then
        warn "No agents/ directory found. Skipping."
        return
    fi

    # Collect agent files
    local -a agent_files=()
    local -a display_labels=()
    while IFS= read -r -d '' f; do
        agent_files+=("$f")
        local name desc rel_path
        name="$(extract_name "$f")"
        desc="$(extract_description "$f")"
        # Show category from subdirectory
        rel_path="${f#"$agents_dir"/}"
        local category
        category="$(dirname "$rel_path")"
        if [[ "$category" == "." ]]; then
            display_labels+=("$name -- $desc")
        else
            display_labels+=("[$category] $name -- $desc")
        fi
    done < <(find "$agents_dir" -name '*.md' -type f -print0 | sort -z)

    if [[ ${#agent_files[@]} -eq 0 ]]; then
        warn "No agent .md files found. Skipping."
        return
    fi

    # Select agents
    local -a selected_labels=()
    if [[ "$INTERACTIVE" == true ]]; then
        local choices
        choices="$(printf '%s\n' "${display_labels[@]}" | gum choose --no-limit --header "Select agents to install:")"
        if [[ -z "$choices" ]]; then
            info "No agents selected."
            return
        fi
        while IFS= read -r line; do
            selected_labels+=("$line")
        done <<< "$choices"
    else
        selected_labels=("${display_labels[@]}")
    fi

    local target
    target="$(ask_target "agents")"
    local target_dir
    target_dir="$(resolve_target "agents" "$target")"

    # Install selected
    for label in "${selected_labels[@]}"; do
        # Find matching file
        for i in "${!display_labels[@]}"; do
            if [[ "${display_labels[$i]}" == "$label" ]]; then
                local src="${agent_files[$i]}"
                local rel="${src#"$agents_dir"/}"
                local sub_dir="$target_dir/$(dirname "$rel")"
                install_file "$src" "$sub_dir" "$(basename "$src")"
                break
            fi
        done
    done
}

# ── Step 2: Skills ──────────────────────────────────────────────────────────
step_skills() {
    header "Step 2/6 ─ Skills"

    local skills_dir="$REPO_DIR/skills"
    local external_json="$REPO_DIR/skills-external.json"

    local -a skill_ids=()       # Internal identifier (dirname or external name)
    local -a skill_labels=()    # Display labels
    local -a skill_types=()     # "bundled" or "external"
    local -a skill_paths=()     # For bundled: dir path. For external: install cmd

    # Bundled skills (directories containing SKILL.md)
    if [[ -d "$skills_dir" ]]; then
        for dir in "$skills_dir"/*/; do
            [[ -d "$dir" ]] || continue
            local skill_md="$dir/SKILL.md"
            local dirname
            dirname="$(basename "$dir")"
            local name="$dirname"
            local desc=""
            if [[ -f "$skill_md" ]]; then
                name="$(extract_name "$skill_md")"
                desc="$(extract_description "$skill_md")"
            fi
            skill_ids+=("$dirname")
            skill_labels+=("$name -- $desc")
            skill_types+=("bundled")
            skill_paths+=("$dir")
        done
    fi

    # External skills
    if [[ -f "$external_json" ]]; then
        local count
        count="$(jq 'length' "$external_json")"
        for (( i=0; i<count; i++ )); do
            local name desc install_cmd
            name="$(jq -r ".[$i].name" "$external_json")"
            desc="$(jq -r ".[$i].description" "$external_json")"
            install_cmd="$(jq -r ".[$i].install" "$external_json")"
            skill_ids+=("$name")
            skill_labels+=("$name -- $desc (external)")
            skill_types+=("external")
            skill_paths+=("$install_cmd")
        done
    fi

    if [[ ${#skill_ids[@]} -eq 0 ]]; then
        warn "No skills found. Skipping."
        return
    fi

    # Select skills
    local -a selected_labels=()
    if [[ "$INTERACTIVE" == true ]]; then
        local choices
        choices="$(printf '%s\n' "${skill_labels[@]}" | gum choose --no-limit --header "Select skills to install:")"
        if [[ -z "$choices" ]]; then
            info "No skills selected."
            return
        fi
        while IFS= read -r line; do
            selected_labels+=("$line")
        done <<< "$choices"
    else
        selected_labels=("${skill_labels[@]}")
    fi

    # Ask target only for bundled skills
    local has_bundled=false
    for label in "${selected_labels[@]}"; do
        for i in "${!skill_labels[@]}"; do
            if [[ "${skill_labels[$i]}" == "$label" && "${skill_types[$i]}" == "bundled" ]]; then
                has_bundled=true
                break 2
            fi
        done
    done

    local target=""
    if [[ "$has_bundled" == true ]]; then
        target="$(ask_target "skills")"
    fi

    # Install selected
    for label in "${selected_labels[@]}"; do
        for i in "${!skill_labels[@]}"; do
            if [[ "${skill_labels[$i]}" == "$label" ]]; then
                if [[ "${skill_types[$i]}" == "bundled" ]]; then
                    local target_dir
                    target_dir="$(resolve_target "skills" "$target")/${skill_ids[$i]}"
                    install_dir "${skill_paths[$i]%/}" "$target_dir"
                else
                    # External skill
                    local cmd="${skill_paths[$i]}"
                    if [[ "$DRY_RUN" == true ]]; then
                        PLAN_LINES+=("external: $cmd")
                        (( COUNT_EXTERNAL++ )) || true
                    else
                        info "Installing external skill: ${skill_ids[$i]}"
                        if eval "$cmd"; then
                            success "+ external: ${skill_ids[$i]}"
                        else
                            warn "! failed: ${skill_ids[$i]} (you can install manually with: $cmd)"
                        fi
                        (( COUNT_EXTERNAL++ )) || true
                    fi
                fi
                break
            fi
        done
    done
}

# ── Step 3: Commands ────────────────────────────────────────────────────────
step_commands() {
    header "Step 3/6 ─ Commands"

    local commands_dir="$REPO_DIR/commands"
    if [[ ! -d "$commands_dir" ]]; then
        warn "No commands/ directory found. Skipping."
        return
    fi

    local -a cmd_files=()
    local -a cmd_labels=()
    for f in "$commands_dir"/*.md; do
        [[ -f "$f" ]] || continue
        local name desc
        name="$(basename "$f" .md)"
        desc="$(extract_description "$f")"
        cmd_files+=("$f")
        cmd_labels+=("$name -- $desc")
    done

    if [[ ${#cmd_files[@]} -eq 0 ]]; then
        warn "No command .md files found. Skipping."
        return
    fi

    local -a selected_labels=()
    if [[ "$INTERACTIVE" == true ]]; then
        local choices
        choices="$(printf '%s\n' "${cmd_labels[@]}" | gum choose --no-limit --header "Select commands to install:")"
        if [[ -z "$choices" ]]; then
            info "No commands selected."
            return
        fi
        while IFS= read -r line; do
            selected_labels+=("$line")
        done <<< "$choices"
    else
        selected_labels=("${cmd_labels[@]}")
    fi

    local target
    target="$(ask_target "commands")"
    local target_dir
    target_dir="$(resolve_target "commands" "$target")"

    for label in "${selected_labels[@]}"; do
        for i in "${!cmd_labels[@]}"; do
            if [[ "${cmd_labels[$i]}" == "$label" ]]; then
                install_file "${cmd_files[$i]}" "$target_dir"
                break
            fi
        done
    done
}

# ── Step 4: CLAUDE.md & AGENTS.md ──────────────────────────────────────────
step_claude_md() {
    header "Step 4/6 ─ CLAUDE.md & AGENTS.md"

    local repo_claude_md="$REPO_DIR/CLAUDE.md"
    local user_claude_md="$HOME/.claude/CLAUDE.md"

    # --- CLAUDE.md ---
    if [[ -f "$repo_claude_md" ]]; then
        if [[ ! -f "$user_claude_md" ]] || [[ ! -s "$user_claude_md" ]]; then
            # Missing or empty -> copy
            if [[ "$DRY_RUN" == true ]]; then
                PLAN_LINES+=("add: CLAUDE.md -> $user_claude_md")
                (( COUNT_ADDED++ )) || true
            else
                mkdir -p "$(dirname "$user_claude_md")"
                cp "$repo_claude_md" "$user_claude_md"
                success "+ added: ~/.claude/CLAUDE.md"
                (( COUNT_ADDED++ )) || true
            fi
        else
            # Has content -> ask
            if [[ "$INTERACTIVE" == true ]]; then
                local action
                action="$(gum choose --header "~/.claude/CLAUDE.md already exists:" \
                    "Replace (backup existing)" \
                    "Keep existing" \
                    "Skip")"
                case "$action" in
                    Replace*)
                        if [[ "$DRY_RUN" != true ]]; then
                            cp "$user_claude_md" "${user_claude_md}.bak.$(timestamp)"
                            cp "$repo_claude_md" "$user_claude_md"
                            warn "↑ replaced: ~/.claude/CLAUDE.md (backup created)"
                            (( COUNT_UPDATED++ )) || true
                        else
                            PLAN_LINES+=("replace: CLAUDE.md -> $user_claude_md")
                            (( COUNT_UPDATED++ )) || true
                        fi
                        ;;
                    Keep*)
                        info "Keeping existing ~/.claude/CLAUDE.md"
                        (( COUNT_SKIPPED++ )) || true
                        ;;
                    Skip*)
                        info "Skipped CLAUDE.md"
                        (( COUNT_SKIPPED++ )) || true
                        ;;
                esac
            else
                info "~/.claude/CLAUDE.md exists; skipping in non-interactive mode."
                (( COUNT_SKIPPED++ )) || true
            fi
        fi
    else
        info "No CLAUDE.md in repo root. Skipping."
    fi

    # --- AGENTS.md symlink ---
    local agents_md="./AGENTS.md"
    local claude_md="./CLAUDE.md"

    if [[ -L "$agents_md" ]]; then
        info "AGENTS.md is already a symlink. Skipping."
        (( COUNT_SKIPPED++ )) || true
    elif [[ -f "$agents_md" ]]; then
        # Regular file exists
        if [[ "$INTERACTIVE" == true ]]; then
            local action
            action="$(gum choose --header "AGENTS.md exists as a regular file:" \
                "Convert to symlink -> CLAUDE.md (backup original)" \
                "Keep as-is" \
                "Skip")"
            case "$action" in
                Convert*)
                    if [[ "$DRY_RUN" != true ]]; then
                        cp "$agents_md" "${agents_md}.bak.$(timestamp)"
                        rm "$agents_md"
                        ln -s "CLAUDE.md" "$agents_md"
                        warn "↑ converted: AGENTS.md -> symlink to CLAUDE.md (backup created)"
                        (( COUNT_UPDATED++ )) || true
                    else
                        PLAN_LINES+=("convert: AGENTS.md -> symlink to CLAUDE.md")
                        (( COUNT_UPDATED++ )) || true
                    fi
                    ;;
                *)
                    info "Keeping AGENTS.md as-is."
                    (( COUNT_SKIPPED++ )) || true
                    ;;
            esac
        else
            info "AGENTS.md exists as regular file; skipping in non-interactive mode."
            (( COUNT_SKIPPED++ )) || true
        fi
    else
        # Does not exist
        if [[ "$INTERACTIVE" == true ]]; then
            local action
            action="$(gum choose --header "AGENTS.md does not exist in current directory:" \
                "Create symlink AGENTS.md -> CLAUDE.md" \
                "Skip")"
            case "$action" in
                Create*)
                    if [[ "$DRY_RUN" != true ]]; then
                        ln -s "CLAUDE.md" "$agents_md"
                        success "+ created: AGENTS.md -> CLAUDE.md"
                        (( COUNT_ADDED++ )) || true
                    else
                        PLAN_LINES+=("add: symlink AGENTS.md -> CLAUDE.md")
                        (( COUNT_ADDED++ )) || true
                    fi
                    ;;
                *)
                    info "Skipped AGENTS.md."
                    (( COUNT_SKIPPED++ )) || true
                    ;;
            esac
        else
            info "AGENTS.md does not exist; skipping in non-interactive mode."
            (( COUNT_SKIPPED++ )) || true
        fi
    fi
}

# ── Step 5: MCP Servers ────────────────────────────────────────────────────
step_mcp_servers() {
    header "Step 5/6 ─ MCP Servers"

    local mcp_dir="$REPO_DIR/mcp-servers"
    if [[ ! -d "$mcp_dir" ]]; then
        warn "No mcp-servers/ directory found. Skipping."
        return
    fi

    local -a mcp_files=()
    local -a mcp_labels=()
    local -a mcp_names=()
    for f in "$mcp_dir"/*.json; do
        [[ -f "$f" ]] || continue
        local name desc
        name="$(jq -r '.name // empty' "$f")"
        desc="$(jq -r '.description // empty' "$f")"
        [[ -z "$name" ]] && name="$(basename "$f" .json)"
        mcp_files+=("$f")
        mcp_names+=("$name")
        mcp_labels+=("$name -- $desc")
    done

    if [[ ${#mcp_files[@]} -eq 0 ]]; then
        warn "No MCP server configs found. Skipping."
        return
    fi

    # Select servers
    local -a selected_labels=()
    if [[ "$INTERACTIVE" == true ]]; then
        local choices
        choices="$(printf '%s\n' "${mcp_labels[@]}" | gum choose --no-limit --header "Select MCP servers to configure:")"
        if [[ -z "$choices" ]]; then
            info "No MCP servers selected."
            return
        fi
        while IFS= read -r line; do
            selected_labels+=("$line")
        done <<< "$choices"
    else
        selected_labels=("${mcp_labels[@]}")
    fi

    # Ask target
    local mcp_target
    if [[ "$INTERACTIVE" == true ]]; then
        local choice
        choice="$(gum choose --header "Install MCP servers to:" \
            "Global (~/.claude/settings.json)" \
            "Project (.mcp.json)")"
        case "$choice" in
            *Global*) mcp_target="global" ;;
            *)        mcp_target="project" ;;
        esac
    else
        if [[ "$TARGET" == "user" ]]; then
            mcp_target="global"
        else
            mcp_target="project"
        fi
    fi

    local target_file
    if [[ "$mcp_target" == "global" ]]; then
        target_file="$HOME/.claude/settings.json"
    else
        target_file="./.mcp.json"
    fi

    # Process each selected server
    for label in "${selected_labels[@]}"; do
        for i in "${!mcp_labels[@]}"; do
            if [[ "${mcp_labels[$i]}" == "$label" ]]; then
                local src="${mcp_files[$i]}"
                local srv_name="${mcp_names[$i]}"

                # Read the config template
                local config
                config="$(jq '.config' "$src")"

                # Collect prompt values
                local has_prompts
                has_prompts="$(jq 'has("prompts") and (.prompts | length > 0)' "$src")"

                if [[ "$has_prompts" == "true" ]]; then
                    local prompt_count
                    prompt_count="$(jq '.prompts | length' "$src")"

                    for (( p=0; p<prompt_count; p++ )); do
                        local var msg default_val sensitive
                        var="$(jq -r ".prompts[$p].var" "$src")"
                        msg="$(jq -r ".prompts[$p].message" "$src")"
                        default_val="$(jq -r ".prompts[$p].default // empty" "$src")"
                        sensitive="$(jq -r ".prompts[$p].sensitive // false" "$src")"

                        local value=""
                        if [[ "$INTERACTIVE" == true ]]; then
                            local gum_args=("--header" "$msg")
                            [[ -n "$default_val" ]] && gum_args+=("--value" "$default_val")
                            [[ "$sensitive" == "true" ]] && gum_args+=("--password")
                            value="$(gum input "${gum_args[@]}")"
                        else
                            value="$default_val"
                        fi

                        # Check if this is a PATHS-type variable (contains commas or var name contains PATH)
                        if [[ "$var" == *PATH* || "$var" == *PATHS* ]] && [[ "$value" == *","* ]]; then
                            # Split by comma, expand ~, build JSON array for args
                            local expanded_args="["
                            local first=true
                            IFS=',' read -ra path_parts <<< "$value"
                            for part in "${path_parts[@]}"; do
                                part="$(echo "$part" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
                                part="${part/#\~/$HOME}"
                                if [[ "$first" == true ]]; then
                                    expanded_args+="\"$part\""
                                    first=false
                                else
                                    expanded_args+=",\"$part\""
                                fi
                            done
                            expanded_args+="]"
                            # Replace the ${VAR} placeholder with array in config
                            config="$(echo "$config" | jq --argjson paths "$expanded_args" \
                                'walk(if type == "string" and test("\\$\\{'"$var"'\\}") then $paths else . end)')"
                        else
                            # Expand ~ in value
                            value="${value/#\~/$HOME}"
                            # Simple string replacement of ${VAR}
                            config="$(echo "$config" | jq --arg val "$value" --arg var "\${$var}" \
                                'walk(if type == "string" then gsub($var; $val) else . end)')"
                        fi
                    done
                fi

                # Merge into target file
                if [[ "$DRY_RUN" == true ]]; then
                    PLAN_LINES+=("mcp: $srv_name -> $target_file")
                    (( COUNT_ADDED++ )) || true
                else
                    # Ensure target file exists with valid JSON
                    if [[ ! -f "$target_file" ]]; then
                        mkdir -p "$(dirname "$target_file")"
                        echo '{}' > "$target_file"
                    fi

                    if [[ "$mcp_target" == "global" ]]; then
                        # settings.json uses "mcpServers" key
                        local updated
                        updated="$(jq --arg name "$srv_name" --argjson cfg "$config" \
                            '.mcpServers[$name] = $cfg' "$target_file")"
                        echo "$updated" > "$target_file"
                    else
                        # .mcp.json uses "mcpServers" key as well
                        local updated
                        updated="$(jq --arg name "$srv_name" --argjson cfg "$config" \
                            '.mcpServers[$name] = $cfg' "$target_file")"
                        echo "$updated" > "$target_file"
                    fi
                    success "+ mcp: $srv_name -> $target_file"
                    (( COUNT_ADDED++ )) || true
                fi
                break
            fi
        done
    done
}

# ── Step 6: Git Hooks ──────────────────────────────────────────────────────
step_git_hooks() {
    header "Step 6/6 ─ Git Hooks"

    local hooks_dir="$REPO_DIR/git-hooks"
    if [[ ! -d "$hooks_dir" ]]; then
        warn "No git-hooks/ directory found. Skipping."
        return
    fi

    # Check we are in a git repo
    if [[ ! -d ".git/hooks" ]]; then
        warn "Not inside a git repository (no .git/hooks). Skipping git hooks."
        return
    fi

    local -a hook_files=()
    local -a hook_names=()
    for f in "$hooks_dir"/*; do
        [[ -f "$f" ]] || continue
        local name
        name="$(basename "$f")"
        # Skip hidden files, .sample files, etc.
        [[ "$name" == .* ]] && continue
        [[ "$name" == *.sample ]] && continue
        hook_files+=("$f")
        hook_names+=("$name")
    done

    if [[ ${#hook_files[@]} -eq 0 ]]; then
        warn "No hook files found. Skipping."
        return
    fi

    local -a selected_names=()
    if [[ "$INTERACTIVE" == true ]]; then
        local choices
        choices="$(printf '%s\n' "${hook_names[@]}" | gum choose --no-limit --header "Select git hooks to install:")"
        if [[ -z "$choices" ]]; then
            info "No hooks selected."
            return
        fi
        while IFS= read -r line; do
            selected_names+=("$line")
        done <<< "$choices"
    else
        selected_names=("${hook_names[@]}")
    fi

    for name in "${selected_names[@]}"; do
        for i in "${!hook_names[@]}"; do
            if [[ "${hook_names[$i]}" == "$name" ]]; then
                local src="${hook_files[$i]}"
                local dest=".git/hooks/$name"

                if [[ "$DRY_RUN" == true ]]; then
                    if [[ -f "$dest" && ! "$dest" == *.sample ]]; then
                        PLAN_LINES+=("hook (alongside): ${name}.ai_project_init -> .git/hooks/")
                    else
                        PLAN_LINES+=("hook: $name -> .git/hooks/")
                    fi
                    (( COUNT_ADDED++ )) || true
                else
                    if [[ -f "$dest" && "$(basename "$dest")" != *.sample ]]; then
                        # Existing hook (not a .sample) -- install alongside
                        local alt_dest=".git/hooks/${name}.ai_project_init"
                        cp "$src" "$alt_dest"
                        chmod +x "$alt_dest"
                        warn "↑ hook installed alongside existing: ${name}.ai_project_init"
                        (( COUNT_ADDED++ )) || true
                    else
                        cp "$src" "$dest"
                        chmod +x "$dest"
                        success "+ hook: $name"
                        (( COUNT_ADDED++ )) || true
                    fi
                fi
                break
            fi
        done
    done
}

# ── Summary & Confirmation ──────────────────────────────────────────────────
show_summary() {
    local total=$(( COUNT_ADDED + COUNT_UPDATED + COUNT_SKIPPED + COUNT_EXTERNAL ))

    if [[ "$DRY_RUN" == true ]]; then
        header "Dry Run Summary"
        if [[ ${#PLAN_LINES[@]} -gt 0 ]]; then
            for line in "${PLAN_LINES[@]}"; do
                info "$line"
            done
        fi
        echo ""
        info "Would add: $COUNT_ADDED | update: $COUNT_UPDATED | skip: $COUNT_SKIPPED | external: $COUNT_EXTERNAL"
        info "Total items: $total"
        echo ""
        info "Run without --dry-run to apply changes."
        return
    fi

    if [[ "$INTERACTIVE" == true ]]; then
        echo ""
        gum style --foreground 76 --bold --border rounded --padding "0 2" \
            "Installation Complete" \
            "" \
            "  + Added:     $COUNT_ADDED" \
            "  ↑ Updated:   $COUNT_UPDATED" \
            "  ✓ Unchanged: $COUNT_SKIPPED" \
            "  ⬡ External:  $COUNT_EXTERNAL" \
            "" \
            "  Total: $total"
    else
        echo ""
        echo "=== Installation Complete ==="
        echo "  Added:     $COUNT_ADDED"
        echo "  Updated:   $COUNT_UPDATED"
        echo "  Unchanged: $COUNT_SKIPPED"
        echo "  External:  $COUNT_EXTERNAL"
        echo "  Total:     $total"
    fi
}

# ── Confirmation gate (interactive only) ────────────────────────────────────
# In dry-run mode we run all steps to collect the plan, then display.
# In interactive mode, we collect selections first, then confirm.
# In non-interactive --all mode, we just run.

# ── Main ────────────────────────────────────────────────────────────────────
main() {
    if [[ "$INTERACTIVE" == true ]]; then
        gum style --foreground 212 --bold --border double --padding "1 3" \
            "ai_project_init" \
            "Interactive installer for Claude Code"
        echo ""
    fi

    step_agents
    step_skills
    step_commands
    step_claude_md
    step_mcp_servers
    step_git_hooks

    show_summary

    if [[ "$DRY_RUN" == true ]]; then
        exit 0
    fi

    # Final confirmation is implicit -- we install as we go per step.
    # If the user wants a pre-flight check they can use --dry-run.
    echo ""
    if [[ "$INTERACTIVE" == true ]]; then
        gum style --foreground 39 "Done! Your Claude Code environment is ready."
    else
        echo "Done! Your Claude Code environment is ready."
    fi
}

main
