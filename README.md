# work-units

A Claude Code plugin that takes a request, from a one-line bug fix to a whole application, and handles it end to end. It strengthens the specification, splits the task into **work units** with explicit dependencies, runs independent units in parallel subagents, has each one adversarially reviewed, then, if you allow it, commits and merges the result.

You talk to one orchestrator. It delegates everything else.

## How it works

```
/work-units:task
 │
 ├─ worktree-specialist ──────────── isolates the work in a git worktree when needed
 │    └─ database-isolation-specialist (one per database)
 │
 ├─ new-task ─────────────────────── writes task.md
 │    ├─ specification-strengthener ── fills gaps and fixes weak spots in specs/
 │    └─ task-to-work-unit-splitter ── breaks the task into work units + dependencies
 │
 └─ work-unit-executor × N ───────── runs every unblocked unit in parallel,
                                      each followed by an independent adversarial review
```

1. **Worktree.** If a `task.md` already exists in the repo root, or other agents are working on the main worktree, a new git worktree is created so the task gets its own copy of the codebase, build and databases. Otherwise the task runs in the repo root.
2. **Specification.** The request is checked against `specs/`. Missing decisions, wrong assumptions and vague requirements are fixed before any code is written. With manual specification approval (the default), you're shown the spec files that were created, modified or deleted, and planning starts only after you approve them.
3. **Planning.** `task.md` is written with a description of the task and a list of work units. Each unit lists the units it depends on.
4. **Execution.** Every unit whose dependencies are complete gets its own `work-unit-executor`. When a unit finishes, the orchestrator re-reads `task.md` and starts whatever has become unblocked.
5. **Wrap-up.** When every unit is complete, `task.md` is archived to `task-history/`. With auto commit on, the archive is committed to `main` and the worktree is removed. With it off (the default), nothing is committed and the worktree is kept, so you can review, commit and merge the changes yourself.

### Agents

| Agent | Role |
| --- | --- |
| `task` (skill) | Orchestrator and the only one that talks to you. Dispatches agents and relays their questions. |
| `worktree-specialist` | Decides whether a new worktree is needed, creates it, and checks the result with an adversarial reviewer. |
| `database-isolation-specialist` | Picks and applies an isolation strategy per database (e.g. a copied SQLite file, a separate Docker Compose project, or a separate Postgres database) and records it in `DATABASE-ISOLATION-STRATEGIES.md` for reuse. |
| `new-task` | Turns the request into `task.md`. |
| `specification-strengthener` | Brings `specs/` up to the level the task needs. |
| `task-to-work-unit-splitter` | Splits the task into work units sized for a single session and classifies their dependencies. |
| `work-unit-executor` | Plans, implements and tests one unit, then has a fresh subagent try to break it before marking the unit complete. |

## Requirements

