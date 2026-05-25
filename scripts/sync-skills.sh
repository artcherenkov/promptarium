#!/usr/bin/env zsh
emulate -L zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL

usage() {
  cat <<'USAGE'
Usage:
  scripts/sync-skills.sh [--check] [--target codex|claude|agents|all] [skill ...]
  scripts/sync-skills.sh --remove [--target codex|claude|agents|all] skill ...
  scripts/sync-skills.sh --list

Synchronizes only skills defined in this repository:
  skills/<name>/skill-source.md

Installed layout:
  ~/.codex/skills/<name>/SKILL.md
  ~/.claude/skills/<name>/SKILL.md
  ~/.agents/skills/<name>/SKILL.md

Options:
  --check     report status without writing files
  --remove    move installed repo-defined skills to a backup directory
  --target    limit operation to codex, claude, agents, or all
  --list      print repo-defined skill names
  -h, --help

Backups are stored under:
  $SKILL_SYNC_BACKUP_DIR, or ~/.agent-skill-sync-backups when unset
USAGE
}

mode="sync"
target_arg="all"
skill_args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      mode="check"
      ;;
    --remove)
      mode="remove"
      ;;
    --target)
      shift
      if [[ $# -eq 0 ]]; then
        echo "Missing value for --target." >&2
        usage >&2
        exit 2
      fi
      target_arg="$1"
      ;;
    --list)
      mode="list"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      skill_args+=("$@")
      break
      ;;
    -*)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      skill_args+=("$1")
      ;;
  esac
  shift
done

script_dir="${0:A:h}"
repo_root="$(cd "$script_dir/.." && pwd)"
source_root="$repo_root/skills"
backup_root="${SKILL_SYNC_BACKUP_DIR:-$HOME/.agent-skill-sync-backups}"
timestamp="$(date +%Y%m%d_%H%M%S)"
temp_root="$(mktemp -d "${TMPDIR:-/tmp}/sync-skills.XXXXXX")"

cleanup() {
  rm -rf "$temp_root"
}
trap cleanup EXIT

typeset -A target_roots
target_roots=(
  codex "$HOME/.codex/skills"
  claude "$HOME/.claude/skills"
  agents "$HOME/.agents/skills"
)
all_targets=(codex claude agents)
selected_targets=()
skills_to_process=()

typeset -A repo_skill_dirs
repo_skills=()

typeset -A result_cells
detail_lines=()
operation_status=""
operation_detail=""
exit_status=0

error() {
  echo "ERROR $*" >&2
  exit_status=1
}

set_operation_result() {
  operation_status="$1"
  operation_detail="${2:-}"
}

record_result() {
  local target="$1"
  local skill="$2"
  local cell_status="$3"
  local detail="${4:-}"
  local key="$skill|$target"

  result_cells[$key]="$cell_status"

  if [[ -n "$detail" ]]; then
    detail_lines+=("$target $skill: $detail")
  fi
}

