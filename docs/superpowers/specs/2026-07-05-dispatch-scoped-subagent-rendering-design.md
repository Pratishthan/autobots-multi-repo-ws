# Dispatch-Scoped Subagent Rendering

**Date:** 2026-07-05
**Status:** Approved design
**Area:** `autobots-devtools-shared-lib` — `dynagent/ui`

## Problem

When the deep-agent coordinator dispatches **N parallel subagents of the same type**
(e.g. three `general-purpose` agents each researching one language), both UI surfaces
that render subagent activity collapse them into a single surface, because they key that
surface by the subagent's `lc_agent_name` (its *type*), which is identical across the N
dispatches.

Observed symptoms (from the AMA "research 3 languages" run):

- **Chainlit steps** (`ChainlitStepRenderer`): all three dispatches share one
  `cl.Step`, so their token streams interleave into one buffer, producing garbled text
  ("Memory safety without a garbage collector — Rust's ownership and bPros\*\*"), and all
  three carry the identical `general-purpose` label.
- **AMA web activity-rail** (`ActivityProjection`): nested-tool rollups for the three
  dispatches cross-contaminate because nested tools are matched by agent-type name.

### Root cause

Both renderers use agent-*type* as the identity of a subagent surface:

- `ChainlitStepRenderer._agent_steps: dict[str, cl.Step]` keyed by `lc_agent_name`
  (`ui_utils.py:288`).
- `ActivityProjection._nested_mono` / `snapshot` match nested tools by
  `subagent_type == _run_agent[parent_run_id]` (`activity_projection.py:132,163`).

The type is not unique under same-type fan-out. The only identity that stays unique is the
**`task` dispatch `run_id`**.

### Verified linkage (against recorded events)

Using the real recorded stream in
`autobots-devtools-shared-lib/tests/unit/fixtures/agui_stream.jsonl` (a 3-way parallel
run: `assistant` → `math_expert` + `weather_expert`):

- Each `task` `on_tool_start` has a **distinct full `run_id`**. Two dispatches in the
  fixture share only a UUIDv7 **time-prefix** (`019f2dd0-…dba3` vs `019f2dd0-…279b`) —
  so any attribution logic **must compare full run_ids, never prefixes/substrings**.
- Each subagent's `on_chat_model_*` events carry their owning dispatch's **full run_id in
  `event["parent_ids"]`** (root→parent ordered). This gives a robust 1:1
  token→dispatch attribution.
- Main-agent events have an empty task-ancestor set → attribute to main (fail-open).

This linkage holds identically for same-type and different-type fan-out, since dispatch
run_ids differ regardless of type.

## Goals

- Same-type parallel dispatches render as **separate, independently-labeled surfaces** on
  both the Chainlit step UI and the AMA web activity-rail.
- Live token streaming is preserved (no buffering-until-complete).
- One shared attribution primitive powers both surfaces.
- No regression for single-dispatch, no-subagent, or main-agent-only runs.

## Non-goals

- Grouping dispatches under a parent node (rejected: "one step per dispatch" chosen).
- Changing the main-agent bubble, structured-output handling, or the main-tool
  `deque(maxlen=3)` eviction.
- Any change to how subagents are dispatched or named upstream in deepagents.

## Chosen approach (A): dispatch-keyed surfaces via `parent_ids`

Make the identity of a subagent surface the **task dispatch `run_id`**, not the
`lc_agent_name`. Centralize "which dispatch owns this event?" in `StreamAttribution`, and
have both renderers re-key their subagent surfaces by dispatch id.

### Rejected alternatives

- **B — key by `metadata.langgraph_checkpoint_ns` (`tools:<tool_call_id>` prefix).**
  Self-contained in metadata, but parses a LangGraph-internal string format (brittle
  across versions) and introduces a second id system distinct from the `task` dispatch
  `run_id` used elsewhere. Kept as a fallback only if `parent_ids` proves unreliable in
  production.
- **C — buffer each subagent's output, flush on task completion.** Trivially prevents
  interleave but kills live token streaming — worse UX than today for the common
  single-dispatch case.

