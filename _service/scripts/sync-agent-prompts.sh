#!/usr/bin/env zsh
emulate -L zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL

usage() {
  cat <<'USAGE'
Usage:
  _service/scripts/sync-agent-prompts.sh [--check]

Copies system-rules/agents-md.md into:
  ~/.codex/AGENTS.md
  ~/.claude/CLAUDE.md
  ~/.agents/AGENTS.md

The script writes regular files only. If a destination is a symlink or another
non-regular file, it stops and asks you to fix that path manually.

Options:
  --check   report whether destinations are in sync without writing files
  -h, --help
USAGE
}

mode="sync"

case "${1:-}" in
  "")
    ;;
  --check)
    mode="check"
    shift
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    echo "Unknown argument: $1" >&2
    usage >&2
    exit 2
    ;;
esac

if [[ $# -gt 0 ]]; then
  echo "Too many arguments." >&2
  usage >&2
  exit 2
fi

script_dir="${0:A:h}"
repo_root="$(cd "$script_dir/../.." && pwd)"
source_file="$repo_root/system-rules/agents-md.md"
backup_root="${AGENT_PROMPT_BACKUP_DIR:-$HOME/.agent-prompt-sync-backups}"
timestamp="$(date +%Y%m%d_%H%M%S)"

targets=(
  "$HOME/.codex/AGENTS.md"
  "$HOME/.claude/CLAUDE.md"
  "$HOME/.agents/AGENTS.md"
)

if [[ ! -f "$source_file" ]]; then
  echo "Source file does not exist or is not a regular file: $source_file" >&2
  exit 1
fi

exit_status=0

safe_backup_name() {
  local target="$1"
  local name="${target#$HOME/}"
  name="${name//\//__}"
  name="${name// /_}"
  printf '%s.bak' "$name"
}

check_target() {
  local target="$1"

  if [[ -L "$target" ]]; then
    echo "ERROR symlink: $target -> $(readlink "$target")" >&2
    return 1
  fi

  if [[ -e "$target" && ! -f "$target" ]]; then
    echo "ERROR not a regular file: $target" >&2
    return 1
  fi

  if [[ ! -e "$target" ]]; then
    echo "MISSING $target"
    return 1
  fi

  if cmp -s "$source_file" "$target"; then
    echo "OK $target"
    return 0
  fi

  echo "DIFFERS $target"
  return 1
}

sync_target() {
  local target="$1"
  local target_dir
  target_dir="$(dirname "$target")"

  if [[ -L "$target" ]]; then
    echo "ERROR symlink: $target -> $(readlink "$target")" >&2
    echo "Remove or replace the symlink manually, then run this script again." >&2
    return 1
  fi

  if [[ -e "$target" && ! -f "$target" ]]; then
    echo "ERROR not a regular file: $target" >&2
    return 1
  fi

  if [[ ! -d "$target_dir" ]]; then
    mkdir -p "$target_dir"
  fi

  if [[ ! -e "$target" ]]; then
    install -m 0644 "$source_file" "$target"
    echo "CREATED $target"
    return 0
  fi

  if cmp -s "$source_file" "$target"; then
    echo "UNCHANGED $target"
    return 0
  fi

  local backup_dir="$backup_root/$timestamp"
  local backup_file="$backup_dir/$(safe_backup_name "$target")"
  mkdir -p "$backup_dir"
  cp -p "$target" "$backup_file"
  install -m 0644 "$source_file" "$target"
  echo "UPDATED $target"
  echo "BACKUP $backup_file"
}

for target in "${targets[@]}"; do
  if [[ "$mode" == "check" ]]; then
    check_target "$target" || exit_status=1
  else
    sync_target "$target" || exit_status=1
  fi
done

exit "$exit_status"
