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

def subagent_key(self, event) -> str | None:
    """Identity of the subagent surface this event belongs to: dispatch run_id when
    a task ancestor is known, else the distinct lc_agent_name (legacy fallback), else
    None (main agent). Full definition in §2."""

def step_label(self, key) -> str:
    """dispatch_label(key) when key is a known dispatch run_id (key in self.dispatches),
    else the bare key (legacy agent name)."""
```

`observe()` calls `observe_task_start()` internally.

Correctness rules baked in:

- **Full run_id equality only** — never prefix/substring match (UUIDv7 time-prefix
  collision).
- **Nearest-ancestor, not first** — scanning `parent_ids` from the deep end makes a nested
  subagent (one that itself dispatches a task) attribute to the innermost dispatch.
- **Fail-open** — no task ancestor ⇒ `None` ⇒ treated as main agent.

### 2. `ChainlitStepRenderer` consumes dispatch identity

Re-key subagent surfaces by a **subagent key** that is the dispatch `run_id` when a task
ancestor is known, and falls back to `lc_agent_name` otherwise
(`dynagent/ui/ui_utils.py`). The fallback preserves today's behavior for event streams
that carry no `parent_ids` (older LangGraph, or classic single-graph domains) — dispatch
keying is a strict improvement layered on top, not a replacement.

The subagent-key rule (a small method on `StreamAttribution`, see §1):

```python
def subagent_key(self, event) -> str | None:
    d = self.dispatch_of(event)
    if d is not None:
        return d                         # dispatch run_id — separates same-type fan-out
    agent = self.owner(event)
    if agent is not None and agent != self.main_agent:
        return agent                     # legacy fallback: distinct lc_agent_name
    return None                          # main agent / fail-open