print_status_table() {
  local skill target key cell width
  local skill_width=5
  typeset -A col_widths

  for skill in "${skills_to_process[@]}"; do
    if (( ${#skill} > skill_width )); then
      skill_width=${#skill}
    fi
  done

  for target in "${selected_targets[@]}"; do
    col_widths[$target]=${#target}

    for skill in "${skills_to_process[@]}"; do
      key="$skill|$target"
      cell="${result_cells[$key]:--}"

      if (( ${#cell} > col_widths[$target] )); then
        col_widths[$target]=${#cell}
      fi
    done
  done

  printf "%-*s" "$skill_width" "skill"

  for target in "${selected_targets[@]}"; do
    width="${col_widths[$target]}"
    printf "  %-*s" "$width" "$target"
  done

  printf "\n"

  for skill in "${skills_to_process[@]}"; do
    printf "%-*s" "$skill_width" "$skill"

    for target in "${selected_targets[@]}"; do
      key="$skill|$target"
      cell="${result_cells[$key]:--}"
      width="${col_widths[$target]}"
      printf "  %-*s" "$width" "$cell"
    done

    printf "\n"
  done

  if [[ "${#detail_lines[@]}" -gt 0 ]]; then
    printf "\n"
    echo "details:"
    printf "  %s\n" "${detail_lines[@]}"
  fi
}

load_repo_skills() {
  local source_file source_dir skill first_symlink

  if [[ ! -d "$source_root" ]]; then
    error "source skills directory does not exist: $source_root"
    return
  fi

  for source_file in "$source_root"/*/skill-source.md(N); do
    source_dir="${source_file:h}"
    skill="${source_dir:t}"

    if [[ ! "$skill" =~ '^[a-z0-9][a-z0-9-]*$' ]]; then
      error "invalid skill directory name: $source_dir"
      continue
    fi

    if ! grep -Eq "^name:[[:space:]]*${skill}[[:space:]]*$" "$source_file"; then
      error "frontmatter name must match directory for $source_file"
      continue
    fi

    first_symlink="$(find "$source_dir" -type l -print -quit)"
    if [[ -n "$first_symlink" ]]; then
      error "source skill contains a symlink: $first_symlink"
      continue
    fi

    repo_skills+=("$skill")
    repo_skill_dirs[$skill]="$source_dir"
  done
}

select_targets() {
  if [[ "$target_arg" == "all" ]]; then
    selected_targets=("${all_targets[@]}")
    return
  fi

  if [[ -z "${target_roots[$target_arg]:-}" ]]; then
    echo "Unknown target: $target_arg" >&2
    usage >&2
    exit 2
  fi

  selected_targets=("$target_arg")
}

select_skills() {
  local skill

  if [[ "${#skill_args[@]}" -eq 0 ]]; then
    skills_to_process=("${repo_skills[@]}")
    return
  fi

  for skill in "${skill_args[@]}"; do
    if [[ -z "${repo_skill_dirs[$skill]:-}" ]]; then
      error "skill is not defined in this repository: $skill"
      continue
    fi

    skills_to_process+=("$skill")
  done
}

copy_extra_payload_files() {
  local source_dir="$1"
  local payload_dir="$2"
  local entry

  for entry in "$source_dir"/*(N) "$source_dir"/.[!.]*(N) "$source_dir"/..?*(N); do
    if [[ "${entry:t}" == "skill-source.md" ]]; then
      continue
    fi

    cp -R "$entry" "$payload_dir/"
  done
}

build_payload() {
  local skill="$1"
  local source_dir="${repo_skill_dirs[$skill]}"
  local payload_dir="$temp_root/payload/$skill"

  rm -rf "$payload_dir"
  mkdir -p "$payload_dir"
  install -m 0644 "$source_dir/skill-source.md" "$payload_dir/SKILL.md"
  copy_extra_payload_files "$source_dir" "$payload_dir"

  print -r -- "$payload_dir"
}

ensure_target_root() {
  local target="$1"
  local root="${target_roots[$target]}"

  if [[ -L "$root" ]]; then
    set_operation_result "error" "skills root is a symlink: $root -> $(readlink "$root")"
    return 1
  fi

  if [[ -e "$root" && ! -d "$root" ]]; then
    set_operation_result "error" "skills root is not a directory: $root"
    return 1
  fi

  if [[ ! -d "$root" && "$mode" == "sync" ]]; then
    if ! mkdir -p "$root"; then
      set_operation_result "error" "failed to create skills root: $root"
      return 1
    fi
  fi
}

backup_path_for() {
  local target="$1"
  local skill="$2"
  local backup_dir="$backup_root/$timestamp"

  mkdir -p "$backup_dir"
  print -r -- "$backup_dir/$target--$skill"
}

check_skill() {
  local target="$1"
  local skill="$2"
  local root="${target_roots[$target]}"
  local dest_dir="$root/$skill"
  local payload_dir

  ensure_target_root "$target" || return 1

  if [[ ! -e "$dest_dir" ]]; then
    set_operation_result "missing"
    return 1
  fi

  if [[ -L "$dest_dir" ]]; then
    set_operation_result "error" "symlink: $dest_dir -> $(readlink "$dest_dir")"
    return 1
  fi

  if [[ ! -d "$dest_dir" ]]; then
    set_operation_result "error" "not a directory: $dest_dir"
    return 1
  fi

  payload_dir="$(build_payload "$skill")"

  if diff -qr "$payload_dir" "$dest_dir" >/dev/null; then
    set_operation_result "ok"
    return 0
  fi

  set_operation_result "differs"
  return 1
}

sync_skill() {
  local target="$1"
  local skill="$2"
  local root="${target_roots[$target]}"
  local dest_dir="$root/$skill"
  local payload_dir backup_path had_dest=0

  ensure_target_root "$target" || return 1

  if [[ -L "$dest_dir" ]]; then
    set_operation_result "error" "symlink: $dest_dir -> $(readlink "$dest_dir")"
    return 1
  fi

  if [[ -e "$dest_dir" && ! -d "$dest_dir" ]]; then
    set_operation_result "error" "not a directory: $dest_dir"
    return 1
  fi

  payload_dir="$(build_payload "$skill")"

  if [[ -d "$dest_dir" ]] && diff -qr "$payload_dir" "$dest_dir" >/dev/null; then
    set_operation_result "unchanged"
    return 0
  fi

  if [[ -d "$dest_dir" ]]; then
    had_dest=1
    backup_path="$(backup_path_for "$target" "$skill")"
    if ! mv "$dest_dir" "$backup_path"; then
      set_operation_result "error" "failed to move old skill to backup: $backup_path"
      return 1
    fi
  fi

  if ! cp -R "$payload_dir" "$dest_dir"; then
    set_operation_result "error" "failed to install: $dest_dir"
    return 1
  fi

  if [[ -d "$dest_dir" ]]; then
    if (( had_dest )); then
      set_operation_result "updated" "backup: $backup_path"
    else
      set_operation_result "created"
    fi
    return 0
  fi

  set_operation_result "error" "failed to install: $dest_dir"
  return 1
}

remove_skill() {
  local target="$1"
  local skill="$2"
  local root="${target_roots[$target]}"
  local dest_dir="$root/$skill"
  local backup_path

  ensure_target_root "$target" || return 1

  if [[ ! -e "$dest_dir" ]]; then
    set_operation_result "missing"
    return 0
  fi

  if [[ -L "$dest_dir" ]]; then
    set_operation_result "error" "symlink: $dest_dir -> $(readlink "$dest_dir")"
    return 1
  fi

  if [[ ! -d "$dest_dir" ]]; then
    set_operation_result "error" "not a directory: $dest_dir"
    return 1
  fi

  backup_path="$(backup_path_for "$target" "$skill")"
  if ! mv "$dest_dir" "$backup_path"; then
    set_operation_result "error" "failed to move skill to backup: $backup_path"
    return 1
  fi

  set_operation_result "removed" "backup: $backup_path"
}

load_repo_skills
select_targets

if [[ "$mode" == "remove" && "${#skill_args[@]}" -eq 0 ]]; then
  echo "--remove requires at least one repo-defined skill name." >&2
  exit 2
fi

select_skills

if [[ "$mode" == "list" ]]; then
  printf '%s\n' "${repo_skills[@]}"
  exit "$exit_status"
fi

if [[ "${#repo_skills[@]}" -eq 0 ]]; then
  error "no valid repo-defined skills found in $source_root"
  exit "$exit_status"
fi

if [[ "${#skills_to_process[@]}" -eq 0 ]]; then
  exit "$exit_status"
fi

for target in "${selected_targets[@]}"; do
  for skill in "${skills_to_process[@]}"; do
    operation_status=""
    operation_detail=""

    case "$mode" in
      check)
        check_skill "$target" "$skill" || exit_status=1
        ;;
      remove)
        remove_skill "$target" "$skill" || exit_status=1
        ;;
      sync)
        sync_skill "$target" "$skill" || exit_status=1
        ;;
      *)
        echo "Unknown mode: $mode" >&2
        exit 2
        ;;
    esac

    if [[ -z "$operation_status" ]]; then
      operation_status="error"
      operation_detail="operation did not report a status"
      exit_status=1
    fi

    record_result "$target" "$skill" "$operation_status" "$operation_detail"
  done
done

print_status_table

exit "$exit_status"
