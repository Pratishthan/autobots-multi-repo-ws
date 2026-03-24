---
name: verify
description: Run format-check, lint, type-check, and tests across all repos or a specific repo. Use after making changes to verify everything passes.
---

# /verify — Full verification pass

Run the quality checks for this workspace. Accept an optional repo name argument to scope the checks.

## Execution

If `$ARGUMENTS` specifies a repo name (e.g., `autobots-agents-jarvis`), run checks only in that repo.
Otherwise, run checks across all repos from the workspace root.

### Single repo (when $ARGUMENTS is provided)

```bash
cd $ARGUMENTS
make check-format
make type-check
make test-fast
```

### All repos (no arguments)

```bash
# From workspace root
make all-checks
```

## Rules

1. Run each command sequentially — stop and report on the first failure.
2. Show the full output of any failing command so the user can see what went wrong.
3. If all checks pass, report success with a one-line summary.
4. Do NOT auto-fix issues. Report them and let the user decide.
