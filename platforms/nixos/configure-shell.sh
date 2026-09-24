#!/usr/bin/env bash
set -euo pipefail

baseline_link="${1:-$HOME/.local/state/pc-setup/nix-user-baseline}"
config_dir="$HOME/.config/pc-setup"
init_file="$config_dir/shell-init.bash"

mkdir -p "$config_dir"

cat > "$init_file" <<'EOF'
# Managed by rebuildup/pc-setup.
pc_setup_user_baseline="$HOME/.local/state/pc-setup/nix-user-baseline/bin"
if [[ -d "$pc_setup_user_baseline" ]]; then
  case ":$PATH:" in
    *":$pc_setup_user_baseline:"*) ;;
    *) export PATH="$pc_setup_user_baseline:$PATH" ;;
  esac
fi

# Dotfiles provider entrypoints (non-secret PATH only).
# Provider URL/model/credential flags stay process-scoped inside the entrypoint.
pc_setup_agent_entry="$HOME/.dotfiles/script/agent"
if [[ -d "$pc_setup_agent_entry" ]]; then
  case ":$PATH:" in
    *":$pc_setup_agent_entry:"*) ;;
    *) export PATH="$pc_setup_agent_entry:$PATH" ;;
  esac
fi
if [[ -x "$pc_setup_agent_entry/mimo" ]]; then
  claude() {
    "$HOME/.dotfiles/script/agent/mimo" claude "$@"
  }
fi

if command -v wt >/dev/null 2>&1; then
  eval "$(wt config shell init bash)"
fi
unset pc_setup_agent_entry pc_setup_user_baseline
EOF

ensure_source() {
  local rc_file="$1"
  local begin='# >>> pc-setup shell init >>>'
  local end='# <<< pc-setup shell init <<<'
  local source_line="[[ -r \"\$HOME/.config/pc-setup/shell-init.bash\" ]] && source \"\$HOME/.config/pc-setup/shell-init.bash\""
  local tmp

  touch "$rc_file"

  if grep -Fq "$begin" "$rc_file"; then
    tmp="$(mktemp)"
    awk -v begin="$begin" -v end="$end" '
      $0 == begin { skip=1; next }
      $0 == end { skip=0; next }
      !skip { print }
    ' "$rc_file" > "$tmp"
    mv "$tmp" "$rc_file"
  fi

  {
    printf '\n%s\n' "$begin"
    printf '%s\n' "$source_line"
    printf '%s\n' "$end"
  } >> "$rc_file"
}

ensure_source "$HOME/.bashrc"
ensure_source "$HOME/.profile"

if [[ ! -d "$baseline_link/bin" ]]; then
  printf 'warning: NixOS user baseline is not built yet: %s\n' "$baseline_link" >&2
fi

printf 'configured Bash shell init through %s\n' "$init_file"