```

State changes:

```python
self._subagent_steps: dict[str, cl.Step] = {}   # renamed from _agent_steps; keyed by subagent_key
self._task_dispatch: dict[str, str] = {}        # renamed from _task_agent; task run_id -> subagent_type
```

- **`_on_token`:** `key = self._attr.subagent_key(event)`. `None` → stream into `self.msg`
  (main bubble). Else `_get_or_create_subagent_step(key)` and stream into it.
  `_get_or_create_subagent_step` lazily creates one
  `cl.Step(name=f"🧵 {self._attr.step_label(key)}", type="run", default_open=True,
  auto_collapse=True)`, cached by key. `step_label(key)` returns
  `dispatch_label(key)` when `key` is a known dispatch run_id, else the bare `key`
  (legacy agent name).
- **`_on_tool_start`:** a subagent's own tool call parents under
  `_subagent_steps[subagent_key(event)]`. Main-agent tools keep the existing
  `deque(maxlen=3)` eviction untouched.
- **`_on_tool_end`:** when a `task` tool ends (`run_id in self._attr.dispatches`), collapse
  the subagent step for it. Deepagent path: the subagent step is keyed by the task
  `run_id` itself (that's what `dispatch_of` returned for its child events), so collapse
  `_subagent_steps.get(run_id)`. Legacy path: bridge through
  `_subagent_steps.get(self._task_dispatch.get(run_id))`. Collapse whichever resolves.
- **`finish`:** collapses any still-open subagent steps, iterating
  `_subagent_steps.values()`.

No change to the main-agent bubble, structured-output handling, or tool eviction.

### 3. `ActivityProjection` (AMA web activity-rail)

Fix labels and nested-tool rollup (`dynagent/ui/activity_projection.py`). Distinct
dispatches already yield distinct rail rows here (each `task` tool is keyed by its own
`tcid`); the bug is only the label and the nested-tool cross-contamination.

**The two-namespace problem.** The projection's rail rows are built from **AG-UI** events
(`TOOL_CALL_START/ARGS/END/RESULT`) keyed by Anthropic `toolu_…` tool-call ids, whereas
dispatch attribution lives on the **RAW** astream_events keyed by LangGraph `run_id`s. A
task row (`toolu_…`) and its dispatch (`run_id`) are in different namespaces. Both `task`
dispatches even share the same AG-UI `parent_message_id` (the coordinator model), so
`parent_message_id` cannot separate them. Three joins, all verified present in the RAW
events the projection already receives (wrapped as `type == "RAW"`), bridge the gap:

1. **dispatch info** — RAW `on_tool_start(name="task")`: `run_id` is the dispatch id; its
   `data.input` carries `subagent_type` **and** `description`.
2. **model-run → dispatch** — RAW `on_chat_model*` for a subagent: `run_id` is the
   subagent's model-run; its `parent_ids` contains the dispatch `run_id`. This is exactly
   `StreamAttribution.dispatch_of`.
3. **toolu → dispatch** — RAW `on_tool_end(name="task")`: event `run_id` is the dispatch
   id; `data.output` is a ToolMessage whose `tool_call_id` is the AG-UI `toolu_…`. This
   bridges the rail row to its dispatch.

Implementation:

- `ActivityProjection` composes a `StreamAttribution`, feeding it every RAW event, so there
  is one implementation of dispatch attribution shared with the Chainlit renderer.
- New projection maps: `self._model_dispatch: dict[str, str]` (subagent model-run →
  dispatch run_id, from join 2 via `dispatch_of`) and `self._toolu_dispatch: dict[str,
  str]` (AG-UI `toolu_` → dispatch run_id, from join 3).
- **`snapshot()` task branch:** title becomes
  `self._attr.dispatch_label(self._toolu_dispatch[tcid])` (falls back to the AG-UI-parsed
  `subagent_type`, then `"sub-agent"`, if the toolu bridge is absent); `_nested_mono` now
  filters nested tools to those whose `parent_run_id` (their subagent model-run) maps via
  `_model_dispatch` to *this row's* dispatch run_id, instead of matching any tool whose
  parent shares the agent-type name.
- The AG-UI `subagent_type`/`description` parse at `TOOL_CALL_END` (`activity_projection.py:88-93`)
  is retained as the label fallback when RAW joins are unavailable.

### 4. Edge cases & error handling

Fail safe (never crash a live stream) and fail open (unknown attribution → main agent,
never a dropped token).

| Case | Behavior |
|---|---|
| `parent_ids` missing/empty on a genuine subagent event (older LangGraph) | `dispatch_of` → `None`, then `subagent_key` legacy fallback returns the distinct `lc_agent_name` → subagent still gets its own step (today's behavior). Same-type collision persists only in this degraded path; different-type still separates. |
| Main-agent event | `dispatch_of` → `None` and `owner == main_agent` → `subagent_key` returns `None` → main bubble. No regression. |
| `task` input un-parseable (partial/streamed args JSON) | `observe_task_start` try/except → `DispatchInfo(None, None)`; label falls back to `"sub-agent"`. Never raises. |
| Token arrives before its `task` on_tool_start observed | Does not occur: `astream_events` v2 emits a node's `on_tool_start` before any child (subagent) event, so the dispatch is always registered first. If it ever did, `subagent_key` fails open to the legacy `lc_agent_name` path (or main) — graceful, no crash, no provisional-step machinery (YAGNI). |
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

**Regression / backward-compat:** the existing renderer tests build subagents purely via a
distinct `lc_agent_name` with no task dispatch and no `parent_ids`. These exercise the
legacy `subagent_key` fallback and must keep passing with only the mechanical rename
(`_agent_steps` → `_subagent_steps`, `_task_agent` → `_task_dispatch`) — no behavioral
change. New same-type tests add explicit `task` `on_tool_start` events and `parent_ids` on
the subagent streams to exercise the dispatch path. The existing `ActivityProjection`
golden test titles change from bare type (`"weather_expert"`) to
type-plus-description; `stats`, `mono`, ordering, and dots stay identical.

Coverage runs via `make test`; new fixtures live beside the current one.

## Files touched

- `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/dynagent/ui/stream_attribution.py` — new dispatch primitive.
- `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/dynagent/ui/ui_utils.py` — `ChainlitStepRenderer` re-key by dispatch.
- `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/dynagent/ui/activity_projection.py` — labels + nested-tool rollup + shared attribution.
- `autobots-devtools-shared-lib/tests/unit/test_stream_attribution.py` and renderer/projection tests — new coverage + same-type fixture.