## Design

### 1. Core primitive: dispatch attribution in `StreamAttribution`

Extend `StreamAttribution` (`dynagent/ui/stream_attribution.py`) to track dispatches and
answer dispatch-level ownership. Callers keep using the single `observe(event)` entry
point.

```python
@dataclass
class DispatchInfo:
    subagent_type: str | None
    description: str | None

# new state
self.dispatches: dict[str, DispatchInfo] = {}   # task run_id -> DispatchInfo

def observe_task_start(self, event) -> None:
    """On on_tool_start where name == 'task', record run_id -> DispatchInfo
    parsed from event['data']['input']. Wrapped in try/except: on parse failure
    record DispatchInfo(None, None). Never raises."""

def dispatch_of(self, event) -> str | None:
    """Return the NEAREST task run_id present in event['parent_ids'].
    parent_ids is root->parent ordered, so scan from the deep end and return the
    last id that is in self.dispatches. None => main agent / no dispatch."""

def dispatch_label(self, run_id) -> str:
    """'{subagent_type} · {description-trimmed}', falling back to subagent_type,
    then 'sub-agent'. Description: newlines collapsed to spaces, trimmed to ~60
    chars on a word boundary."""
```

`observe()` calls `observe_task_start()` internally.

Correctness rules baked in:

- **Full run_id equality only** — never prefix/substring match (UUIDv7 time-prefix
  collision).
- **Nearest-ancestor, not first** — scanning `parent_ids` from the deep end makes a nested
  subagent (one that itself dispatches a task) attribute to the innermost dispatch.
- **Fail-open** — no task ancestor ⇒ `None` ⇒ treated as main agent.

### 2. `ChainlitStepRenderer` consumes dispatch identity

Re-key subagent surfaces by dispatch `run_id` (`dynagent/ui/ui_utils.py`).

State changes:

```python
self._dispatch_steps: dict[str, cl.Step] = {}   # replaces _agent_steps (name -> step)
# _task_agent dict removed — its job (task run_id -> step to collapse) is now direct:
# the task run_id IS the dispatch key.
```

- **`_on_token`:** `dispatch_id = self._attr.dispatch_of(event)`. `None` → stream into
  `self.msg` (main bubble). Else `_get_or_create_dispatch_step(dispatch_id)` and stream
  into it. `_get_or_create_dispatch_step` lazily creates one
  `cl.Step(name=f"🧵 {self._attr.dispatch_label(dispatch_id)}", type="run",
  default_open=True, auto_collapse=True)` per dispatch, cached by run_id.
- **`_on_tool_start`:** a subagent's own tool call parents under
  `_dispatch_steps[dispatch_of(event)]`. Main-agent tools keep the existing
  `deque(maxlen=3)` eviction untouched.
- **`_on_tool_end`:** when a `task` tool ends, its `run_id` *is* the dispatch key →
  collapse `_dispatch_steps.get(run_id)` directly. Deletes the `_task_agent` indirection.
- **`finish`:** collapses any still-open dispatch steps, iterating
  `_dispatch_steps.values()`.

No change to the main-agent bubble, structured-output handling, or tool eviction.

### 3. `ActivityProjection` (AMA web activity-rail)

Fix labels and nested-tool rollup (`dynagent/ui/activity_projection.py`). Distinct
dispatches already yield distinct rail rows here (each `task` tool is keyed by its own
`tcid`); the bug is only the label and the nested-tool cross-contamination.

- Add `self._dispatch: dict[str, DispatchInfo]` populated at `TOOL_CALL_END` for `task`
  tools — extend the existing `subagent_type` parse (`activity_projection.py:88-93`) to
  also capture `description`, keyed by the task's own `tool_call_id`.
- **`snapshot()` task branch:** title becomes `dispatch_label(tcid)`;
  `_nested_mono(subagent_type)` becomes `_nested_mono(dispatch_id)` — select nested tools
  whose parentage resolves (via dispatch attribution) to *this dispatch's* run_id, not any
  tool sharing the agent-type name.
