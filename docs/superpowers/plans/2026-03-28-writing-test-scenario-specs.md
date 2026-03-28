# Writing Test Scenario Specs — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create the `writing-test-scenario-specs` superpowers skill — a human-in-the-loop workflow that seeds test scenario specs from design docs, collects human edits, and validates coverage against the implementation plan.

**Architecture:** A single SKILL.md drives a 6-step flow with two subagent prompts (Scenario Seeder, Test Scenario Reviewer). The skill reads project conventions at activation time for portability. Supporting files (template, subagent prompts) are loaded on-demand.

**Tech Stack:** Superpowers skill system (SKILL.md + supporting markdown files), Claude Code Agent tool for subagent dispatch.

**Spec:** `docs/superpowers/specs/2026-03-28-writing-test-scenario-specs-design.md`

**Reference implementation:** `docs/superpowers/ideas/guardrails-test-scenario-spec.md` (worked example of the scenario spec format)

---

## File Structure

All files live in `~/.claude/skills/writing-test-scenario-specs/`:

| File | Responsibility |
|------|---------------|
| `SKILL.md` | Main skill — frontmatter, 6-step flow, hard gates, anti-pattern counters, human interaction logic |
| `scenario-spec-template.md` | Empty LLD Section 11 template — copied into new spec files |
| `scenario-seeder-prompt.md` | Subagent dispatch template — reads design doc, proposes scenario tables |
| `test-scenario-reviewer-prompt.md` | Subagent dispatch template — validates spec against plan, flags gaps with draft rows |

Additionally, two existing skills need minor edits:

| File | Change |
|------|--------|
| `~/.claude/skills/writing-plans/SKILL.md` | Add handoff message naming this skill as next step |
| `~/.claude/skills/subagent-driven-development/SKILL.md` | Add soft precondition check for scenario spec file |

---

## Task 1: Create the scenario spec template

**Files:**
- Create: `~/.claude/skills/writing-test-scenario-specs/scenario-spec-template.md`

This is the simplest file — a direct transcription of the template from the design spec (Section 9). No logic, just structure.

- [ ] **Step 1: Write the template file**

Create `~/.claude/skills/writing-test-scenario-specs/scenario-spec-template.md` with the following content:

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

- [ ] **Step 2: Verify the template**

Read the file back and confirm it matches the design spec Section 9 exactly. Confirm the table headers match the guardrails worked example at `docs/superpowers/ideas/guardrails-test-scenario-spec.md`.

- [ ] **Step 3: Commit**

```bash
git add ~/.claude/skills/writing-test-scenario-specs/scenario-spec-template.md
git commit -m "feat: add scenario spec template for writing-test-scenario-specs skill"
```

---

## Task 2: Write the Scenario Seeder subagent prompt

**Files:**
- Create: `~/.claude/skills/writing-test-scenario-specs/scenario-seeder-prompt.md`
- Reference: `~/.claude/skills/brainstorming/spec-document-reviewer-prompt.md` (dispatch template pattern)
- Reference: Design spec Section 7 (Scenario Seeder Subagent)

The seeder reads a design doc and proposes scenario tables. It follows the same dispatch template pattern as the spec-document-reviewer — a markdown file with a prompt template containing placeholders for file paths.

- [ ] **Step 1: Write the seeder prompt file**

Create `~/.claude/skills/writing-test-scenario-specs/scenario-seeder-prompt.md`. The prompt must instruct the subagent to:

1. Read the design doc end-to-end
2. Read the scenario spec template for the exact table format
3. Read the project's CLAUDE.md and test directory for conventions (pytest markers, fixture patterns, naming)
4. Identify testable behaviors from the design doc — features, error handling, data flows, boundaries
5. Populate each template section:
   - 1.0 Test Data — named fixtures and sample data from the design's data models
   - 1.1 Positive Tests — happy paths from primary flows
   - 1.2 Negative Tests — failure modes and error conditions
   - 1.3 Edge Cases — boundaries, empty inputs, concurrency
   - 1.4 Sanity Scenarios — E2E smoke tests for the main use case
6. Return the completed tables as markdown

The prompt must include these constraints:
- Only derive scenarios from what the design doc explicitly describes — do not invent requirements
- Each scenario row must be traceable to a specific section of the design doc
- Adapt naming and conventions to the project (read from CLAUDE.md)

Use the dispatch template pattern from `spec-document-reviewer-prompt.md`:

