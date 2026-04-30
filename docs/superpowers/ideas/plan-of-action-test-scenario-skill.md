# Plan of Action — `writing-test-scenario-specs` Skill

## Goal

Create a superpowers skill that **hard-gates** the transition from
`writing-plans` to `subagent-driven-development`, requiring you to author
and approve a BDD-style scenario spec before any implementation begins.

---

## Step 1 — Scaffold the skill directory

**What:** Create the skill folder in your personal superpowers skills area.

```
~/.claude/skills/writing-test-scenario-specs/
├── SKILL.md                          # Main skill definition
├── scenario-spec-template.md         # The LLD §11 format template (your format)
├── spec-to-pytest-prompt.md          # Subagent prompt: translate spec → pytest
└── spec-reviewer-prompt.md           # Subagent prompt: review spec ↔ test mapping
```

**Why this structure:** Superpowers discovers `SKILL.md` via frontmatter. The
three supporting files are read on-demand by the skill — they don't consume
context tokens until needed.

**Do this in:** Claude Code terminal.

---

## Step 2 — Write the SKILL.md

**What:** Author the skill definition with proper frontmatter, hard gates,
and a process flowchart.

### Frontmatter (must be under 1024 chars total)

```yaml
---
name: writing-test-scenario-specs
description: >
  Use after writing-plans produces an approved implementation plan
  and BEFORE subagent-driven-development begins. Guides the user
  through authoring a BDD-style test scenario spec that becomes
  the acceptance criteria for the feature.
---
```

### Key sections to include in the body

1. **HARD-GATE declaration** — The critical enforcement:
   ```
   <HARD-GATE>
   Do NOT invoke subagent-driven-development, execute any implementation
   task, or write any code until the user has authored a test scenario spec
   and explicitly approved it.
   </HARD-GATE>
   ```

2. **When this skill activates** — After `writing-plans` saves a plan file
   and before the user says "go" to start implementation.

3. **Process flow** (graphviz notation per superpowers conventions):
   ```
   "Plan approved" -> "Present scenario spec template"
   "Present scenario spec template" -> "User authors scenario rows"
   "User authors scenario rows" -> "Agent generates pytest from spec"
   "Agent generates pytest from spec" -> "User reviews spec ↔ test mapping"
   "User reviews spec ↔ test mapping" -> "Tests match spec?" 
   "Tests match spec?" -> "Commit RED tests" [label="yes"]
   "Tests match spec?" -> "User authors scenario rows" [label="no, missing scenarios"]
   "Commit RED tests" -> "Invoke subagent-driven-development"
   ```

4. **What the user authors** — Scenario tables in the template format
   (sections 1.0–1.4: test data, positive, negative, edge cases, sanity).
   The user writes scenario names, steps, and expected results — never
   test code.

5. **What the agent does** — Reads the spec, translates each row to a
   pytest function using `spec-to-pytest-prompt.md`, presents the mapping
   for review.

6. **File locations** —
   - Spec saved to: `docs/superpowers/specs/YYYY-MM-DD-<feature>-test-scenarios.md`
   - Generated tests saved to: `tests/` following existing project conventions
   - Spec committed alongside RED tests in the same commit

7. **Red flags — STOP and redirect**:
   - Agent writes test code before spec is authored → Delete it
   - Agent invents scenarios not in the spec → Remove them
   - "The plan already covers testing" → No. Plan covers tasks. Spec covers acceptance.
   - "This is too simple to need a spec" → Especially then. Simple features drift silently.

**Do this in:** Claude Code — ask Claude to help you author the SKILL.md
using `superpowers:writing-skills` (it will TDD the skill for you).

---

## Step 3 — Create the scenario spec template

**What:** Take the template we built (the guardrails example) and
generalise it into a reusable template with placeholder instructions.

This file is `scenario-spec-template.md` — the agent presents it to you
after plan approval, and you fill in the scenario rows.

### Template sections

```markdown
# Test Scenario Spec — {Feature Name}

| Field       | Value                          |
| ----------- | ------------------------------ |
| Feature     | {DYN-X}: {Feature title}       |
| Author      | doc_pk                         |
| Plan ref    | docs/superpowers/plans/{plan}  |
| Status      | Draft                          |

## 1.0 Test Data
<!-- Data sets needed by the scenarios below.
     Each row = a named fixture the agent will create. -->

## 1.1 Positive Tests
<!-- Happy paths. Each row = one pytest function.
     Columns: Scenario Name | Service/Unit | Priority | Preconditions | Steps | Expected Result | Reference Models -->

## 1.2 Negative Tests
<!-- Failure modes. What should break, and how. -->

## 1.3 Edge Cases
<!-- Boundary conditions, empty inputs, concurrency, etc. -->

## 1.4 Sanity Scenarios
<!-- End-to-end smoke tests run against the real system.
     Columns: Scenario Name | Steps | Assertions -->
```

**Do this in:** Claude Code — create the file in the skill directory.

---

## Step 4 — Write the spec-to-pytest subagent prompt

