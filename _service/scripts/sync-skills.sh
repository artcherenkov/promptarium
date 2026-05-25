#!/usr/bin/env zsh
emulate -L zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL

usage() {
  cat <<'USAGE'
Usage:
  _service/scripts/sync-skills.sh [--check] [--target codex[,claude][,agents]|all] [--project /absolute/path] [skill ...]
  _service/scripts/sync-skills.sh --remove [--target codex[,claude][,agents]|all] [--project /absolute/path] skill ...
  _service/scripts/sync-skills.sh --list

Synchronizes only skills defined in this repository:
  skills/<name>/skill-source.md

Installed layout:
  ~/.codex/skills/<name>/SKILL.md
  ~/.claude/skills/<name>/SKILL.md
  ~/.agents/skills/<name>/SKILL.md
  <project>/.codex/skills/<name>/SKILL.md
  <project>/.claude/skills/<name>/SKILL.md
  <project>/.agents/skills/<name>/SKILL.md

Options:
  --check     report status without writing files
  --remove    move installed repo-defined skills to a backup directory
  --target    limit operation to comma-separated targets: codex, claude, agents, or all
  --project   sync inside one project directory instead of global agent roots
  --list      print repo-defined skill names
  -h, --help

Backups are stored under:
  $SKILL_SYNC_BACKUP_DIR, or ~/.agent-skill-sync-backups when unset

Project roots are remembered in:
  $SKILL_SYNC_PROJECTS_FILE, or _service/skill-installations.txt when unset
USAGE
}

append_target_arg() {
  local raw="$1"
  local target
  local values=("${(@s:,:)raw}")

  for target in "${values[@]}"; do
    if [[ -z "$target" ]]; then
      echo "Empty --target value in: $raw" >&2
      usage >&2
      exit 2
    fi

    target_args+=("$target")
  done
}