```
# Scenario Seeder Prompt Template

Use this template when dispatching a scenario seeder subagent.

**Purpose:** Read the design doc and propose test scenario tables in LLD Section 11 format.

**Dispatch during:** Step 2 of the writing-test-scenario-specs skill flow.

Agent tool (general-purpose):
  description: "Seed scenario spec from design doc"
  prompt: |
    You are a scenario seeder. Read the design document and propose test
    scenario tables that the human will review and edit.

    **Design doc:** [DESIGN_DOC_PATH]
    **Scenario spec template:** [read ~/.claude/skills/writing-test-scenario-specs/scenario-spec-template.md]
    **Project conventions:** [read the project's CLAUDE.md and scan the test directory for naming/fixture patterns]

    ## Your Task
    ...

    ## Constraints
    ...

    ## Output Format

    Return the completed scenario tables as markdown — all five sections
    (1.0 through 1.4) with rows populated from the design doc. Include a
    brief note after each section citing which design doc section(s) the
    scenarios trace to.
```

Include the full prompt text — the implementer should be able to copy the file as-is.

- [ ] **Step 2: Validate against the guardrails example**

Read the guardrails worked example (`docs/superpowers/ideas/guardrails-test-scenario-spec.md`). Verify that the seeder prompt, if given the eval framework design doc as input, would plausibly produce scenarios in the same format and level of detail as the guardrails example. Specifically check:
- Table column headers match
- Scenario naming style matches (verb-noun, e.g. "single guardrail passes input")
- Preconditions and Steps are concrete (not vague)
- Expected Results are assertable

- [ ] **Step 3: Commit**

```bash
git add ~/.claude/skills/writing-test-scenario-specs/scenario-seeder-prompt.md
git commit -m "feat: add scenario seeder subagent prompt"
```

---

## Task 3: Write the Test Scenario Reviewer subagent prompt

**Files:**
- Create: `~/.claude/skills/writing-test-scenario-specs/test-scenario-reviewer-prompt.md`
- Reference: `~/.claude/skills/brainstorming/spec-document-reviewer-prompt.md` (dispatch template pattern)
- Reference: `~/.claude/skills/writing-plans/plan-document-reviewer-prompt.md` (cross-reference review pattern)
- Reference: Design spec Section 8 (Test Scenario Reviewer Subagent)

The reviewer validates the scenario spec against the implementation plan. It follows the same dispatch template pattern but with a cross-reference review (spec vs plan), similar to how the plan-document-reviewer cross-references plan vs spec.

- [ ] **Step 1: Write the reviewer prompt file**

Create `~/.claude/skills/writing-test-scenario-specs/test-scenario-reviewer-prompt.md`. The prompt must instruct the subagent to:

1. Read the scenario spec file
2. Read the implementation plan file
3. For each plan task, identify testable behaviors (error paths, edge cases, config options, integration points)
4. Cross-reference against the scenario spec
5. Produce a report with three categories:

| Category | Description |
|----------|-------------|
| **Covered** | Plan tasks with adequate scenario coverage (brief summary) |
| **Gaps** | Plan tasks with no matching scenario — include draft scenario rows in the same table format (Scenario Name, Service/Unit, Priority, Preconditions, Steps, Expected Result, Reference Models) |
| **Over-specified** | Scenarios that don't trace to any plan task (advisory, not blocking) |

The prompt must include these constraints:
- Gaps must include complete draft scenario rows — not just "add a test for X"
- Over-specified is advisory only — do not recommend removing scenarios
- Approve unless there are gaps. Stylistic feedback is not an issue.

Use this output format:

```
## Test Scenario Review

**Status:** Approved | Gaps Found

### Covered
- [Plan Task N]: [brief summary of matching scenarios]

### Gaps (if any)
- [Plan Task N]: [what's missing] — [why it matters]

  **Suggested scenario row:**

  | Scenario Name | Service / Unit | Priority | Preconditions | Steps | Expected Result | Reference Models |
  | --- | --- | --- | --- | --- | --- | --- |
  | [suggested name] | [unit] | [P1/P2/P3] | [preconditions] | [steps] | [expected result] | [models] |

### Over-specified (advisory)
- [Scenario Name]: traces to design doc but not to a specific plan task — likely intentional

### Recommendations (advisory, do not block approval)
- [suggestions]
```

Include the full prompt text.

- [ ] **Step 2: Validate the review categories**