**What:** A prompt template that a subagent reads to mechanically translate
your scenario spec into pytest code.

### Key instructions for the subagent

- Read `dynagent_samples.py` and `CLAUDE.md` for framework patterns
- Each scenario row → one `test_` function, named from the scenario name
  (lowercased, underscored)
- Preconditions → pytest fixtures or setup within the test
- Steps → sequential calls in the test body
- Expected Result → assert statements
- Reference Models → imports and mock setup
- Test data rows → `@pytest.fixture` definitions or `@pytest.mark.parametrize`
- Do NOT invent scenarios beyond what the spec contains
- Do NOT skip any scenario row — every row must have a test

**Do this in:** Claude Code — create `spec-to-pytest-prompt.md` in the
skill directory.

---

## Step 5 — Write the spec reviewer prompt

**What:** A prompt template for a reviewer subagent that validates the
mapping between your spec and the generated tests.

### What the reviewer checks

1. **Coverage** — every scenario row has a matching test function
2. **Naming** — test name derives from scenario name (traceable)
3. **Assertions** — expected results from the spec appear as asserts
4. **No extras** — no test functions exist that don't trace to a spec row
5. **Framework compliance** — tests follow `dynagent_samples.py` patterns
   (ToolRuntime mocking, AgentMeta.reset(), fixture conventions)

**Do this in:** Claude Code — create `spec-reviewer-prompt.md` in the
skill directory.

---

## Step 6 — Test the skill with subagent pressure scenarios

**What:** Follow superpowers TDD for skills — test BEFORE deploying.

### Pressure scenarios to run WITHOUT the skill (baseline)

1. Give a subagent an approved plan and say "go" — does it jump straight
   to implementation? (Expected: yes, this is the behaviour you want to fix)
2. Give a subagent a plan and say "write the tests first" — does it write
   tests from the plan tasks or from acceptance criteria? (Expected: from
   tasks, not from requirements)

### Pressure scenarios to run WITH the skill

1. Same as above — does the agent stop and present the template?
2. Try saying "skip the spec, just implement" — does the hard gate hold?
3. Try providing a partial spec (only positive tests) — does the agent
   ask about negative/edge cases?

**Do this in:** Claude Code — use fresh subagent sessions for each test.

---

## Step 7 — Wire into your existing workflow

**What:** Update the transition point between `writing-plans` and
`subagent-driven-development` so this skill activates automatically.

### Option A: Modify writing-plans exit (recommended)

Add a line at the end of the `writing-plans` skill's transition section:

```
After user approves the plan:
→ Invoke superpowers:writing-test-scenario-specs before proceeding
  to subagent-driven-development
```

### Option B: Modify subagent-driven-development entry

Add a precondition check at the top of `subagent-driven-development`:

```
Before executing any task:
→ Check: does a test scenario spec exist for this feature?
→ If no: invoke superpowers:writing-test-scenario-specs
→ If yes: proceed with implementation (tests are already RED)
```

### Which to pick

Option A is cleaner — it makes the spec a natural step in the plan-to-
implement transition. Option B is a safety net. You could do both.

**Do this in:** Claude Code — edit the relevant SKILL.md files. Since
superpowers skills live in a git repo, this is a PR against your fork.

---

## Step 8 — First real use

**What:** Use the skill on your next Dynagent feature (guardrails is the
natural candidate since we already have a draft spec).

### Workflow you'll experience

1. Brainstorm the guardrails feature → design approved
2. `writing-plans` produces the implementation plan → plan approved
3. **NEW:** `writing-test-scenario-specs` activates:
   - Presents the template
   - You fill in scenario rows (you already have the guardrails draft)
   - Agent generates pytest from your spec
   - You review the mapping — approve or add scenarios
   - RED tests committed
4. `subagent-driven-development` begins — subagents implement until GREEN
5. PR review = "do my tests pass?" → merge

### Success criteria

- You authored the spec in < 15 minutes (faster than reviewing a 40-file PR)
- Every test traces to a scenario row you wrote
- PR review took < 5 minutes (check GREEN, check no drift, merge)

---

## Summary — What you're building

| Artifact                        | Purpose                                       | Effort   |
| ------------------------------- | --------------------------------------------- | -------- |
| `SKILL.md`                      | Skill definition with hard gate + flow         | ~30 min  |
| `scenario-spec-template.md`     | Your LLD §11 format, generalised               | ~10 min  |
| `spec-to-pytest-prompt.md`      | Subagent translates spec → pytest              | ~20 min  |
| `spec-reviewer-prompt.md`       | Subagent validates spec ↔ test mapping          | ~15 min  |
| Pressure tests (6 scenarios)    | TDD for the skill itself                        | ~30 min  |
| Wiring (writing-plans exit)     | Activate the skill in the workflow              | ~10 min  |
| **Total**                       |                                                 | **~2 hr** |

After this, every feature you build goes through your scenario spec
before a single line of implementation is written. PR review becomes
trivial because the tests are *your* acceptance criteria, not the
agent's interpretation.
