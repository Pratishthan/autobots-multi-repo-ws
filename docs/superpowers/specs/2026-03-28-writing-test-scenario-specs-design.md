# Writing Test Scenario Specs — Design Spec

**Date:** 2026-03-28
**Status:** Draft
**Author:** doc_pk
**PRD:** [prd-scenario-driven-testing.md](../ideas/prd-scenario-driven-testing.md)

## 1. Problem

In the current superpowers workflow, subagents own test authoring. They write both the failing test (RED) and the implementation (GREEN). The human steers the design and approves the plan, but never touches the acceptance criteria. PR review is the first time the human sees the tests — by then, reviewing 40+ files post-hoc is the only option.

The root cause: acceptance criteria are never authored by the human. Tests are the most important artifact (they define "done"), yet the human never touches them.

## 2. Solution

A new skill (`writing-test-scenario-specs`) that inserts a human-authored acceptance criteria step between planning and implementation. The human authors scenario tables in a structured markdown format (LLD Section 11), seeded by an agent from the design doc, and validated against the implementation plan.

The skill produces a scenario spec file — not code. Pytest generation is a separate concern (Phase 2: `subagent-driven-test-development`).

## 3. Goals

- Human controls acceptance criteria without writing test code
- Scenario spec is behavioral and implementation-agnostic (sourced from design doc, not plan)
- PR review collapses from "read 40 files" to "my tests pass? merge"
- Skill is portable — adapts to any project by reading its conventions at activation time

## 4. Non-Goals

- Generating pytest code from the spec (Phase 2: `subagent-driven-test-development`)
- Modifying the implementation plan
- Replacing existing unit/integration tests
- Enforcing the spec for existing features without specs (backward compatible)

## 5. Workflow Position

```
brainstorming → writing-plans → **writing-test-scenario-specs** → subagent-driven-test-development (Phase 2) → subagent-driven-development → finishing-a-development-branch
```

### Integration with existing skills

| Skill | Change |
|-------|--------|
| `writing-plans` | Add to handoff message: "Next: author your test scenario spec with `superpowers:writing-test-scenario-specs`" |
| `subagent-driven-development` | Add precondition check: scenario spec file must exist before proceeding (safety net, bypassable for existing features without specs) |
| `test-driven-development` | No change |
| `brainstorming` | No change |

### Linkage pattern

Follows the existing convention: each skill names its successor in its output text. The human explicitly invokes the next skill. No programmatic coupling between skills.

## 6. Skill Flow

### Step 1 — Collect inputs

Check if design doc and implementation plan paths are already available from prior handoff. If yes, confirm them with the human. If no (skill invoked in a fresh session), ask the human for the paths. Either way, read the project's `CLAUDE.md` and test directory conventions to adapt the template.

### Step 2 — Seed scenarios

Dispatch the **Scenario Seeder** subagent with: design doc, scenario spec template, project test conventions. Subagent reads the design doc end-to-end and proposes scenario tables (sections 1.0–1.4).

### Step 3 — Coarse approval

Present the seeded scenarios in the conversation as markdown tables. Human says "add X, remove Y, change Z." Iterate until the human says it looks roughly right.

### Step 4 — Write spec file

Write the approved scenarios to `docs/superpowers/specs/YYYY-MM-DD-<feature>-test-scenarios.md`. Tell the human the file is ready for fine-tuning in their editor if needed. Wait for the human to confirm they're done editing.

### Step 5 — Review against plan

Dispatch the **Test Scenario Reviewer** subagent with: scenario spec file + implementation plan. Reviewer flags coverage gaps and proposes draft scenario rows for each gap. Present findings to the human — they accept, modify, or reject each suggestion. Update the spec file if needed. Re-run reviewer until it approves (max 3 iterations, then surface to human).

### Step 6 — Final approval & commit

Ask the human to confirm the spec is complete. Commit the spec file. Announce the next step: invoke `subagent-driven-test-development` to generate RED tests from this spec (Phase 2).

