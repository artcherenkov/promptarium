# Promptarium

При работе с несколькими ИИ-агентами нужно синхронизировать, версионировать и держать в понятной области видимости промпты, правила и скиллы. `promptarium` делает это управляемым: один источник правды, проверка расхождений и точная синхронизация туда, где инструкция реально нужна.

Идея простая: правишь всё здесь, а потом раскатываешь в нужные окружения – `Codex`, `Claude`, `~/.agents` или конкретный проект. Не нужно руками копировать `AGENTS.md`, `CLAUDE.md` и `SKILL.md` по разным папкам.

## Как Это Работает

Сначала можно проверить системные промпты. `--check` ничего не меняет:

```sh
_service/scripts/sync-agent-prompts.sh --check
```

```text
OK ~/.codex/AGENTS.md
OK ~/.claude/CLAUDE.md
OK ~/.agents/AGENTS.md
```

Синхронизировать системные промпты:

```sh
_service/scripts/sync-agent-prompts.sh
```

```text
UNCHANGED ~/.codex/AGENTS.md
UNCHANGED ~/.claude/CLAUDE.md
CREATED ~/.agents/AGENTS.md
```

Проверить скиллы:

```sh
_service/scripts/sync-skills.sh --check
```

```text
skill                               codex    claude   agents
occams-chainsaw-architecture        ok       ok       ok
review-parser-against-xsd           missing  missing  missing
thermo-nuclear-code-quality-review  ok       ok       ok

~/path/to/project
skill                      codex  claude   agents
review-parser-against-xsd  ok     missing  missing
```

Скилл можно раскатить только туда, где он нужен:

```sh
_service/scripts/sync-skills.sh --target codex,claude review-parser-against-xsd
```

```text
skill                      codex    claude   agents
review-parser-against-xsd  created  created  unchanged
```

## Видимость Скиллов

Глобально во все поддержанные окружения:

```sh
_service/scripts/sync-skills.sh
```

Только для одного агента:

```sh
_service/scripts/sync-skills.sh --target codex thermo-nuclear-code-quality-review
```

Для нескольких агентов:

```sh
_service/scripts/sync-skills.sh --target codex,claude occams-chainsaw-architecture
```

Только внутри конкретного проекта:

```sh
_service/scripts/sync-skills.sh --project /absolute/path/to/project --target codex review-parser-against-xsd
```

Проектная установка кладёт скилл сюда:

```text
<project>/.codex/skills/<name>/SKILL.md
<project>/.claude/skills/<name>/SKILL.md
<project>/.agents/skills/<name>/SKILL.md
```

Посмотреть, какие скиллы есть в репозитории:

```sh
_service/scripts/sync-skills.sh --list
```

```text
occams-chainsaw-architecture
review-parser-against-xsd
thermo-nuclear-code-quality-review
```

## Где Что Лежит

```text
system-rules/                 общие правила агентов
skills/<name>/skill-source.md исходник скилла
_service/scripts/             скрипты синхронизации
_service/skill-installations.txt
```

Исходник скилла – `skills/<name>/skill-source.md`. При синхронизации он устанавливается как `SKILL.md`.

## Справка

### sync-agent-prompts.sh

```sh
_service/scripts/sync-agent-prompts.sh --help
```

```text
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
```

### sync-skills.sh

```sh
_service/scripts/sync-skills.sh --help
```

```text
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
```