- **Shared attribution:** `ActivityProjection` composes a `StreamAttribution` instance and
  feeds its RAW events through it, so there is exactly one implementation of "which
  dispatch owns this." No duplication of the `parent_ids`-nearest-task logic.

### 4. Edge cases & error handling

Fail safe (never crash a live stream) and fail open (unknown attribution → main agent,
never a dropped token).

| Case | Behavior |
|---|---|
| `parent_ids` missing/empty (older LangGraph, main-agent events) | `dispatch_of` → `None` → main bubble. Today's behavior; no regression. |
| `task` input un-parseable (partial/streamed args JSON) | `observe_task_start` try/except → `DispatchInfo(None, None)`; label falls back to `"sub-agent"`. Never raises. |
| Token arrives before its `task` on_tool_start observed | `dispatch_of` finds the run_id in `parent_ids` but not yet in `self.dispatches` → buffer under a provisional step keyed by that run_id; label backfilled when the task start is later observed. No lost tokens. |
| Nested subagent dispatches its own task | `parent_ids` holds both ancestors root→deep; nearest-match returns the inner dispatch → nested step parents correctly. |
| UUIDv7 time-prefix collision | Guarded by full-string equality only. Explicit test. |
| Same-type, same-description dispatches (identical labels) | Steps keyed by distinct run_ids, so surfaces stay separate even with identical labels. Correctness doesn't depend on label uniqueness. |
| Dispatch never emits a token (fails instantly) | No step created; `finish()` collapse loop skips it. Task-end handling is a no-op if no step. |
| `description` extremely long / newlines | Trimmed to ~60 chars on a word boundary, newlines collapsed; label only. Full text untouched elsewhere. |

No new exceptions propagate to `stream_agent_events`; the existing `try/finally` (with
`flush_tracing`) is unchanged.

### 5. Testing

The recorded fixture already contains a real 3-way parallel dispatch, so tests run against
real event shapes. A **same-type** fan-out fixture is added since that is the exact clash
being fixed.

**Unit — `StreamAttribution`** (extends `test_stream_attribution.py`):

- `dispatch_of` returns the correct full task run_id from `parent_ids`; `None` for
  main-agent events.
- UUIDv7 guard: two dispatches sharing a time-prefix attribute to different steps
  (regression test).
- Nearest-ancestor: nested dispatch resolves to the inner task run_id.
- Un-parseable / missing `task` input → label falls back to `"sub-agent"`, no raise.
- `dispatch_label` trimming: long/newline description → single line, ≤~60 chars.

**Unit — `ChainlitStepRenderer`** (Chainlit `Step`/`Message` faked/monkeypatched, as
existing renderer tests do):

- Headline test: two same-type dispatches produce two distinct steps with distinct labels,
  and each dispatch's tokens land only in its own step (assert no interleave).
- Nested subagent tool step parents under the right dispatch step.
- `task` end collapses exactly that dispatch's step; `finish()` collapses any still-open.
- Main-agent tokens still stream to `self.msg`; `deque(maxlen=3)` eviction unchanged.

**Unit — `ActivityProjection`** (`project_events` over fixtures):

- Same-type fan-out → N distinct rail rows with distinct labels.
- `_nested_mono` rolls up each dispatch's own nested tools only.
- `stats` (tokens/tools/latency) unchanged vs. current snapshot on the existing fixture.

**Regression:** existing single-dispatch and no-subagent fixtures yield byte-identical
output to today (golden snapshot).

Coverage runs via `make test`; new fixtures live beside the current one.

## Files touched

- `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/dynagent/ui/stream_attribution.py` — new dispatch primitive.
- `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/dynagent/ui/ui_utils.py` — `ChainlitStepRenderer` re-key by dispatch.
- `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/dynagent/ui/activity_projection.py` — labels + nested-tool rollup + shared attribution.
- `autobots-devtools-shared-lib/tests/unit/test_stream_attribution.py` and renderer/projection tests — new coverage + same-type fixture.