## 7. Scenario Seeder Subagent

**Purpose:** Read the design doc and propose scenario tables in the LLD Section 11 format.

**Inputs:**
- Design doc path
- Scenario spec template
- Project test conventions (from CLAUDE.md / test directory inspection)

**Behavior:**
1. Reads the design doc end-to-end
2. Identifies testable behaviors — features, error handling, data flows, boundaries
3. Populates the template sections:
   - **1.0 Test Data** — named fixtures and sample data sets derived from the design's data models
   - **1.1 Positive Tests** — happy paths from the design's primary flows
   - **1.2 Negative Tests** — failure modes and error conditions mentioned in the design
   - **1.3 Edge Cases** — boundaries, empty inputs, concurrency concerns from the design
   - **1.4 Sanity Scenarios** — E2E smoke tests covering the design's main use case

**Constraints:**
- Only derive scenarios from what the design doc explicitly describes — do not invent requirements
- Adapt test conventions to the project (pytest markers, fixture patterns, naming)
- Each scenario row must be traceable to a specific section of the design doc

**Output:** Complete scenario tables as markdown, returned to the main skill for presentation.

## 8. Test Scenario Reviewer Subagent

**Purpose:** Validate the approved scenario spec against the implementation plan, catching coverage gaps the design-level seeding missed.

**Inputs:**
- Scenario spec file (approved by human)
- Implementation plan file

**Behavior:**
1. Reads the implementation plan task-by-task
2. For each task, identifies testable behaviors — error paths, edge cases, configuration options, integration points
3. Cross-references against the scenario spec — does a scenario exist that would exercise this behavior?
4. Produces a report

**Report format:**

| Category | Description |
|----------|-------------|
| **Covered** | Plan tasks with adequate scenario coverage (brief summary) |
| **Gaps** | Plan tasks with no matching scenario — includes draft scenario rows the human can accept/modify/reject |
| **Over-specified** | Scenarios that don't trace to any plan task (advisory, not blocking — the spec may intentionally cover design-level concerns the plan doesn't break into separate tasks) |

**Constraints:**
- Gaps must include draft scenario rows in the same table format (Scenario Name, Service/Unit, Priority, Preconditions, Steps, Expected Result, Reference Models)
- Over-specified is advisory only — the reviewer does not recommend removing scenarios
- Approve unless there are gaps. Stylistic feedback is not an issue.

**Loop:** Main skill presents findings to human → human accepts/modifies/rejects suggestions → spec file updated → re-dispatch reviewer → repeat until approved (max 3 iterations, then surface to human).

## 9. Scenario Spec Template

The template uses the LLD Section 11 format:

```markdown
# Test Scenario Spec — {Feature Name}

| Field       | Value                                |
| ----------- | ------------------------------------ |
| Feature     | {Feature title}                      |
| Author      | {author}                             |
| Design ref  | {path to design doc}                 |
| Plan ref    | {path to implementation plan}        |
| Status      | Draft                                |

---

## 1.0 Test Data

| Data Set Name | Model / Entity | Purpose | Sample Data | Notes |
| ------------- | -------------- | ------- | ----------- | ----- |
|               |                |         |             |       |

## 1.1 Positive Tests

| Scenario Name | Service / Unit | Priority | Preconditions | Steps | Expected Result | Reference Models |
| ------------- | -------------- | -------- | ------------- | ----- | --------------- | ---------------- |
|               |                |          |               |       |                 |                  |

## 1.2 Negative Tests

| Scenario Name | Service / Unit | Priority | Preconditions | Steps | Expected Result | Reference Models |
| ------------- | -------------- | -------- | ------------- | ----- | --------------- | ---------------- |
|               |                |          |               |       |                 |                  |

## 1.3 Edge Cases

| Scenario Name | Service / Unit | Priority | Preconditions | Steps | Expected Result | Reference Models |
| ------------- | -------------- | -------- | ------------- | ----- | --------------- | ---------------- |
|               |                |          |               |       |                 |                  |

## 1.4 Sanity Scenarios

| Scenario Name | Steps | Assertions |
| ------------- | ----- | ---------- |
|               |       |            |
```

