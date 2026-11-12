# agentic-engineering-patterns

![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)
![PRs welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)
![Dependencies: none](https://img.shields.io/badge/dependencies-none-lightgrey.svg)

Practical patterns and small, dependency-free tooling for running coding agents
(Claude Code, Aider, Codex CLI, and similar) on real repositories.

The repo targets four recurring failure modes:

1. **Context bloat**: too many files in the prompt, invented imports
2. **Parallel-agent conflicts**: several agents editing one working directory
3. **Runaway fix loops**: an agent breaks test B while fixing test A, forever
4. **Unreviewed output**: a model reviewing its own code shares its blind spots

Everything referenced in this README exists in this repo. Scripts are plain Bash or Python.

---

## Table of contents

- [Repository layout](#repository-layout)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Tooling reference](#tooling-reference)
  - [repo-map.py](#scriptsrepo-mappy)
  - [parallel-worktrees.sh](#scriptsparallel-worktreessh)
  - [circuit-breaker.sh](#scriptscircuit-breakersh)
  - [lock-tests.sh](#scriptslock-testssh)
  - [ci-autofix.yml](#workflowsci-autofixyml)
  - [adversarial-reviewer.md](#promptsadversarial-reviewermd)
  - [MCP read-only Postgres](#mcp-configs)
  - [.ai templates](#templatesai)
- [Patterns](#patterns)
- [Recommended end-to-end workflow](#recommended-end-to-end-workflow)
- [Safety notes](#safety-notes)
- [Known limitations](#known-limitations)
- [Status](#status)
- [Contributing](#contributing)
- [License](#license)

---

## Repository layout

```
agentic-engineering-patterns/
├── README.md
├── LICENSE
├── scripts/
│   ├── repo-map.py              # signature-only repo map for LLM context
│   ├── parallel-worktrees.sh    # N agents, N isolated git worktrees
│   ├── circuit-breaker.sh       # stop/rollback runaway fix loops
│   └── lock-tests.sh            # keep agents from editing tests
├── workflows/
│   └── ci-autofix.yml           # CI failure -> headless agent -> draft PR (template)
├── prompts/
│   └── adversarial-reviewer.md  # bug-only review prompt for a second model
├── mcp-configs/
│   ├── readonly-postgres.json   # MCP server config (example)
│   └── README.md                # DB-level read-only role setup
└── templates/
    └── ai/
        ├── ARCHITECTURE.md      # starter: data flow and module boundaries
        ├── ANTI_PATTERNS.md     # starter: banned libs and conventions
        └── COMMANDS.md          # starter: exact typecheck/lint/test commands
```

## Requirements

| Tool | Version | Used by |
| :--- | :--- | :--- |
| Bash | 4+ | all `.sh` scripts |
| Git | 2.38+ (for `merge-tree --write-tree`) | `parallel-worktrees.sh`, `circuit-breaker.sh`, `lock-tests.sh` |
| Python | 3.9+ (for `ast.unparse`) | `repo-map.py` |
| An agent CLI | any headless one, e.g. `claude -p` | worktrees, breaker, CI workflow |

No packages to install.

## Quick start

```bash
git clone https://github.com/ionox-creator/AEP-.git
cd AEP-

# 1. Build a context map of your project
python3 scripts/repo-map.py /path/to/your/project --out /path/to/your/project/.ai/REPO_MAP.txt

# 2. Copy the agent-context templates into your project
cp -r templates/ai /path/to/your/project/.ai

# 3. Wrap a fix loop with a safety net (run inside your project, clean git tree)
/path/to/AEP-/scripts/circuit-breaker.sh \
  --test "npm test" \
  --agent "claude -p 'Fix the failing tests without editing test files'"
```

---

## Tooling reference

### `scripts/repo-map.py`

Prints a compact map of file paths and public signatures so an agent can navigate a repo
without reading every file body.

```
repo-map.py [ROOT] [--max-files N] [--out FILE]
```

| Option | Default | Meaning |
| :--- | :--- | :--- |
| `ROOT` | `.` | Directory to scan |
| `--max-files` | `500` | Stop after N files that contain signatures |
| `--out` | stdout | Write to a file instead |

- **Python** (`.py`): parsed with the standard `ast` module. Emits top-level functions
  (with argument lists and return annotations), classes, and public methods.
- **JS/TS** (`.js .jsx .ts .tsx`): regex-based. Emits exported functions, classes,
  interfaces, types, and exported arrow-function constants.
- Skipped directories: `.git`, `node_modules`, `venv`, `.venv`, `__pycache__`, `dist`, `build`, `.next`, `.ai`.

Example output:

```
repo-map.py
  def py_signatures(path)
  def ts_signatures(path)
  def main()
```

### `scripts/parallel-worktrees.sh`

Runs several headless agents at once, each on its own branch in its own `git worktree`,
so they cannot overwrite each other's files.

```
parallel-worktrees.sh run "name:prompt" ["name:prompt" ...]
parallel-worktrees.sh status
parallel-worktrees.sh merge-check
parallel-worktrees.sh clean
```

| Subcommand | What it does |
| :--- | :--- |
| `run` | For each `name:prompt`, creates branch `agent/<name>` and a worktree, runs the agent there in the background, logs to `<WT_DIR>/<name>.log`, and appends `exit=<code>` when done. Waits for all agents. |
| `status` | Lists worktrees and the last line (exit code) of each log |
| `merge-check` | Dry-run merges every `agent/*` branch into `BASE_BRANCH` and prints `OK` or `CONFLICT` without touching your tree |
| `clean` | Removes the worktrees and deletes the `agent/*` branches |

| Env var | Default | Meaning |
| :--- | :--- | :--- |
| `AGENT_CMD` | `claude -p` | Command that receives the prompt as its last argument |
| `BASE_BRANCH` | `main` | Branch to fork from and merge-check against |
| `WT_DIR` | `<repo>/../.agent-worktrees` | Where worktrees and logs live |

```bash
AGENT_CMD="aider --yes --message" scripts/parallel-worktrees.sh run \
  "fix-auth:Fix the token refresh bug from issue 42" \
  "csv-export:Add CSV export to the reports endpoint"
scripts/parallel-worktrees.sh merge-check
```

### `scripts/circuit-breaker.sh`

Wraps an agent in a bounded loop. After each attempt it runs your tests and counts failure
lines. If the count does not improve for `--patience` consecutive attempts, it rolls back to
the starting commit and exits with code `2` so you can escalate to a stronger model or a human.

```
circuit-breaker.sh --test "<cmd>" --agent "<cmd>" \
  [--max-attempts 5] [--patience 2] [--fail-pattern 'FAIL|FAILED|Error']
```

| Option | Default | Meaning |
| :--- | :--- | :--- |
| `--test` | required | Command that runs your tests |
| `--agent` | required | Command that makes one fix attempt |
| `--max-attempts` | `5` | Hard cap on attempts |
| `--patience` | `2` | Consecutive non-improving attempts tolerated |
| `--fail-pattern` | `FAIL\|FAILED\|Error` | Regex (grep -E) counted per output line as a failure |

| Exit code | Meaning |
| :--- | :--- |
| `0` | Tests pass (or were already passing) |
| `1` | Usage error, not a git repo, or dirty working tree |
| `2` | Rolled back; escalate |

The working tree must be clean at start because rollback runs `git reset --hard` and `git clean -fd`.

### `scripts/lock-tests.sh`

Stops the classic agent shortcut of making CI green by weakening or deleting tests.

```
lock-tests.sh lock   [tests_dir]              # chmod a-w (soft lock, default dir: tests)
lock-tests.sh unlock [tests_dir]
lock-tests.sh verify <base_ref> [tests_dir]   # exit 1 if tests differ from base_ref
```

`lock` is advisory: an agent running as your user can undo it. `verify` is the enforceable
check, so run it in CI (`lock-tests.sh verify origin/main tests`) on agent-authored branches.

### `workflows/ci-autofix.yml`

GitHub Actions **template**. Trigger: the workflow named `CI` completes with `failure` on a
non-`main` branch. Steps: fetch the last 300 lines of failed logs, run a headless agent
(`claude -p`, max 15 turns) with instructions to make a minimal fix and not edit tests, then open a
**draft** pull request.

To use it: move it to `.github/workflows/`, change the `workflows: ["CI"]` name to match your
pipeline, and add an `ANTHROPIC_API_KEY` repository secret. Review every draft PR; there is no auto-merge.

### `prompts/adversarial-reviewer.md`

A system prompt for a *second* model that reviews a diff. It restricts output to five categories
(correctness, concurrency, security, data integrity, test gaps), requires `file:line`, severity,
a concrete failing scenario, and a minimal fix, and forbids praise and style nits. Findings
marked `unverified` need manual confirmation.

### `mcp-configs/`

`readonly-postgres.json` is an example MCP server entry for read-only database exploration.
The accompanying `README.md` shows the SQL to create an `agent_ro` role with `SELECT` only and
`default_transaction_read_only = on`, which is the actual safety boundary. Point it at a replica
or a sanitized copy.

### `templates/ai/`

Starter files for a small in-repo context directory:

| File | Put here |
| :--- | :--- |
| `ARCHITECTURE.md` | Entry points, data flow, module boundaries, external services |
| `ANTI_PATTERNS.md` | "Never use X, use wrapper Y", generated files not to edit, API-change rules |
| `COMMANDS.md` | Exact commands for typecheck, lint, single-test, full suite, dev server |

---

## Patterns

Each pattern states the problem, the mitigation, and the trade-off.

| # | Problem | Pattern | Tooling | Trade-off |
| :-- | :--- | :--- | :--- | :--- |
| 1 | Long context degrades attention; imports get invented | Signature map first, open file bodies on demand | `repo-map.py` | Signatures omit behavior; JS/TS extraction is heuristic |
| 2 | Parallel agents overwrite each other | One branch + worktree per task, merge-check before integrating | `parallel-worktrees.sh` | Prevents file clobbering, not semantic conflicts |
| 3 | Fix loop never converges | Track failure count; rollback and escalate on stall | `circuit-breaker.sh` | Failure count is a text match on test output |
| 4 | Agent edits tests to pass | Write tests first, then freeze them; verify in CI | `lock-tests.sh` | `chmod` lock is advisory; CI `verify` is the real gate |
| 5 | Author-model blind spots | Review with a different model and an adversarial prompt | `adversarial-reviewer.md` | More cost; findings still need human verification |
| 6 | Exploration noise pollutes execution | Read-only planning session, then a fresh session with only `PLAN.md` | (process) | Extra step; plan must be reviewed to be worth it |
| 7 | Frontier-model spend on trivial work | Route by difficulty: small, mid, strongest | (process) | Needs measurement on your own repo |
| 8 | Agents ignore project conventions | Small modular `.ai/` files instead of one long prompt | `templates/ai/` | Files must be kept current |
| 9 | Schema drift (agent builds on stale docs) | Provide live schema/specs via MCP, read-only | `mcp-configs/` | Needs a safe replica; server maintenance varies |

### Pattern 6 in detail: plan, then execute

1. **Phase 1 (read-only):** the agent explores and writes `PLAN.md` with exact file paths,
   function signatures, and a risk list. No code changes.
2. A human reviews and edits the plan.
3. **Phase 2:** a fresh session receives only `PLAN.md` and the target files.

### Pattern 4 in detail: test-first agent loop

1. Restrict the agent to writing tests only; confirm the new test fails for the *right reason*.
2. Run `lock-tests.sh lock tests`.
3. Let the agent implement under `src/`.
4. In CI, run `lock-tests.sh verify origin/main tests`.

---

## Recommended end-to-end workflow

```
repo-map.py          -> .ai/REPO_MAP.txt            (context)
agent (read-only)    -> PLAN.md                     (plan, human-reviewed)
agent (tests only)   -> new failing tests           (spec as code)
lock-tests.sh lock   -> tests frozen
circuit-breaker.sh   -> implementation, bounded     (rollback on stall)
reviewer model       -> adversarial-reviewer.md     (second opinion)
CI: lock-tests.sh verify + your normal checks       (hard gate)
human review + merge
```

For several independent tasks, run the implementation step per task through
`parallel-worktrees.sh` and `merge-check` before integrating.

## Safety notes

- Run agents in a sandbox or container with least-privilege credentials.
- Never give an agent production database credentials; enforce read-only at the DB role level.
- `ci-autofix.yml` opens draft PRs only. Do not auto-merge agent output.
- `circuit-breaker.sh` runs `git reset --hard` and `git clean -fd` on rollback; use it on a clean tree.
- Treat agent-generated code like code from an untrusted contributor.

## Known limitations

- `repo-map.py` does not parse JS/TS; it uses regexes and can miss unusual export styles.
  Only Python and JS/TS are supported.
- `circuit-breaker.sh` measures progress by counting lines matching a regex, not by parsing
  structured test reports. Tune `--fail-pattern` per runner.
- `parallel-worktrees.sh` has no concurrency limit and no timeout per agent.
- `ci-autofix.yml` and the MCP config are templates and have not been run against a live
  pipeline or database.

## Status

The four scripts were exercised locally with Bash and Git: breaker rollback path (exit 2) and
success path (exit 0), worktree create / status / merge-check / clean, and detection of modified tests.
`ci-autofix.yml` and `readonly-postgres.json` were validated for syntax only.

## Contributing

Issues and PRs welcome. A good contribution includes the failure mode it addresses, a minimal
reproducible script or config, and its known limitations. Please keep dependencies at zero where possible.

## License

MIT. See [LICENSE](LICENSE).