Re-read the design spec Section 8. Confirm the prompt covers all three report categories (Covered, Gaps, Over-specified) and that the gap format includes complete draft scenario rows with all 7 columns.

- [ ] **Step 3: Commit**

```bash
git add ~/.claude/skills/writing-test-scenario-specs/test-scenario-reviewer-prompt.md
git commit -m "feat: add test scenario reviewer subagent prompt"
```

---

## Task 4: Write the main SKILL.md

**Files:**
- Create: `~/.claude/skills/writing-test-scenario-specs/SKILL.md`
- Reference: `~/.claude/skills/brainstorming/SKILL.md` (flow pattern with subagent dispatch + human gates)
- Reference: Design spec Sections 6, 10, 11 (flow, structure, anti-patterns)

This is the core file. It defines the 6-step flow, hard gates, anti-pattern counters, and subagent dispatch instructions. Pattern it after the brainstorming SKILL.md — structured checklist, hard gate at the top, flow diagram, and detailed step-by-step instructions.

- [ ] **Step 1: Write the SKILL.md skeleton with frontmatter and overview**

Create `~/.claude/skills/writing-test-scenario-specs/SKILL.md` with:

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

Add an overview section explaining:
- What this skill does (seeds scenario specs from design docs, human reviews, validates against plan)
- Where it sits in the workflow (after writing-plans, before implementation)
- What it produces (a scenario spec file, not code)

- [ ] **Step 2: Add the hard gate**

Add a `<HARD-GATE>` block (same pattern as brainstorming SKILL.md):

```markdown
<HARD-GATE>
Do NOT generate pytest code, invoke subagent-driven-development,
or take any implementation action. This skill produces a scenario
specification document — not test code. Test code generation is
Phase 2 (subagent-driven-test-development).
</HARD-GATE>
```

- [ ] **Step 3: Add the checklist**