## 10. Skill Directory Structure

```
~/.claude/skills/writing-test-scenario-specs/
├── SKILL.md                              # Main skill — flow, gates, human interaction
├── scenario-spec-template.md             # LLD Section 11 template (empty tables)
├── scenario-seeder-prompt.md             # Subagent: design doc → proposed scenarios
└── test-scenario-reviewer-prompt.md      # Subagent: spec vs plan coverage validation
```

**Frontmatter:**
```yaml
---
name: writing-test-scenario-specs
description: >
  Use after writing-plans produces an approved implementation plan
  and BEFORE implementation begins. Guides the user through authoring
  a BDD-style test scenario spec that becomes the acceptance criteria
  for the feature. Seeds scenarios from the design doc, validates
  coverage against the implementation plan.
---
```

**Spec file output location:** `docs/superpowers/specs/YYYY-MM-DD-<feature>-test-scenarios.md`
(User preferences for spec location override this default.)

## 11. Anti-Patterns

Rationalizations the skill must counter:

| Rationalization | Counter |
|-----------------|---------|
| "The plan already covers testing" | Plan covers tasks. Spec covers acceptance criteria. Different artifacts. |
| "This is too simple to need a spec" | Simple features drift silently. Present the template. |
| "I'll write the spec after implementation" | Spec-after is post-hoc justification, not acceptance criteria. |
| "Skip the spec, just implement" | Refuse. Re-present the template. |
| Agent writes test code before spec is authored | This skill does not generate code. If it happens, delete it and restart. |
| Agent invents scenarios not in the design doc | Remove them. Only design-doc-derived scenarios in the seed. |

## 12. Success Criteria

| Metric | Target |
|--------|--------|
| Time to author scenario spec | < 15 minutes per feature |
| Scenario traceability | 100% of scenarios trace to design doc |
| Coverage validation | Reviewer confirms no plan-level gaps (or gaps accepted by human) |
| Backward compatibility | Existing features without specs unaffected |
| Portability | Skill works in any project with a CLAUDE.md and test directory |

## 13. Phase 2: `subagent-driven-test-development`

A separate skill to be designed in a follow-up brainstorming session. It will:

- Take the approved scenario spec as input
- Translate each scenario row into a RED pytest function via a Spec-to-Pytest Translator subagent
- Validate the mapping via a Spec ↔ Test Mapping Reviewer subagent
- Support suggest-and-confirm for `@pytest.mark.parametrize` expansions (agent proposes, human approves)
- Commit RED tests together with the spec in one commit
- Hand off to `subagent-driven-development` for GREEN implementation

This skill will sit between `writing-test-scenario-specs` and `subagent-driven-development` in the workflow chain.

## 14. Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Authoring mode | Hybrid — agent seeds, human reviews/edits | Human retains authorship; design doc provides enough signal for seeding |
| Scenario source | Design doc only | Keeps scenarios behavioral and implementation-agnostic |
| Reviewer scope | Plan only | Design doc already used for seeding; reviewer catches implementation-level gaps |
| Reviewer gap handling | Flag with draft suggestions | Human decides whether to add; reviewer doesn't add silently |
| Workflow integration | Standalone skill, soft gate | Matches existing skill linkage pattern (text directives, not programmatic calls) |
| Portability | Generic with project detection | Reads CLAUDE.md and test conventions at activation; no project-specific patterns hard-coded |
| Interaction pattern | Conversation then file | Present seeds in chat for coarse approval, write file, human fine-tunes in editor |
| Pytest generation | Phase 2 (separate skill) | This skill produces a spec, not code; separates specification from implementation |

## Revision History

| Version | Date       | Author | Changes       |
| ------- | ---------- | ------ | ------------- |
| 1.0     | 2026-03-28 | doc_pk | Initial draft |