- [Claude Code](https://docs.claude.com/en/docs/claude-code/overview)
- A git repository with a `main` branch
- Optional: the `chrome-devtools-mcp`, `claude-in-chrome` or `playwright` plugins, used to test web apps in a browser, and the `frontend-design` skill, used for UI work

## Installation

Install once from inside Claude Code:

```
/plugin install work-units --marketplace danmvale/work-units-plugin
```

Or from your terminal:

```bash
claude plugin install work-units --marketplace danmvale/work-units-plugin
```

This adds the repository as a plugin marketplace and installs the plugin for your user, so `/work-units:task` is available in every project from then on. Add `--scope project` to the terminal command to install it only for the current project and share it with your team through `.claude/settings.json`.

On Claude Code versions before 2.1.275, which can't do this in one step, add the marketplace first:

```
/plugin marketplace add danmvale/work-units-plugin
/plugin install work-units@work-units
```

To get the latest version later:

```bash
claude plugin marketplace update work-units
claude plugin update work-units@work-units
```

Then restart Claude Code, or run `/reload-plugins` in a running session, to load the new version.

To get new versions automatically, enable auto-update once from inside Claude Code: run `/plugin`, open the **Marketplaces** tab, select `work-units`, and choose **Enable auto-update**. Claude Code then checks for updates in the background and asks you to run `/reload-plugins` when one arrives.

## Usage

Run the skill in your project and describe what you want:

```
/work-units:task Add CSV export to the reports page
```

If your prompt doesn't include a participation mode, an auto commit setting or a specification approval setting, the orchestrator asks for them.

### User participation mode

This sets how often agents stop to ask you something. Questions from nested subagents reach you through the orchestrator, labeled with the agent path they came from (for example `new-task -> specification-strengthener`).

| Mode | Behavior |
| --- | --- |
| `0` | Never asks. Every decision is made by the agents. |
| `1` | Asks only when it truly cannot continue without you. |
| `2` (default) | Decides when the right choice is obvious and asks about significant design or technical decisions. |
| `3` | Asks about every project decision. |

To set it up front, put it in the prompt:

```
/work-units:task Add CSV export to the reports page. user_participation_mode: 0
```

### Auto commit

This sets whether agents commit the work for you. It's recorded in `task.md`, so a resumed task keeps it.

| Value | Behavior |
| --- | --- |
| `no` (default) | Nothing is committed, merged or pushed unless you explicitly ask. Changes are left uncommitted and the worktree, if one was created, is kept. |
| `yes` | A Git work unit commits the work and merges it into `main`, the archived task is committed to `main`, and the worktree is removed. |

To set it up front, put it in the prompt:

```
/work-units:task Add CSV export to the reports page. auto_commit: yes
```

### Specification approval

This sets whether you review the specification before the task is planned.

| Value | Behavior |
| --- | --- |
| `manual` (default) | Once `specs/` is written, the orchestrator lists the files that were created, modified or deleted and asks you to approve them. If you request changes, the specification is revised and you're asked again. `task.md` is created only after you approve. This happens in every participation mode, including `0`. |
| `auto` | The specification is approved automatically and planning starts right away. |

To set it up front, put it in the prompt:

```
/work-units:task Add CSV export to the reports page. spec_approval: auto
```

### Resuming

All progress lives in `task.md`. If a session is interrupted, run `/work-units:task` again in the same worktree: the orchestrator finds the existing `task.md` and picks up the units that are not yet complete. An executor whose context reaches 500k tokens is told by a hook to stop: it writes a handoff note into `task.md` and leaves the unit `In Progress` so a fresh executor can finish it.

## Files it creates in your project

| Path | Purpose |
| --- | --- |
| `specs/` | The project specification, maintained by `specification-strengthener`. |
| `src/` | The implementation. |
| `task.md` | The active task: description, a status line per unit, and each unit's dependencies, description, report and notes for later agents. |
| `task-history/` | Completed tasks, named `{id:000}-{task-name}-{mm-dd-yyyy}`. |
| `DATABASE-ISOLATION-STRATEGIES.md` | Isolation strategy per database, reused by later worktrees. |

`task.md` looks like this:

```markdown
# Task: Add CSV export | In Progress
Init date: 2026-10-13
Auto commit: no

<task description>

# Status
## 1. Export endpoint | Completed
## 2. Export button | In Progress
## 3. Security review | Not Started

# Work units
## Work unit 1 - Export endpoint | Completed
### Dependencies
None

### Description
...

### What was done
...

### Notes for next agents
...
```

## Before you use it

- **It's opinionated about layout.** It expects (and will create) `specs/` for the specification and `src/` for the code.
- **It only commits when you let it.** With `auto_commit: yes`, the Git work unit and the final archive step both commit to `main`. With `no` (the default), all changes are left uncommitted.
- **It holds everything to production standards.** Agents are told to treat the project as production code, so even small changes get security and verification passes unless the splitter decides they aren't needed.

## Project structure

```
.claude-plugin/plugin.json        Plugin manifest
.claude-plugin/marketplace.json   Marketplace manifest (makes the repo installable)
skills/task/SKILL.md              The /work-units:task orchestrator
agents/                           Subagent definitions
hooks/hooks.json                  Registers the context-limit hook
hooks/context-limit.sh            Tells an executor to hand off once its context reaches 500k tokens
hooks/context-limit.ps1           PowerShell port of context-limit.sh, for Windows without Git Bash
```