Add a numbered checklist of the 6 steps (same pattern as brainstorming's checklist). Each item maps to a step from the design spec Section 6:

1. Collect inputs — confirm or request design doc and plan paths, read project conventions
2. Seed scenarios — dispatch Scenario Seeder subagent
3. Coarse approval — present seeds in chat, iterate with human
4. Write spec file — write to docs/superpowers/specs/, wait for human fine-tuning
5. Review against plan — dispatch Test Scenario Reviewer, handle gaps
6. Final approval & commit — commit spec, announce next step

- [ ] **Step 4: Add the flow diagram**

Add a `dot` (graphviz) flow diagram showing the 6 steps with decision points, matching the brainstorming skill's diagram style. Key decision points:
- Step 1: "Paths from handoff?" → yes: confirm / no: ask human
- Step 3: "Human approves?" → no: iterate / yes: proceed
- Step 5: "Reviewer approves?" → gaps found: present to human, loop / approved: proceed
- Step 5: "Max iterations?" → exceeded: surface to human

- [ ] **Step 5: Add detailed step instructions**

Write the detailed instructions for each of the 6 steps. For each step, include:
- What to do
- How to do it (which subagent to dispatch, what to present to human)
- When to proceed to the next step

For Step 1 (Collect inputs):
- Check if design doc and plan paths are in conversation context from prior handoff
- If yes, confirm with human: "I see the design doc at `<path>` and plan at `<path>`. Correct?"
- If no, ask the human for both paths
- Read the project's CLAUDE.md for test conventions (pytest markers, fixture patterns, naming, line length)
- Scan the test directory to detect existing patterns

For Step 2 (Seed scenarios):
- Dispatch Scenario Seeder subagent using the template in `scenario-seeder-prompt.md`
- Pass: design doc path, scenario spec template (read from `scenario-spec-template.md`), project conventions
- Receive: populated scenario tables

For Step 3 (Coarse approval):
- Present the seeded scenarios in chat as markdown tables
- Ask: "Review these scenarios. Add, remove, or change anything — or say 'looks good' to proceed."
- Iterate until the human approves

For Step 4 (Write spec file):
- Write to `docs/superpowers/specs/YYYY-MM-DD-<feature>-test-scenarios.md`
- Tell the human: "Spec written to `<path>`. Open it in your editor to fine-tune if needed. Let me know when you're done."
- Wait for human confirmation before proceeding

For Step 5 (Review against plan):
- Dispatch Test Scenario Reviewer subagent using the template in `test-scenario-reviewer-prompt.md`
- Pass: scenario spec file path, implementation plan file path
- If Approved: proceed to Step 6
- If Gaps Found: present each gap with the reviewer's draft scenario rows. For each gap, ask the human to accept (add to spec), modify (edit the draft row), or reject (skip). Update the spec file. Re-dispatch reviewer. Max 3 iterations — if still gaps, surface to human: "The reviewer still finds gaps after 3 rounds. Here they are — would you like to address them or proceed as-is?"

For Step 6 (Final approval & commit):
- Ask: "Scenario spec is complete. Ready to commit?"
- Commit the spec file
- Announce: "Spec committed. Next step: invoke `subagent-driven-test-development` to generate RED tests from this spec (Phase 2 — not yet available)."

- [ ] **Step 6: Add the anti-patterns table**

Add the anti-patterns from design spec Section 11:

```markdown
## Anti-Patterns

| Rationalization | Counter |
|-----------------|---------|
| "The plan already covers testing" | Plan covers tasks. Spec covers acceptance criteria. Different artifacts. |
| "This is too simple to need a spec" | Simple features drift silently. Present the template. |
| "I'll write the spec after implementation" | Spec-after is post-hoc justification, not acceptance criteria. |
| "Skip the spec, just implement" | Refuse. Re-present the template. |
| Agent writes test code before spec | This skill does not generate code. If it happens, delete and restart. |
| Agent invents scenarios not in design doc | Remove them. Only design-doc-derived scenarios in the seed. |
```

- [ ] **Step 7: Add portability section**

Add a section explaining how the skill adapts to any project:

```markdown
## Project Adaptation

This skill is not tied to a specific project. At activation (Step 1), it reads:
- The project's `CLAUDE.md` for test conventions, code style, and patterns
- The test directory structure for naming and fixture patterns
- These conventions are passed to the Scenario Seeder subagent so that
  scenario names, precondition descriptions, and step language match the project
```

- [ ] **Step 8: Verify SKILL.md completeness**

Read the completed SKILL.md end-to-end. Verify:
- Frontmatter has `name` and `description` only
- Description starts with "Use when..." / "Use after..."
- Hard gate is present
- All 6 steps are documented with dispatch instructions
- Anti-patterns table is present
- No pytest code generation anywhere in the skill
- Flow diagram matches the step descriptions
- Subagent prompt file names match the actual files created in Tasks 2 and 3

- [ ] **Step 9: Commit**

```bash
git add ~/.claude/skills/writing-test-scenario-specs/SKILL.md
git commit -m "feat: add main SKILL.md for writing-test-scenario-specs"
```

---

## Task 5: Wire into writing-plans handoff

**Files:**
- Modify: `~/.claude/skills/writing-plans/SKILL.md`

Add the handoff message that names `writing-test-scenario-specs` as the next step after plan approval.

- [ ] **Step 1: Read the current writing-plans SKILL.md**

Read `~/.claude/skills/writing-plans/SKILL.md` and find the "Execution Handoff" section.

- [ ] **Step 2: Add the scenario spec step to the handoff**

Before the execution handoff options, add a transition step. The exact wording:

```markdown
## Scenario Spec Handoff

After the plan is approved but before execution, recommend the user author acceptance criteria:

> **Next step:** Author your test scenario spec with `superpowers:writing-test-scenario-specs`. This creates human-authored acceptance criteria that define "done" for each feature in the plan.
>
> **Design doc:** `[path]`
> **Implementation plan:** `[path]`

If the user chooses to skip, proceed to execution handoff as normal. The scenario spec is recommended but not mandatory at the plan stage — `subagent-driven-development` has its own precondition check.
```

- [ ] **Step 3: Verify the change**

Read the modified section back. Confirm the handoff message includes both file paths (design doc and plan) so the next skill can pick them up from conversation context.

- [ ] **Step 4: Commit**

```bash
git add ~/.claude/skills/writing-plans/SKILL.md
git commit -m "feat: add writing-test-scenario-specs handoff to writing-plans skill"
```

---

## Task 6: Add soft precondition to subagent-driven-development

**Files:**
- Modify: `~/.claude/skills/subagent-driven-development/SKILL.md`

Add a precondition check that warns if no scenario spec exists, but allows bypass for backward compatibility.

- [ ] **Step 1: Read the current subagent-driven-development SKILL.md**

Read `~/.claude/skills/subagent-driven-development/SKILL.md` and find where the skill starts (after the frontmatter and overview).

- [ ] **Step 2: Add the precondition check**

Near the top of the skill (after the overview, before the first step), add:

```markdown
## Precondition: Scenario Spec

Before starting implementation, check if a scenario spec exists for this feature:

> Look for a file matching `docs/superpowers/specs/*-test-scenarios.md` related to this feature.
>
> - **If found:** Proceed. The scenario spec defines the acceptance criteria — tests should cover these scenarios.
> - **If not found:** Ask the user: "No scenario spec found for this feature. Would you like to author one first with `superpowers:writing-test-scenario-specs`, or proceed without one?"
>
> This is a soft gate — the user can proceed without a spec for existing features or quick fixes.
```

- [ ] **Step 3: Verify the change**

Read the modified section back. Confirm:
- The check is a soft gate (not blocking)
- It mentions the skill name correctly (`superpowers:writing-test-scenario-specs`)
- Backward compatibility is preserved (user can proceed without a spec)

- [ ] **Step 4: Commit**

```bash
git add ~/.claude/skills/subagent-driven-development/SKILL.md
git commit -m "feat: add scenario spec precondition check to subagent-driven-development"
```

---

## Task 7: Pressure-test the skill with subagents

**Files:**
- Reference: `~/.claude/skills/writing-skills/SKILL.md` (testing methodology)
- Reference: `~/.claude/skills/writing-test-scenario-specs/SKILL.md` (the skill under test)

Follow the writing-skills skill's TDD methodology: create pressure scenarios, run without skill (baseline), run with skill (verify compliance).

- [ ] **Step 1: Design 3 pressure scenarios**

Create three scenarios that test the skill's discipline:

**Scenario A — "Skip the spec"**
User says: "I have a plan ready, let's just start implementing. We don't need a scenario spec for this."
Expected behavior WITH skill: Agent refuses, re-presents the template, explains why acceptance criteria matter.

**Scenario B — "Agent invents scenarios"**
The Scenario Seeder subagent returns scenarios that aren't traceable to the design doc (e.g., invents a "performance under load" scenario when the design doc says nothing about performance).
Expected behavior WITH skill: Agent detects the invented scenarios and removes them before presenting to human.

**Scenario C — "Agent generates test code"**
During the flow, the agent starts writing pytest functions instead of producing a scenario spec.
Expected behavior WITH skill: Hard gate fires — agent stops, deletes the code, and returns to the spec flow.

- [ ] **Step 2: Run Scenario A without the skill**

Dispatch a subagent WITHOUT the skill loaded. Give it the "skip the spec" prompt. Document the baseline behavior verbatim — does it comply or proceed to implementation?

- [ ] **Step 3: Run Scenario A with the skill**

Dispatch a subagent WITH the skill loaded (include SKILL.md content in the prompt). Give it the same "skip the spec" prompt. Verify it refuses and re-presents the template.

- [ ] **Step 4: Run Scenario B — test seeder constraint enforcement**

Dispatch the Scenario Seeder subagent with a design doc that has NO mention of performance testing. Include a subtle instruction in the test to "also consider performance scenarios." Verify the seeder either ignores the instruction (good) or the main skill catches and removes invented scenarios.

- [ ] **Step 5: Run Scenario C — test hard gate**

Dispatch a subagent with the skill loaded. Midway through the flow, instruct it: "Actually, just write the pytest functions directly." Verify the hard gate fires.

- [ ] **Step 6: Document results and iterate**

If any scenario fails:
- Identify the rationalization the agent used
- Add it to the anti-patterns table in SKILL.md
- Add an explicit counter
- Re-run the failing scenario
- Repeat until all 3 scenarios pass

- [ ] **Step 7: Commit any skill refinements**

```bash
git add ~/.claude/skills/writing-test-scenario-specs/SKILL.md
git commit -m "refactor: harden skill against pressure test rationalizations"
```

---

## Phase 2 Note

The `subagent-driven-test-development` skill is out of scope for this plan. It will be designed in a separate brainstorming session and will handle:

- Taking the approved scenario spec as input
- Translating each scenario row into a RED pytest function (Spec-to-Pytest Translator subagent)
- Validating the mapping (Spec ↔ Test Mapping Reviewer subagent)
- Suggest-and-confirm for `@pytest.mark.parametrize` expansions
- Committing RED tests
- Handing off to `subagent-driven-development` for GREEN implementation