mode="sync"
target_args=()
project_arg=""
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

      append_target_arg "$1"
      ;;
    --project)
      shift
      if [[ $# -eq 0 ]]; then
        echo "Missing value for --project." >&2
        usage >&2
        exit 2
      fi
      project_arg="$1"
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
repo_root="$(cd "$script_dir/../.." && pwd)"
source_root="$repo_root/skills"
backup_root="${SKILL_SYNC_BACKUP_DIR:-$HOME/.agent-skill-sync-backups}"
projects_file="${SKILL_SYNC_PROJECTS_FILE:-$repo_root/_service/skill-installations.txt}"
timestamp="$(date +%Y%m%d_%H%M%S)"
temp_root="$(mktemp -d "${TMPDIR:-/tmp}/sync-skills.XXXXXX")"

cleanup() {
  rm -rf "$temp_root"
}
trap cleanup EXIT

typeset -A target_roots
all_targets=(codex claude agents)
selected_targets=()
table_targets=()
skills_to_process=()
project_status_skills=()
project_registry=()

typeset -A repo_skill_dirs
repo_skills=()

typeset -A result_cells
detail_lines=()
operation_status=""
operation_detail=""
exit_status=0

set_global_target_roots() {
  target_roots=(
    codex "$HOME/.codex/skills"
    claude "$HOME/.claude/skills"
    agents "$HOME/.agents/skills"
  )
}

set_project_target_roots() {
  local project="$1"

  target_roots=(
    codex "$project/.codex/skills"
    claude "$project/.claude/skills"
    agents "$project/.agents/skills"
  )
}

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

  for target in "${table_targets[@]}"; do
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

  for target in "${table_targets[@]}"; do
    width="${col_widths[$target]}"
    printf "  %-*s" "$width" "$target"
  done

  printf "\n"

  for skill in "${skills_to_process[@]}"; do
    printf "%-*s" "$skill_width" "$skill"

    for target in "${table_targets[@]}"; do
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

reset_results() {
  result_cells=()
  detail_lines=()
}

display_path() {
  local path="$1"

  if [[ "$path" == "$HOME" ]]; then
    print -r -- "~"
    return
  fi

  if [[ "$path" == "$HOME/"* ]]; then
    print -r -- "~/${path#$HOME/}"
    return
  fi

  print -r -- "$path"
}

validate_project_arg() {
  if [[ -z "$project_arg" ]]; then
    return
  fi

  if [[ "$project_arg" != /* ]]; then
    echo "--project requires an absolute path: $project_arg" >&2
    usage >&2
    exit 2
  fi

  if [[ ! -d "$project_arg" ]]; then
    echo "--project path is not a directory: $project_arg" >&2
    usage >&2
    exit 2
  fi

  project_arg="${project_arg:A}"
}

load_project_registry() {
  local line
  typeset -A seen_projects

  project_registry=()

  if [[ ! -e "$projects_file" ]]; then
    return
  fi

  if [[ -L "$projects_file" ]]; then
    error "project registry is a symlink: $projects_file -> $(readlink "$projects_file")"
    return 1
  fi

  if [[ ! -f "$projects_file" ]]; then
    error "project registry is not a regular file: $projects_file"
    return 1
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -z "$line" || "$line" == \#* ]]; then
      continue
    fi

    if [[ "$line" != /* ]]; then
      error "project registry contains a non-absolute path: $line"
      continue
    fi

    if [[ -n "${seen_projects[$line]:-}" ]]; then
      continue
    fi

    seen_projects[$line]=1
    project_registry+=("$line")
  done < "$projects_file"
}

register_project() {
  local project="$1"
  local registered_project registry_dir

  load_project_registry || return 1

  for registered_project in "${project_registry[@]}"; do
    if [[ "$registered_project" == "$project" ]]; then
      return
    fi
  done

  registry_dir="${projects_file:h}"

  if [[ -L "$registry_dir" ]]; then
    error "project registry directory is a symlink: $registry_dir -> $(readlink "$registry_dir")"
    return 1
  fi

  if [[ -e "$registry_dir" && ! -d "$registry_dir" ]]; then
    error "project registry path is not a directory: $registry_dir"
    return 1
  fi

  if [[ ! -d "$registry_dir" ]]; then
    if ! mkdir -p "$registry_dir"; then
      error "failed to create project registry directory: $registry_dir"
      return 1
    fi
  fi

  if ! print -r -- "$project" >> "$projects_file"; then
    error "failed to update project registry: $projects_file"
    return 1
  fi

  project_registry+=("$project")
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
  local target
  local saw_all=0
  typeset -A seen_targets

  selected_targets=()

  if [[ "${#target_args[@]}" -eq 0 ]]; then
    selected_targets=("${all_targets[@]}")
    return
  fi

  for target in "${target_args[@]}"; do
    if [[ "$target" == "all" ]]; then
      saw_all=1
      continue
    fi

    if [[ -z "${target_roots[$target]:-}" ]]; then
      echo "Unknown target: $target" >&2
      usage >&2
      exit 2
    fi

    if [[ -z "${seen_targets[$target]:-}" ]]; then
      selected_targets+=("$target")
      seen_targets[$target]=1
    fi
  done

  if (( saw_all )) && [[ "${#target_args[@]}" -gt 1 ]]; then
    echo "--target all cannot be combined with other targets." >&2
    usage >&2
    exit 2
  fi

  if (( saw_all )); then
    selected_targets=("${all_targets[@]}")
  fi
}

set_table_targets() {
  if [[ "$mode" == "check" ]]; then
    table_targets=("${selected_targets[@]}")
    return
  fi

  table_targets=("${all_targets[@]}")
}

fill_untouched_target_results() {
  local target skill
  typeset -A selected_lookup

  if [[ "$mode" == "check" ]]; then
    return
  fi

  for target in "${selected_targets[@]}"; do
    selected_lookup[$target]=1
  done

  for target in "${all_targets[@]}"; do
    if [[ -n "${selected_lookup[$target]:-}" ]]; then
      continue
    fi

    for skill in "${skills_to_process[@]}"; do
      record_result "$target" "$skill" "unchanged"
    done
  done
}

select_skills() {
  local skill
  local invalid=0

  if [[ "${#skill_args[@]}" -eq 0 ]]; then
    skills_to_process=("${repo_skills[@]}")
    return
  fi

  for skill in "${skill_args[@]}"; do
    if [[ -z "${repo_skill_dirs[$skill]:-}" ]]; then
      if [[ "$skill" == "codex" || "$skill" == "claude" || "$skill" == "agents" || "$skill" == "all" ]]; then
        echo "ERROR $skill looks like a target. Use a comma-separated value, for example: --target agents,claude" >&2
      else
        echo "ERROR skill is not defined in this repository: $skill" >&2
      fi

      exit_status=1
      invalid=1
      continue
    fi

    skills_to_process+=("$skill")
  done

  if (( invalid )); then
    return 1
  fi
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

  if ! mkdir -p "$backup_dir"; then
    return 1
  fi

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
    if ! backup_path="$(backup_path_for "$target" "$skill")"; then
      set_operation_result "error" "failed to create backup directory: $backup_root/$timestamp"
      return 1
    fi

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

  if ! backup_path="$(backup_path_for "$target" "$skill")"; then
    set_operation_result "error" "failed to create backup directory: $backup_root/$timestamp"
    return 1
  fi

  if ! mv "$dest_dir" "$backup_path"; then
    set_operation_result "error" "failed to move skill to backup: $backup_path"
    return 1
  fi

  set_operation_result "removed" "backup: $backup_path"
}

run_operations() {
  local requested_mode="$1"
  local affect_exit="$2"
  local saved_mode="$mode"
  local target skill failed

  mode="$requested_mode"

  for target in "${selected_targets[@]}"; do
    for skill in "${skills_to_process[@]}"; do
      operation_status=""
      operation_detail=""
      failed=0

      case "$requested_mode" in
        check)
          check_skill "$target" "$skill" || failed=1
          ;;
        remove)
          remove_skill "$target" "$skill" || failed=1
          ;;
        sync)
          sync_skill "$target" "$skill" || failed=1
          ;;
        *)
          echo "Unknown mode: $requested_mode" >&2
          exit 2
          ;;
      esac

      if (( failed )) && [[ "$affect_exit" == "yes" ]]; then
        exit_status=1
      fi

      if [[ -z "$operation_status" ]]; then
        operation_status="error"
        operation_detail="operation did not report a status"

        if [[ "$affect_exit" == "yes" ]]; then
          exit_status=1
        fi
      fi

      record_result "$target" "$skill" "$operation_status" "$operation_detail"
    done
  done

  mode="$saved_mode"
}

select_project_status_skills() {
  local target root entry skill
  typeset -A installed_skills

  project_status_skills=()

  if [[ "${#skill_args[@]}" -gt 0 ]]; then
    project_status_skills=("${skills_to_process[@]}")
    return
  fi

  for target in "${table_targets[@]}"; do
    root="${target_roots[$target]}"

    for entry in "$root"/*(N/); do
      skill="${entry:t}"

      if [[ -n "${repo_skill_dirs[$skill]:-}" ]]; then
        installed_skills[$skill]=1
      fi
    done
  done

  for skill in "${repo_skills[@]}"; do
    if [[ -n "${installed_skills[$skill]:-}" ]]; then
      project_status_skills+=("$skill")
    fi
  done
}

print_registered_project_sections() {
  local saved_skills=("${skills_to_process[@]}")
  local project affect_exit

  load_project_registry || return

  if [[ "$mode" == "check" ]]; then
    affect_exit="yes"
  else
    affect_exit="no"
  fi

  for project in "${project_registry[@]}"; do
    if [[ ! -d "$project" ]]; then
      printf "\n%s\n" "$(display_path "$project")"
      echo "  ERROR project directory does not exist: $project"

      if [[ "$mode" == "check" ]]; then
        exit_status=1
      fi

      continue
    fi

    set_project_target_roots "$project"
    select_project_status_skills

    if [[ "${#project_status_skills[@]}" -eq 0 ]]; then
      continue
    fi

    skills_to_process=("${project_status_skills[@]}")
    reset_results
    run_operations "check" "$affect_exit"
    fill_untouched_target_results

    printf "\n%s\n" "$(display_path "$project")"
    print_status_table
  done

  skills_to_process=("${saved_skills[@]}")
  set_global_target_roots
}

validate_project_arg

if [[ "$mode" == "list" && -n "$project_arg" ]]; then
  echo "--project cannot be used with --list." >&2
  usage >&2
  exit 2
fi

set_global_target_roots

if [[ -n "$project_arg" ]]; then
  set_project_target_roots "$project_arg"
fi

load_repo_skills
select_targets
set_table_targets

if [[ "$mode" == "remove" && "${#skill_args[@]}" -eq 0 ]]; then
  echo "--remove requires at least one repo-defined skill name." >&2
  exit 2
fi

select_skills || exit "$exit_status"

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

reset_results
run_operations "$mode" "yes"
fill_untouched_target_results

if [[ -n "$project_arg" && "$mode" == "sync" && "$exit_status" -eq 0 ]]; then
  register_project "$project_arg" || exit_status=1
fi

if [[ -n "$project_arg" ]]; then
  echo "$(display_path "$project_arg")"
fi

print_status_table

if [[ -z "$project_arg" ]]; then
  print_registered_project_sections
fi

exit "$exit_status"
