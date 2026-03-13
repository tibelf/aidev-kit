#!/usr/bin/env bash
set -e

###############################################################################
# manage.sh - Content management for ai_project_init
#
# Provides bidirectional sync between user's environment and this repo.
# Uses gum TUI for interactive menus.
#
# Usage:
#   ./manage.sh                  Interactive main menu
#   ./manage.sh --paths "~/a,~/b"  Pre-set scan paths for Add flow
###############################################################################

# --- Resolve repo directory from script location ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$SCRIPT_DIR"
CLAUDE_HOME="${HOME}/.claude"
GLOBAL_SETTINGS="${CLAUDE_HOME}/settings.json"

# --- Parse arguments ---
ARG_PATHS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --paths)
      ARG_PATHS="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

###############################################################################
# Dependencies
###############################################################################

ensure_deps() {
  local missing=()
  command -v gum  >/dev/null 2>&1 || missing+=(gum)
  command -v jq   >/dev/null 2>&1 || missing+=(jq)

  if [[ ${#missing[@]} -gt 0 ]]; then
    if [[ "$(uname)" == "Darwin" ]] && command -v brew >/dev/null 2>&1; then
      echo "Installing missing dependencies: ${missing[*]} ..."
      brew install "${missing[@]}"
    else
      echo "Error: missing dependencies: ${missing[*]}"
      echo "Please install them manually (e.g. brew install ${missing[*]})"
      exit 1
    fi
  fi
}

###############################################################################
# Helpers
###############################################################################

heading() {
  gum style --bold --foreground 212 "$1"
}

info() {
  gum style --foreground 114 "$1"
}

warn() {
  gum style --foreground 214 "$1"
}

err() {
  gum style --foreground 196 "$1"
}

# Compute MD5 checksum (portable macOS / Linux)
file_checksum() {
  local path="$1"
  if [[ -d "$path" ]]; then
    # For directories, hash the concatenation of all file contents
    find "$path" -type f -print0 | sort -z | xargs -0 cat 2>/dev/null | md5sum 2>/dev/null | awk '{print $1}' \
      || find "$path" -type f -print0 | sort -z | xargs -0 cat 2>/dev/null | md5 -q 2>/dev/null || echo "none"
  else
    md5sum "$path" 2>/dev/null | awk '{print $1}' \
      || md5 -q "$path" 2>/dev/null || echo "none"
  fi
}

# Expand a tilde path to absolute
expand_path() {
  local p="$1"
  p="${p/#\~/$HOME}"
  echo "$p"
}

# Get the basename without extension for .md files
name_of() {
  basename "$1" .md
}

###############################################################################
# Add Flow
###############################################################################

flow_add() {
  heading "== Add: detect new content from environment =="

  # 1. Ask for scan paths
  local default_paths="~/Github, ~/Gitee, ~/Desktop"
  local raw_paths
  if [[ -n "$ARG_PATHS" ]]; then
    raw_paths="$ARG_PATHS"
  else
    raw_paths=$(gum input --placeholder "$default_paths" \
      --prompt "Scan paths (comma-separated): " \
      --value "$default_paths")
  fi

  # Parse comma-separated paths into array
  IFS=',' read -ra path_tokens <<< "$raw_paths"
  local scan_paths=()
  for p in "${path_tokens[@]}"; do
    p="$(expand_path "$(echo "$p" | xargs)")"  # trim + expand ~
    [[ -d "$p" ]] && scan_paths+=("$p")
  done

  if [[ ${#scan_paths[@]} -eq 0 ]]; then
    warn "No valid scan paths found."
    return
  fi

  info "Scanning paths: ${scan_paths[*]}"

  # -------------------------------------------------------------------
  # Collect items.  Each item stored as a line:
  #   STATUS|CATEGORY|NAME|SOURCE_PATH|SCOPE
  # STATUS: new, modified
  # SCOPE: global, project:<dir>
  # -------------------------------------------------------------------
  local items=()

  # Track names seen across projects for shared detection
  # (using eval-based indirect variables for Bash 3.2 compatibility)

  # ---- Helper: compare a set of env files against repo counterparts ----

  # compare_agents  ENV_GLOB  REPO_BASE  SCOPE
  compare_agents() {
    local env_base="$1" repo_base="$2" scope="$3"
    # env_base is e.g. ~/.claude/agents  — scan for **/*.md
    if [[ ! -d "$env_base" ]]; then return; fi
    while IFS= read -r -d '' env_file; do
      # Preserve subdirectory category structure
      local rel="${env_file#"$env_base"/}"
      local agent_name
      agent_name="$(name_of "$rel")"
      local repo_file="${repo_base}/${rel}"

      local key="agent:${agent_name}"
      local _safe_key="_npc_${key//[^a-zA-Z0-9_]/_}"
      eval "${_safe_key}=\$(( \${${_safe_key}:-0} + 1 ))"

      if [[ ! -f "$repo_file" ]]; then
        items+=("new|Agent|${rel%.md}|${env_file}|${scope}")
      else
        local cs_env cs_repo
        cs_env="$(file_checksum "$env_file")"
        cs_repo="$(file_checksum "$repo_file")"
        if [[ "$cs_env" != "$cs_repo" ]]; then
          items+=("modified|Agent|${rel%.md}|${env_file}|${scope}")
        fi
      fi
    done < <(find "$env_base" -name '*.md' -type f -print0 2>/dev/null)
  }

  compare_skills() {
    local env_base="$1" repo_base="$2" scope="$3"
    if [[ ! -d "$env_base" ]]; then return; fi
    for entry in "$env_base"/*/; do
      [[ -d "$entry" ]] || continue
      local sname
      sname="$(basename "$entry")"

      local key="skill:${sname}"
      local _safe_key="_npc_${key//[^a-zA-Z0-9_]/_}"
      eval "${_safe_key}=\$(( \${${_safe_key}:-0} + 1 ))"

      if [[ ! -d "${repo_base}/${sname}" ]]; then
        items+=("new|Skill|${sname}|${entry%/}|${scope}")
      else
        local cs_env cs_repo
        cs_env="$(file_checksum "$entry")"
        cs_repo="$(file_checksum "${repo_base}/${sname}")"
        if [[ "$cs_env" != "$cs_repo" ]]; then
          items+=("modified|Skill|${sname}|${entry%/}|${scope}")
        fi
      fi
    done
  }

  # compare_commands  ENV_BASE  REPO_CMDS  SCOPE
  compare_commands() {
    local env_base="$1" repo_base="$2" scope="$3"
    if [[ ! -d "$env_base" ]]; then return; fi
    for cmd_file in "$env_base"/*.md; do
      [[ -f "$cmd_file" ]] || continue
      local cname
      cname="$(name_of "$cmd_file")"

      local key="command:${cname}"
      local _safe_key="_npc_${key//[^a-zA-Z0-9_]/_}"
      eval "${_safe_key}=\$(( \${${_safe_key}:-0} + 1 ))"

      if [[ ! -f "${repo_base}/${cname}.md" ]]; then
        items+=("new|Command|${cname}|${cmd_file}|${scope}")
      else
        local cs_env cs_repo
        cs_env="$(file_checksum "$cmd_file")"
        cs_repo="$(file_checksum "${repo_base}/${cname}.md")"
        if [[ "$cs_env" != "$cs_repo" ]]; then
          items+=("modified|Command|${cname}|${cmd_file}|${scope}")
        fi
      fi
    done
  }

  # compare_mcp_servers  SETTINGS_FILE  SCOPE
  compare_mcp_servers() {
    local settings="$1" scope="$2"
    [[ -f "$settings" ]] || return
    # Extract mcpServers keys
    local keys
    keys=$(jq -r '.mcpServers // {} | keys[]' "$settings" 2>/dev/null || true)
    [[ -z "$keys" ]] && return
    while IFS= read -r srvname; do
      [[ -z "$srvname" ]] && continue
      if [[ ! -f "${REPO_DIR}/mcp-servers/${srvname}.json" ]]; then
        items+=("new|MCP Server|${srvname}|${settings}|${scope}")
      else
        # Compare config content (ignoring prompts which are repo-only metadata)
        local env_cfg repo_cfg
        env_cfg=$(jq -cS --arg n "$srvname" '.mcpServers[$n]' "$settings" 2>/dev/null || echo "{}")
        repo_cfg=$(jq -cS '.config' "${REPO_DIR}/mcp-servers/${srvname}.json" 2>/dev/null || echo "{}")
        # Strip env values for comparison (placeholders in repo vs real values in env)
        # Just check structural keys instead of values for meaningful diff
        local env_keys repo_keys
        env_keys=$(echo "$env_cfg" | jq -cS 'keys' 2>/dev/null || echo "[]")
        repo_keys=$(echo "$repo_cfg" | jq -cS 'keys' 2>/dev/null || echo "[]")
        if [[ "$env_keys" != "$repo_keys" ]]; then
          items+=("modified|MCP Server|${srvname}|${settings}|${scope}")
        fi
      fi
    done <<< "$keys"
  }

  # -------------------------------------------------------------------
  # A) Global scope: ~/.claude/
  # -------------------------------------------------------------------
  info "Scanning global ~/.claude/ ..."
  compare_agents   "${CLAUDE_HOME}/agents"   "${REPO_DIR}/agents"   "global"
  compare_skills   "${CLAUDE_HOME}/skills"   "${REPO_DIR}/skills"   "global"
  compare_commands "${CLAUDE_HOME}/commands"  "${REPO_DIR}/commands" "global"
  compare_mcp_servers "$GLOBAL_SETTINGS" "global"

  # -------------------------------------------------------------------
  # B) Project-level: each scan path
  # -------------------------------------------------------------------
  for scan_dir in "${scan_paths[@]}"; do
    info "Scanning ${scan_dir} ..."
    for project_dir in "$scan_dir"/*/; do
      [[ -d "$project_dir" ]] || continue
      local project_name
      project_name="$(basename "$project_dir")"
      local project_claude="${project_dir}.claude"
      local scope="project:${project_name}"

      if [[ -d "$project_claude" ]]; then
        compare_agents   "${project_claude}/agents"   "${REPO_DIR}/agents"   "$scope"
        compare_skills   "${project_claude}/skills"   "${REPO_DIR}/skills"   "$scope"
        compare_commands "${project_claude}/commands"  "${REPO_DIR}/commands" "$scope"
      fi

      # Project .mcp.json
      if [[ -f "${project_dir}.mcp.json" ]]; then
        compare_mcp_servers "${project_dir}.mcp.json" "$scope"
      fi
    done
  done

  # -------------------------------------------------------------------
  # 4. Display results summary
  # -------------------------------------------------------------------
  if [[ ${#items[@]} -eq 0 ]]; then
    info "No new or modified content detected."
    return
  fi

  heading "Scan results:"
  echo ""

  # Count by status
  local count_new=0 count_mod=0
  for item in "${items[@]}"; do
    local status="${item%%|*}"
    case "$status" in
      new)      ((count_new++)) || true ;;
      modified) ((count_mod++)) || true ;;
    esac
  done

  printf "  %-18s %s\n" "New:" "$count_new"
  printf "  %-18s %s\n" "Modified:" "$count_mod"
  printf "  %-18s %s\n" "Total:" "${#items[@]}"
  echo ""

  # 5. Display items grouped by category
  local categories=("Agent" "Skill" "Command" "MCP Server")
  for cat in "${categories[@]}"; do
    local cat_items=()
    for item in "${items[@]}"; do
      IFS='|' read -r status category name source scope <<< "$item"
      if [[ "$category" == "$cat" ]]; then
        cat_items+=("$item")
      fi
    done
    if [[ ${#cat_items[@]} -gt 0 ]]; then
      gum style --bold --foreground 81 "  ${cat}s:"
      for item in "${cat_items[@]}"; do
        IFS='|' read -r status category name source scope <<< "$item"
        local shared_mark=""
        local key
        key="$(echo "$category" | tr '[:upper:]' '[:lower:]'):${name}"
        key="${key// /-}"
        local _safe_key="_npc_${key//[^a-zA-Z0-9_]/_}"; local _cnt; eval "_cnt=\${${_safe_key}:-0}"
        # Check shared across projects
        if [[ $_cnt -ge 2 ]]; then
          shared_mark=" [shared]"
        fi
        local status_label
        case "$status" in
          new)      status_label="NEW" ;;
          modified) status_label="MOD" ;;
        esac
        printf "    [%s] %-30s (%s)%s\n" "$status_label" "$name" "$scope" "$shared_mark"
      done
      echo ""
    fi
  done

  # 6. Present selection
  local choice_lines=()
  for item in "${items[@]}"; do
    IFS='|' read -r status category name source scope <<< "$item"
    local status_label
    case "$status" in
      new)      status_label="NEW" ;;
      modified) status_label="MOD" ;;
    esac
    local shared_mark=""
    local key="$(echo "$category" | tr '[:upper:]' '[:lower:]'):${name}"
    key="${key// /-}"
    local _safe_key="_npc_${key//[^a-zA-Z0-9_]/_}"; local _cnt; eval "_cnt=\${${_safe_key}:-0}"
    if [[ $_cnt -ge 2 ]]; then
      shared_mark=" *shared*"
    fi
    choice_lines+=("[${status_label}] ${category}: ${name} (${scope})${shared_mark}")
  done

  heading "Select items to add to repo:"
  local selected
  selected=$(printf '%s\n' "${choice_lines[@]}" | gum choose --no-limit --height 40) || true

  if [[ -z "$selected" ]]; then
    info "Nothing selected."
    return
  fi

  # 7. Process each selected item
  local added_names=()
  while IFS= read -r sel_line; do
    [[ -z "$sel_line" ]] && continue
    # Find the matching item
    for item in "${items[@]}"; do
      IFS='|' read -r status category name source scope <<< "$item"
      local status_label
      case "$status" in
        new)      status_label="NEW" ;;
        modified) status_label="MOD" ;;
      esac
      local shared_mark=""
      local key="$(echo "$category" | tr '[:upper:]' '[:lower:]'):${name}"
      key="${key// /-}"
      local _safe_key="_npc_${key//[^a-zA-Z0-9_]/_}"; local _cnt; eval "_cnt=\${${_safe_key}:-0}"
      if [[ $_cnt -ge 2 ]]; then
        shared_mark=" *shared*"
      fi
      local expected="[${status_label}] ${category}: ${name} (${scope})${shared_mark}"
      if [[ "$sel_line" == "$expected" ]]; then
        process_add_item "$status" "$category" "$name" "$source" "$scope"
        added_names+=("$name")
        break
      fi
    done
  done <<< "$selected"

  # 8. Commit?
  if [[ ${#added_names[@]} -gt 0 ]]; then
    echo ""
    local do_commit
    do_commit=$(gum choose "Yes" "No" --header "Commit changes?") || true
    if [[ "$do_commit" == "Yes" ]]; then
      local msg="Add: ${added_names[*]}"
      cd "$REPO_DIR"
      git add .
      git commit -m "$msg"
      info "Committed: $msg"
    fi
  fi
}

process_add_item() {
  local status="$1" category="$2" name="$3" source="$4" scope="$5"

  case "$category" in
    Agent)
      # name may contain subdir, e.g. "development_architecture/backend-architect"
      local dest="${REPO_DIR}/agents/${name}.md"
      mkdir -p "$(dirname "$dest")"
      cp -f "$source" "$dest"
      info "Copied agent: ${name}"
      ;;

    Skill)
      local dest="${REPO_DIR}/skills/${name}"
      mkdir -p "$dest"
      cp -Rf "$source"/* "$dest"/ 2>/dev/null || cp -Rf "$source"/. "$dest"/
      info "Copied skill: ${name}"
      ;;

    Command)
      local dest="${REPO_DIR}/commands/${name}.md"
      mkdir -p "$(dirname "$dest")"
      cp -f "$source" "$dest"
      info "Copied command: ${name}"
      ;;

    "MCP Server")
      # Extract config from settings file, replace sensitive values with placeholders
      local dest="${REPO_DIR}/mcp-servers/${name}.json"
      mkdir -p "$(dirname "$dest")"
      local raw_config
      raw_config=$(jq --arg n "$name" '.mcpServers[$n]' "$source" 2>/dev/null)

      if [[ "$raw_config" == "null" ]] || [[ -z "$raw_config" ]]; then
        warn "Could not extract MCP server config for ${name} from ${source}"
        return
      fi

      # Detect sensitive values in env block and replace with ${VAR} placeholders
      local prompts="[]"
      local config="$raw_config"

      # Process env keys: replace values that look sensitive with placeholders
      local env_keys
      env_keys=$(echo "$raw_config" | jq -r '.env // {} | keys[]' 2>/dev/null || true)
      if [[ -n "$env_keys" ]]; then
        while IFS= read -r ekey; do
          [[ -z "$ekey" ]] && continue
          local evalue
          evalue=$(echo "$raw_config" | jq -r --arg k "$ekey" '.env[$k]' 2>/dev/null)
          # If it's already a placeholder, keep it
          if [[ "$evalue" == \$\{*\} ]]; then
            continue
          fi
          # Replace with ${VAR_NAME} placeholder
          local placeholder="\${${ekey}}"
          config=$(echo "$config" | jq --arg k "$ekey" --arg v "$placeholder" '.env[$k] = $v')
          # Determine if sensitive (keys containing KEY, SECRET, TOKEN, PASSWORD, etc.)
          local is_sensitive=false
          if echo "$ekey" | grep -qiE '(key|secret|token|password|auth|credential)'; then
            is_sensitive=true
          fi
          local prompt_entry
          prompt_entry=$(jq -n --arg v "$ekey" --arg m "${ekey} for ${name}" \
            --arg d "" --argjson s "$is_sensitive" \
            '{var: $v, message: $m, default: $d, sensitive: $s}')
          prompts=$(echo "$prompts" | jq --argjson p "$prompt_entry" '. += [$p]')
        done <<< "$env_keys"
      fi

      # Also check for URL-like values at the top level that might be environment-specific
      local url_val
      url_val=$(echo "$raw_config" | jq -r '.url // empty' 2>/dev/null || true)
      if [[ -n "$url_val" ]] && [[ "$url_val" != \$\{*\} ]]; then
        local var_name
        var_name=$(echo "${name}_URL" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
        config=$(echo "$config" | jq --arg v "\${${var_name}}" '.url = $v')
        local prompt_entry
        prompt_entry=$(jq -n --arg v "$var_name" --arg m "URL for ${name}" \
          --arg d "" --argjson s false \
          '{var: $v, message: $m, default: $d, sensitive: $s}')
        prompts=$(echo "$prompts" | jq --argjson p "$prompt_entry" '. += [$p]')
      fi

      # Build description
      local desc
      desc=$(gum input --placeholder "Brief description of ${name}" \
        --prompt "Description for ${name}: ") || true
      [[ -z "$desc" ]] && desc="MCP server: ${name}"

      # Write final JSON
      jq -n --arg n "$name" --arg d "$desc" \
        --argjson c "$config" --argjson p "$prompts" \
        '{name: $n, description: $d, config: $c, prompts: $p}' > "$dest"
      info "Created MCP server config: ${dest}"
      ;;
  esac
}

###############################################################################
# Update Flow
###############################################################################

flow_update() {
  heading "== Update: edit existing content in repo =="

  local type
  type=$(gum choose "Agent" "Skill" "Command" "MCP Server" --header "Select type to update:") || return

  local items=()
  local base_paths=()
  case "$type" in
    Agent)
      while IFS= read -r -d '' f; do
        local rel="${f#"${REPO_DIR}/agents/"}"
        items+=("${rel%.md}")
        base_paths+=("$f")
      done < <(find "${REPO_DIR}/agents" -name '*.md' -type f -print0 2>/dev/null)
      ;;
    Skill)
      for d in "${REPO_DIR}"/skills/*/; do
        [[ -d "$d" ]] || continue
        local sname
        sname="$(basename "$d")"
        items+=("$sname")
        base_paths+=("$d")
      done
      ;;
    Command)
      for f in "${REPO_DIR}"/commands/*.md; do
        [[ -f "$f" ]] || continue
        local cname
        cname="$(name_of "$f")"
        items+=("$cname")
        base_paths+=("$f")
      done
      ;;
    "MCP Server")
      for f in "${REPO_DIR}"/mcp-servers/*.json; do
        [[ -f "$f" ]] || continue
        local sname
        sname="$(basename "$f" .json)"
        items+=("$sname")
        base_paths+=("$f")
      done
      ;;
  esac

  if [[ ${#items[@]} -eq 0 ]]; then
    warn "No ${type} items found in repo."
    return
  fi

  local selected
  selected=$(printf '%s\n' "${items[@]}" | gum choose --header "Select ${type} to edit:") || return

  # Find the matching path
  local edit_path=""
  for i in "${!items[@]}"; do
    if [[ "${items[$i]}" == "$selected" ]]; then
      edit_path="${base_paths[$i]}"
      break
    fi
  done

  if [[ -z "$edit_path" ]]; then
    err "Could not find path for: ${selected}"
    return
  fi

  # For skills, let user pick a file inside the skill directory
  if [[ "$type" == "Skill" ]] && [[ -d "$edit_path" ]]; then
    local skill_files=()
    while IFS= read -r -d '' sf; do
      skill_files+=("${sf#"$edit_path"/}")
    done < <(find "$edit_path" -type f -print0 2>/dev/null)

    if [[ ${#skill_files[@]} -eq 0 ]]; then
      warn "No files in skill directory."
      return
    fi

    local sel_file
    sel_file=$(printf '%s\n' "${skill_files[@]}" | gum choose --header "Select file to edit:") || return
    edit_path="${edit_path}/${sel_file}"
  fi

  info "Opening ${edit_path} in editor..."
  ${EDITOR:-vim} "$edit_path"

  # After edit, offer to re-install
  local reinstall
  reinstall=$(gum choose "Yes" "No" --header "Re-install to environment?") || true

  if [[ "$reinstall" == "Yes" ]]; then
    case "$type" in
      Agent)
        local rel="${edit_path#"${REPO_DIR}/agents/"}"
        local dest="${CLAUDE_HOME}/agents/${rel}"
        mkdir -p "$(dirname "$dest")"
        cp -f "$edit_path" "$dest"
        info "Installed agent to ${dest}"
        ;;
      Skill)
        # edit_path might be a file inside a skill dir — find the skill root
        local skill_root="$edit_path"
        # Walk up until we find the skills/ parent
        while [[ "$(basename "$(dirname "$skill_root")")" != "skills" ]] && [[ "$skill_root" != "/" ]]; do
          skill_root="$(dirname "$skill_root")"
        done
        local sname
        sname="$(basename "$skill_root")"
        local dest="${CLAUDE_HOME}/skills/${sname}"
        mkdir -p "$dest"
        cp -Rf "$skill_root"/* "$dest"/ 2>/dev/null || cp -Rf "$skill_root"/. "$dest"/
        info "Installed skill to ${dest}"
        ;;
      Command)
        local cname
        cname="$(basename "$edit_path")"
        local dest="${CLAUDE_HOME}/commands/${cname}"
        mkdir -p "$(dirname "$dest")"
        cp -f "$edit_path" "$dest"
        info "Installed command to ${dest}"
        ;;
      "MCP Server")
        info "MCP server configs are applied via setup.sh. Run Sync to apply."
        ;;
    esac
  fi
}

###############################################################################
# Remove Flow
###############################################################################

flow_remove() {
  heading "== Remove: remove content from repo =="

  local type
  type=$(gum choose "Agent" "Skill" "Command" "MCP Server" --header "Select type to remove:") || return

  local items=()
  local base_paths=()
  case "$type" in
    Agent)
      while IFS= read -r -d '' f; do
        local rel="${f#"${REPO_DIR}/agents/"}"
        items+=("${rel%.md}")
        base_paths+=("$f")
      done < <(find "${REPO_DIR}/agents" -name '*.md' -type f -print0 2>/dev/null)
      ;;
    Skill)
      for d in "${REPO_DIR}"/skills/*/; do
        [[ -d "$d" ]] || continue
        local sname
        sname="$(basename "$d")"
        items+=("$sname")
        base_paths+=("$d")
      done
      ;;
    Command)
      for f in "${REPO_DIR}"/commands/*.md; do
        [[ -f "$f" ]] || continue
        local cname
        cname="$(name_of "$f")"
        items+=("$cname")
        base_paths+=("$f")
      done
      ;;
    "MCP Server")
      for f in "${REPO_DIR}"/mcp-servers/*.json; do
        [[ -f "$f" ]] || continue
        local sname
        sname="$(basename "$f" .json)"
        items+=("$sname")
        base_paths+=("$f")
      done
      ;;
  esac

  if [[ ${#items[@]} -eq 0 ]]; then
    warn "No ${type} items found in repo."
    return
  fi

  local selected
  selected=$(printf '%s\n' "${items[@]}" | gum choose --header "Select ${type} to remove:") || return

  # Confirm
  local confirm
  confirm=$(gum choose "Yes, remove" "Cancel" --header "Remove '${selected}' from repo?") || return
  if [[ "$confirm" != "Yes, remove" ]]; then
    info "Cancelled."
    return
  fi

  # Find the matching path
  local remove_path=""
  for i in "${!items[@]}"; do
    if [[ "${items[$i]}" == "$selected" ]]; then
      remove_path="${base_paths[$i]}"
      break
    fi
  done

  if [[ -z "$remove_path" ]]; then
    err "Could not find path for: ${selected}"
    return
  fi

  # Remove from repo
  if [[ -d "$remove_path" ]]; then
    rm -rf "$remove_path"
  else
    rm -f "$remove_path"
  fi
  info "Removed from repo: ${selected}"

  # Also remove from environment?
  local also_env
  also_env=$(gum choose "Yes" "No" --header "Also remove from environment?") || true

  if [[ "$also_env" == "Yes" ]]; then
    case "$type" in
      Agent)
        local env_path="${CLAUDE_HOME}/agents/${selected}.md"
        rm -f "$env_path" 2>/dev/null && info "Removed from environment: ${env_path}" || true
        ;;
      Skill)
        local env_path="${CLAUDE_HOME}/skills/${selected}"
        rm -rf "$env_path" 2>/dev/null && info "Removed from environment: ${env_path}" || true
        ;;
      Command)
        local env_path="${CLAUDE_HOME}/commands/${selected}.md"
        rm -f "$env_path" 2>/dev/null && info "Removed from environment: ${env_path}" || true
        ;;
      "MCP Server")
        # Remove from global settings.json
        if [[ -f "$GLOBAL_SETTINGS" ]]; then
          local updated
          updated=$(jq --arg n "$selected" 'del(.mcpServers[$n])' "$GLOBAL_SETTINGS" 2>/dev/null)
          if [[ -n "$updated" ]]; then
            echo "$updated" | jq '.' > "$GLOBAL_SETTINGS"
            info "Removed MCP server '${selected}' from ${GLOBAL_SETTINGS}"
          fi
        fi
        ;;
    esac
  fi
}

###############################################################################
# Sync Flow
###############################################################################

flow_sync() {
  heading "== Sync: pull remote + re-install =="

  cd "$REPO_DIR"

  # Determine current branch
  local branch
  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")

  info "Pulling latest from origin/${branch} ..."
  local pull_output
  pull_output=$(git pull --rebase origin "$branch" 2>&1) || true
  echo "$pull_output"
  echo ""

  # Show changed files
  local changed
  changed=$(git diff --name-only HEAD@{1}..HEAD 2>/dev/null || true)
  if [[ -n "$changed" ]]; then
    heading "Changed files:"
    echo "$changed"
    echo ""
  else
    info "No files changed."
  fi

  # Ask to re-run setup
  local action
  action=$(gum choose "Yes (interactive)" "Yes (all)" "No" \
    --header "Re-run setup to apply changes?") || return

  case "$action" in
    "Yes (interactive)")
      if [[ -f "${REPO_DIR}/setup.sh" ]]; then
        bash "${REPO_DIR}/setup.sh"
      else
        warn "setup.sh not found in ${REPO_DIR}"
      fi
      ;;
    "Yes (all)")
      if [[ -f "${REPO_DIR}/setup.sh" ]]; then
        bash "${REPO_DIR}/setup.sh" --all 2>/dev/null || bash "${REPO_DIR}/setup.sh"
      else
        warn "setup.sh not found in ${REPO_DIR}"
      fi
      ;;
    "No")
      info "Skipped setup."
      ;;
  esac
}

###############################################################################
# Main Menu
###############################################################################

main() {
  ensure_deps

  heading "ai_project_init content manager"
  echo ""

  local action
  action=$(gum choose \
    "Add     - Detect new content from environment" \
    "Update  - Edit existing content in repo" \
    "Remove  - Remove content from repo" \
    "Sync    - Pull remote + re-install" \
    --header "What would you like to do?") || exit 0

  case "$action" in
    Add*)    flow_add ;;
    Update*) flow_update ;;
    Remove*) flow_remove ;;
    Sync*)   flow_sync ;;
  esac
}

main
