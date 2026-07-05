# Dispatch-Scoped Subagent Rendering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render N parallel subagents of the *same type* as separate, independently-labeled UI surfaces (Chainlit steps and the AMA web activity-rail) instead of collapsing them into one clashing surface.

**Architecture:** Introduce a "dispatch identity" — the `task` tool's LangGraph `run_id` — as the key for subagent surfaces, replacing the colliding `lc_agent_name`. A single primitive in `StreamAttribution` answers "which dispatch owns this event?" from the event's `parent_ids`. Both renderers consume it, with a legacy `lc_agent_name` fallback preserving today's behavior when `parent_ids` are absent.

**Tech Stack:** Python 3.12, pytest (`asyncio_mode = "auto"`), Chainlit, LangGraph `astream_events` v2, deepagents.

## Global Constraints

- Package under change: `autobots-devtools-shared-lib`, module `autobots_devtools_shared_lib.dynagent.ui`.
- Run all commands from `autobots-devtools-shared-lib/`. Shared venv at `../.venv`.
- Ruff line-length 100, double quotes; Pyright basic mode. Ignore `S101` in tests.
- **Full run_id equality only** — never prefix/substring-match run_ids (UUIDv7s share a time-prefix).
- **Fail-open** — unknown attribution routes to the main agent; never drop a token, never raise into the stream.
- No new required dependencies. No change to how subagents are dispatched/named upstream.
- Spec: `docs/superpowers/specs/2026-07-05-dispatch-scoped-subagent-rendering-design.md`.
- Test single: `make test-one TEST=tests/unit/test_x.py::test_y` (or `../.venv/bin/pytest ... -v`).

---

## File Structure

- **Modify** `src/autobots_devtools_shared_lib/dynagent/ui/stream_attribution.py` — add `DispatchInfo`, dispatch tracking, `dispatch_of`, `dispatch_label`, `subagent_key`, `step_label`. (Task 1)
- **Modify** `src/autobots_devtools_shared_lib/dynagent/ui/ui_utils.py` — `ChainlitStepRenderer` re-keys subagent surfaces by `subagent_key`. (Task 2)
- **Modify** `src/autobots_devtools_shared_lib/dynagent/ui/activity_projection.py` — embed `StreamAttribution`, add toolu→dispatch + model-run→dispatch joins, fix labels + nested rollup. (Task 3)
- **Modify** `tests/unit/test_stream_attribution.py` — dispatch-attribution coverage. (Task 1)
- **Modify** `tests/unit/test_chainlit_step_renderer.py` — rename refs; add same-type dispatch tests. (Task 2)
- **Modify** `tests/unit/test_activity_projection.py` — update golden titles; add same-type + cross-contamination tests. (Task 3)

The existing recorded fixture `tests/unit/fixtures/agui_stream.jsonl` (a real 3-way parallel run: `assistant` → `math_expert` + `weather_expert`) is reused. No new fixture file is required — Tasks 2 and 3 synthesize same-type events inline, matching the established test-helper style.

---

### Task 1: Dispatch primitive in `StreamAttribution`

**Files:**
- Modify: `src/autobots_devtools_shared_lib/dynagent/ui/stream_attribution.py`
- Test: `tests/unit/test_stream_attribution.py`

**Interfaces:**
- Consumes: raw `astream_events` dicts (existing `observe(event)` entry point). Relevant fields: `event["event"]`, `event["name"]`, `event["run_id"]`, `event.get("parent_ids")` (list, root→parent order), `event["data"]["input"]` (for `task` tools: `{"subagent_type", "description"}`), `event["metadata"]["lc_agent_name"]`.
- Produces (consumed by Tasks 2 & 3):
  - `DispatchInfo` dataclass: `subagent_type: str | None`, `description: str | None`.
  - `self.dispatches: dict[str, DispatchInfo]` — task run_id → info.
  - `dispatch_of(event) -> str | None` — nearest registered task run_id in `parent_ids`.
  - `dispatch_label(run_id: str) -> str`.
  - `subagent_key(event) -> str | None`.
  - `step_label(key: str) -> str`.

- [ ] **Step 1: Write failing tests for the dispatch primitive**

Add to `tests/unit/test_stream_attribution.py` (the file already has `_load_raw_events`, `_tool_start`, and the `observed` fixture — reuse them). Append:

```python
from autobots_devtools_shared_lib.dynagent.ui.stream_attribution import DispatchInfo


def _chat_stream(agent, run_id, parent_ids):
    return {
        "event": "on_chat_model_stream",
        "run_id": run_id,
        "parent_ids": parent_ids,
        "metadata": {"lc_agent_name": agent},
    }


def test_task_dispatch_is_recorded_with_type_and_description(observed):
    # The frozen fixture dispatches math_expert and weather_expert.
    types = {d.subagent_type for d in observed.dispatches.values()}
    assert types == {"math_expert", "weather_expert"}
    descriptions = [d.description for d in observed.dispatches.values()]
    assert any(desc and "17 times 3" in desc for desc in descriptions)


def test_dispatch_of_maps_subagent_event_to_its_task_run_id(observed):
    # Two dispatches share a UUIDv7 time-prefix; attribution must use full ids.
    by_type = {d.subagent_type: rid for rid, d in observed.dispatches.items()}
    math_run_id = by_type["math_expert"]
    weather_run_id = by_type["weather_expert"]
    assert math_run_id != weather_run_id
    assert math_run_id[:13] == weather_run_id[:13]  # prefix collision is real

    ev_math = _chat_stream("math_expert", "model-a", parent_ids=["root", math_run_id])
    ev_weather = _chat_stream("weather_expert", "model-b", parent_ids=["root", weather_run_id])
    assert observed.dispatch_of(ev_math) == math_run_id
    assert observed.dispatch_of(ev_weather) == weather_run_id


def test_dispatch_of_returns_none_without_task_ancestor(observed):
    ev = _chat_stream("assistant", "m", parent_ids=[])
    assert observed.dispatch_of(ev) is None


def test_dispatch_of_returns_nearest_ancestor():
    attr = StreamAttribution()
    outer = _tool_start_task("outer", "outer_agent", "outer task")
    inner = _tool_start_task("inner", "inner_agent", "inner task")
    attr.observe(outer)
    attr.observe(inner)
    # parent_ids ordered root->parent: outer is shallower, inner is deeper.
    ev = {
        "event": "on_chat_model_stream",
        "run_id": "deep-model",
        "parent_ids": ["root", "outer", "mid", "inner"],
        "metadata": {"lc_agent_name": "inner_agent"},
    }
    assert attr.dispatch_of(ev) == "inner"


def test_dispatch_label_combines_type_and_trimmed_description():
    attr = StreamAttribution()
    attr.observe(_tool_start_task("r1", "general-purpose", "Research Rust pros and cons"))
    assert attr.dispatch_label("r1") == "general-purpose · Research Rust pros and cons"


def test_dispatch_label_trims_long_description_and_collapses_newlines():
    attr = StreamAttribution()
    long_desc = "First line about the task\nsecond line " + "x" * 100
    attr.observe(_tool_start_task("r1", "gp", long_desc))
    label = attr.dispatch_label("r1")
    assert "\n" not in label
    assert len(label) <= 80  # "gp · " + ~60 chars + ellipsis budget


def test_dispatch_label_falls_back_when_input_unparseable():
    attr = StreamAttribution()
    bad = {
        "event": "on_tool_start",
        "name": "task",
        "run_id": "r1",
        "data": {"input": "not-a-dict"},
    }
    attr.observe(bad)  # must not raise
    assert attr.dispatches["r1"] == DispatchInfo(None, None)
    assert attr.dispatch_label("r1") == "sub-agent"


def test_subagent_key_prefers_dispatch_then_falls_back_to_agent_name():
    attr = StreamAttribution()
    attr.observe(
        {"event": "on_chat_model_start", "run_id": "m", "metadata": {"lc_agent_name": "assistant"}}
    )
    attr.observe(_tool_start_task("disp1", "general-purpose", "Research Rust"))

    dispatch_event = _chat_stream("general-purpose", "model-x", parent_ids=["disp1"])
    assert attr.subagent_key(dispatch_event) == "disp1"

    legacy_event = _chat_stream("weather_expert", "model-y", parent_ids=[])
    assert attr.subagent_key(legacy_event) == "weather_expert"

    main_event = _chat_stream("assistant", "model-z", parent_ids=[])
    assert attr.subagent_key(main_event) is None


def test_step_label_uses_dispatch_label_for_known_dispatch_else_bare_key():
    attr = StreamAttribution()
    attr.observe(_tool_start_task("disp1", "general-purpose", "Research Rust"))
    assert attr.step_label("disp1") == "general-purpose · Research Rust"
    assert attr.step_label("weather_expert") == "weather_expert"


def _tool_start_task(run_id, subagent_type, description):
    return {
        "event": "on_tool_start",
        "name": "task",
        "run_id": run_id,
        "data": {"input": {"subagent_type": subagent_type, "description": description}},
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `../.venv/bin/pytest tests/unit/test_stream_attribution.py -v`
Expected: FAIL — `ImportError: cannot import name 'DispatchInfo'` (and `AttributeError` for `dispatches`, `dispatch_of`, etc.).

- [ ] **Step 3: Implement the dispatch primitive**

Edit `src/autobots_devtools_shared_lib/dynagent/ui/stream_attribution.py`. Add the import, the dataclass, and the new state/methods. Full replacement of the file body below (keep the ABOUTME header lines):

```python
# ABOUTME: Pure reducer attributing raw astream_events to their owning lc_agent_name.
# ABOUTME: Mirrors ActivityProjection's _run_agent map + _first_agent heuristic; no Chainlit dep.

from dataclasses import dataclass
from typing import Any

_LABEL_DESC_MAX = 60


@dataclass
class DispatchInfo:
    """What a `task` dispatch launched: its subagent type and task description."""

    subagent_type: str | None
    description: str | None


def _agent_of(event: dict[str, Any]) -> str | None:
    return (event.get("metadata") or {}).get("lc_agent_name")


def _is_chat_model(event: dict[str, Any]) -> bool:
    return str(event.get("event") or "").startswith("on_chat_model")


def _trim_description(description: str | None) -> str | None:
    if not description:
        return None
    collapsed = " ".join(description.split())
    if len(collapsed) <= _LABEL_DESC_MAX:
        return collapsed
    cut = collapsed[:_LABEL_DESC_MAX].rsplit(" ", 1)[0] or collapsed[:_LABEL_DESC_MAX]
    return f"{cut}…"


class StreamAttribution:
    """Answer 'which agent / which dispatch owns this event?' for a single agent run."""

    def __init__(self) -> None:
        self.run_agent: dict[str, str] = {}
        self.main_agent: str | None = None
        self.dispatches: dict[str, DispatchInfo] = {}

    def observe(self, event: dict[str, Any]) -> None:
        """Ingest one raw astream_events dict. Call once per event before querying."""
        agent = _agent_of(event)
        run_id = event.get("run_id")
        if agent and run_id:
            self.run_agent[run_id] = agent
        if agent and self.main_agent is None and _is_chat_model(event):
            self.main_agent = agent
        self._observe_task_start(event)

    def _observe_task_start(self, event: dict[str, Any]) -> None:
        if not self.is_task_dispatch(event):
            return
        run_id = event.get("run_id")
        if not run_id:
            return
        tool_input = event.get("data", {}).get("input")
        if isinstance(tool_input, dict):
            info = DispatchInfo(tool_input.get("subagent_type"), tool_input.get("description"))
        else:
            info = DispatchInfo(None, None)
        self.dispatches[run_id] = info

    def owner(self, event: dict[str, Any]) -> str | None:
        """The lc_agent_name owning this event; falls back to the run_agent map."""
        agent = _agent_of(event)
        if agent:
            return agent
        run_id = event.get("run_id")
        return self.run_agent.get(run_id) if run_id else None

    def is_main(self, agent: str | None) -> bool:
        """True for the main/coordinator agent, or when attribution is unknown (fail-open)."""
        return agent is None or agent == self.main_agent

    def dispatch_of(self, event: dict[str, Any]) -> str | None:
        """Nearest registered task run_id in event['parent_ids'] (root->parent ordered)."""
        for run_id in reversed(event.get("parent_ids") or []):
            if run_id in self.dispatches:
                return run_id
        return None

    def dispatch_label(self, run_id: str) -> str:
        info = self.dispatches.get(run_id)
        subagent_type = info.subagent_type if info else None
        description = _trim_description(info.description) if info else None
        if subagent_type and description:
            return f"{subagent_type} · {description}"
        if subagent_type:
            return subagent_type
        return "sub-agent"

    def subagent_key(self, event: dict[str, Any]) -> str | None:
        """Identity of the subagent surface this event belongs to.

        Dispatch run_id when a task ancestor is known (separates same-type fan-out),
        else the distinct lc_agent_name (legacy fallback for streams without parent_ids),
        else None (main agent / fail-open).
        """
        dispatch = self.dispatch_of(event)
        if dispatch is not None:
            return dispatch
        agent = self.owner(event)
        if agent is not None and agent != self.main_agent:
            return agent
        return None

    def step_label(self, key: str) -> str:
        """dispatch_label(key) for a known dispatch run_id, else the bare key."""
        if key in self.dispatches:
            return self.dispatch_label(key)
        return key

    @staticmethod
    def is_task_dispatch(event: dict[str, Any]) -> bool:
        """True when this on_tool_start is a deepagents `task` subagent dispatch."""
        return event.get("event") == "on_tool_start" and event.get("name") == "task"
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `../.venv/bin/pytest tests/unit/test_stream_attribution.py -v`
Expected: PASS (all existing tests + the new ones). If the `len(label) <= 80` assertion is tight, confirm `_LABEL_DESC_MAX = 60` and the `…` suffix.

- [ ] **Step 5: Lint + type-check the changed file**

Run: `../.venv/bin/ruff check src/autobots_devtools_shared_lib/dynagent/ui/stream_attribution.py tests/unit/test_stream_attribution.py && ../.venv/bin/ruff format src/autobots_devtools_shared_lib/dynagent/ui/stream_attribution.py && make type-check`
Expected: no errors.

- [ ] **Step 6: Commit**

```bash
git add src/autobots_devtools_shared_lib/dynagent/ui/stream_attribution.py tests/unit/test_stream_attribution.py
git commit -m "feat(ui): add dispatch attribution to StreamAttribution

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: `ChainlitStepRenderer` keys subagent surfaces by dispatch

**Files:**
- Modify: `src/autobots_devtools_shared_lib/dynagent/ui/ui_utils.py:270-391` (the `ChainlitStepRenderer` class)
- Test: `tests/unit/test_chainlit_step_renderer.py`

**Interfaces:**
- Consumes (from Task 1): `self._attr.subagent_key(event)`, `self._attr.step_label(key)`, `self._attr.dispatches`, `self._attr.is_task_dispatch(event)`.
- Produces: renderer state `self._subagent_steps: dict[str, cl.Step]` (was `_agent_steps`), `self._task_dispatch: dict[str, str]` (was `_task_agent`). Method `_get_or_create_subagent_step(key: str) -> cl.Step` (was `_get_or_create_agent_step`).

- [ ] **Step 1: Update existing tests for the rename and add same-type dispatch tests**

In `tests/unit/test_chainlit_step_renderer.py`:

(a) Replace every `r._agent_steps` with `r._subagent_steps` (occurrences at the current lines 106, 121, 178, 198). These existing tests use no `parent_ids`, so they exercise the legacy fallback (key == agent name) and their assertions stay valid after the rename.

(b) Add these helpers and tests at the end of the file:

```python
def _stream_with_parents(agent, run_id, text, parent_ids):
    class _C:
        content = text

    return {
        "event": "on_chat_model_stream",
        "run_id": run_id,
        "parent_ids": parent_ids,
        "metadata": {"lc_agent_name": agent},
        "data": {"chunk": _C()},
    }


def _task_dispatch(run_id, subagent_type, description):
    return {
        "event": "on_tool_start",
        "run_id": run_id,
        "name": "task",
        "data": {"input": {"subagent_type": subagent_type, "description": description}},
    }


async def test_same_type_parallel_dispatches_get_separate_steps(patched):
    r = ui_utils.ChainlitStepRenderer(on_structured_output=None)
    await r.start()
    await r.dispatch(_stream("assistant", "m", "hi"))
    await r.dispatch(_task_dispatch("d1", "general-purpose", "Research Rust"))
    await r.dispatch(_task_dispatch("d2", "general-purpose", "Research Kotlin"))
    await r.dispatch(_stream_with_parents("general-purpose", "mA", "rust text", ["d1"]))
    await r.dispatch(_stream_with_parents("general-purpose", "mB", "kotlin text", ["d2"]))

    step1 = r._subagent_steps["d1"]
    step2 = r._subagent_steps["d2"]
    assert step1 is not step2
    assert step1.tokens == ["rust text"]
    assert step2.tokens == ["kotlin text"]
    assert step1.name == "🧵 general-purpose · Research Rust"
    assert step2.name == "🧵 general-purpose · Research Kotlin"


async def test_dispatch_step_collapses_on_its_task_end(patched):
    r = ui_utils.ChainlitStepRenderer(on_structured_output=None)
    await r.start()
    await r.dispatch(_stream("assistant", "m", "hi"))
    await r.dispatch(_task_dispatch("d1", "general-purpose", "Research Rust"))
    await r.dispatch(_stream_with_parents("general-purpose", "mA", "rust", ["d1"]))
    step = r._subagent_steps["d1"]
    await r.dispatch(_tool_end("d1", "done"))
    assert step.default_open is False
    assert step.updated >= 1


async def test_nested_tool_parents_under_dispatch_step(patched):
    r = ui_utils.ChainlitStepRenderer(on_structured_output=None)
    await r.start()
    await r.dispatch(_stream("assistant", "m", "hi"))
    await r.dispatch(_task_dispatch("d1", "general-purpose", "Research Rust"))
    await r.dispatch(_stream_with_parents("general-purpose", "mA", "rust", ["d1"]))
    nested = {
        "event": "on_tool_start",
        "run_id": "nested-1",
        "name": "spike_tools__ls",
        "parent_ids": ["d1", "mA"],
        "metadata": {"lc_agent_name": "general-purpose"},
        "data": {"input": {}},
    }
    await r.dispatch(nested)
    assert r._tool_steps["nested-1"].parent_id == r._subagent_steps["d1"].id
```

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `../.venv/bin/pytest tests/unit/test_chainlit_step_renderer.py -v`
Expected: the three new tests FAIL (`AttributeError: ... has no attribute '_subagent_steps'` / wrong routing); renamed existing tests may also error until Step 3.

- [ ] **Step 3: Re-key the renderer by subagent identity**

Edit `ChainlitStepRenderer` in `src/autobots_devtools_shared_lib/dynagent/ui/ui_utils.py`.

3a. In `__init__` (currently lines 280-291) rename the two dicts:

```python
        self._agent_steps: dict[str, cl.Step] = {}  # lc_agent_name -> subagent step
```
becomes
```python
        self._subagent_steps: dict[str, cl.Step] = {}  # subagent_key -> subagent step
```
and
```python
        self._task_agent: dict[str, str] = {}  # task run_id -> subagent_type
```
becomes
```python
        self._task_dispatch: dict[str, str] = {}  # task run_id -> subagent_type (legacy collapse bridge)
```

3b. Replace `_on_token` (currently lines 315-326) with:

```python
    async def _on_token(self, event: dict[str, Any]) -> None:
        fragments = _extract_token_fragments(event.get("data", {}).get("chunk"))
        if not fragments:
            return
        key = self._attr.subagent_key(event)
        if key is None:
            for frag in fragments:
                await self.msg.stream_token(frag)
            return
        step = await self._get_or_create_subagent_step(key)
        for frag in fragments:
            await step.stream_token(frag)
```

3c. Replace `_get_or_create_agent_step` (currently lines 328-335) with:

```python
    async def _get_or_create_subagent_step(self, key: str) -> cl.Step:
        step = self._subagent_steps.get(key)
        if step is None:
            step = cl.Step(
                name=f"🧵 {self._attr.step_label(key)}",
                type="run",
                default_open=True,
                auto_collapse=True,
            )
            await step.send()
            self._subagent_steps[key] = step
        return step
```

3d. Replace `_on_tool_start` (currently lines 338-372) with:

```python
    async def _on_tool_start(self, event: dict[str, Any]) -> None:
        run_id = event.get("run_id")
        if StreamAttribution.is_task_dispatch(event):
            # Dispatch boundary: no visible step here. Remember the subagent_type so a
            # legacy-keyed step (no parent_ids on child events) can be collapsed on task end.
            tool_input = event.get("data", {}).get("input", {})
            subagent_type = (
                tool_input.get("subagent_type") if isinstance(tool_input, dict) else None
            )
            if run_id and subagent_type:
                self._task_dispatch[run_id] = subagent_type
            return

        tool_name = event.get("name", "unknown")
        tool_input = event.get("data", {}).get("input", {})
        key = self._attr.subagent_key(event)
        parent_id: str | None = None
        if key is not None:
            parent_step = await self._get_or_create_subagent_step(key)
            parent_id = parent_step.id
        else:
            # Main-agent top-level tool step: subject to eviction.
            if len(self._main_tool_queue) >= 3:
                old_run_id = self._main_tool_queue.popleft()
                old_step = self._tool_steps.pop(old_run_id, None)
                if old_step is not None:
                    await old_step.remove()
            if run_id:
                self._main_tool_queue.append(run_id)

        step = cl.Step(name=f"🛠️ {tool_name}", type="tool", parent_id=parent_id)
        step.input = tool_input
        await step.send()
        if run_id:
            self._tool_steps[run_id] = step
```

3e. Replace `_on_tool_end` (currently lines 374-387) with:

```python
    async def _on_tool_end(self, event: dict[str, Any]) -> None:
        run_id = event.get("run_id")
        if run_id is None:
            return
        if run_id in self._attr.dispatches:
            # A subagent dispatch finished: collapse its step. Deepagent path keys the step
            # by the task run_id; legacy path keys it by subagent_type (bridged here).
            step = self._subagent_steps.get(run_id) or self._subagent_steps.get(
                self._task_dispatch.get(run_id, "")
            )
            if step is not None:
                await self._collapse(step)
            return
        step = self._tool_steps.get(run_id)
        if step is not None:
            step.output = str(event.get("data", {}).get("output", ""))[:1000]
            await step.update()
```

3f. In `finish` (currently lines 308-312) rename the iterated dict:

```python
        for step in self._agent_steps.values():
```
becomes
```python
        for step in self._subagent_steps.values():
```

3g. Update the class docstring's mention of `_agent_steps` (line ~288 area, prose only) to `_subagent_steps` and note dispatch keying. (Cosmetic; keep it accurate.)

Note: the `on_tool_end` collapse now checks `run_id in self._attr.dispatches` (a real dispatch) rather than the old `_task_agent` membership. Because `is_task_dispatch` events are observed by `self._attr` in `dispatch()` before `_on_tool_end`, the task run_id is already registered.

- [ ] **Step 4: Run tests to verify all pass**

Run: `../.venv/bin/pytest tests/unit/test_chainlit_step_renderer.py -v`
Expected: PASS — all renamed legacy tests plus the three new dispatch tests. Legacy tests still pass because their subagent events have no `parent_ids`, so `subagent_key` returns the `lc_agent_name`.

- [ ] **Step 5: Run the broader UI test set to catch collateral**

Run: `../.venv/bin/pytest tests/unit/test_ui_utils.py tests/unit/test_ui_utils_tokens.py -v`
Expected: PASS. If any reference `_agent_steps`/`_task_agent`/`_get_or_create_agent_step`, update them to the new names (mechanical rename only).

- [ ] **Step 6: Lint, format, type-check**

Run: `../.venv/bin/ruff check src/autobots_devtools_shared_lib/dynagent/ui/ui_utils.py tests/unit/test_chainlit_step_renderer.py && ../.venv/bin/ruff format src/autobots_devtools_shared_lib/dynagent/ui/ui_utils.py && make type-check`
Expected: no errors.

- [ ] **Step 7: Commit**

```bash
git add src/autobots_devtools_shared_lib/dynagent/ui/ui_utils.py tests/unit/test_chainlit_step_renderer.py tests/unit/test_ui_utils.py tests/unit/test_ui_utils_tokens.py
git commit -m "feat(ui): key Chainlit subagent steps by dispatch, fixing same-type clash

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: `ActivityProjection` dispatch labels + nested-tool rollup

**Files:**
- Modify: `src/autobots_devtools_shared_lib/dynagent/ui/activity_projection.py`
- Test: `tests/unit/test_activity_projection.py`

**Interfaces:**
- Consumes (from Task 1): `StreamAttribution` (`observe`, `dispatch_of`, `dispatch_label`, `dispatches`).
- The projection receives AG-UI events; RAW ones arrive as `{"type": "RAW", "event": <raw astream_events dict>}` (see `_observe_raw`, line 104). It must feed each RAW `event` to an embedded `StreamAttribution`.
- Three joins (all verified in the fixture):
  1. dispatch info — RAW `on_tool_start(name="task")`: `run_id` + `data.input.{subagent_type,description}` → handled by `StreamAttribution.observe`.
  2. model-run → dispatch — RAW `on_chat_model*`: `dispatch_of(event)` keyed by the subagent model `run_id`.
  3. toolu → dispatch — RAW `on_tool_end(name="task")`: event `run_id` is the dispatch id; `data.output` ToolMessage `tool_call_id` is the AG-UI `toolu_…`.

- [ ] **Step 1: Update existing golden tests and add same-type / cross-contamination tests**

In `tests/unit/test_activity_projection.py`:

(a) The rail titles now include the task description. Update the three affected assertions:

- `test_activity_has_three_items_in_start_order` (line 29): the two subagent titles gain their descriptions. Replace with:

```python
def test_activity_has_three_items_in_start_order(projection):
    titles = [item["title"] for item in projection["activity"]]
    assert titles[0].startswith("weather_expert · ")
    assert titles[1].startswith("math_expert · ")
    assert titles[2] == "get_secret_number"
```

- `test_weather_subagent_item_folds_nested_mcp_call` (lines 32-41): assert on the stable fields and a title prefix instead of the exact bare title:

```python
def test_weather_subagent_item_folds_nested_mcp_call(projection):
    weather = projection["activity"][0]
    assert weather["dot"] == "var(--info)"
    assert weather["glow"] is False
    assert weather["title"].startswith("weather_expert · ")
    assert weather["mono"] == "MCP get_weather"
    assert weather["sub"] == "completed · 5837ms · 9220 tok"
    assert weather["isRunning"] is False
```

- `test_math_subagent_item_has_no_nested_call` (lines 44-49): unchanged assertions still hold (`mono == ""`), no title assertion there — leave as is.

- `test_running_item_before_result_glows` (lines 64-86): this test drives only AG-UI events (no RAW `on_tool_start(task)`), so no dispatch is registered and the title must fall back to the AG-UI-parsed `subagent_type`. Keep `assert item["title"] == "math_expert"` — the fallback preserves it.

(b) Add a same-type fan-out test that feeds RAW events (the projection's real dispatch source). Append:

```python
def _raw(event):
    return {"type": "RAW", "event": event}


def _agui_task_row(tcid, t_start, t_end):
    # AG-UI events that build one task rail row keyed by tcid.
    return [
        {
            "type": "TOOL_CALL_START",
            "tool_call_id": tcid,
            "tool_call_name": "task",
            "parent_message_id": "lc_run--COORD",
            "_t_ms": t_start,
        },
        {"type": "TOOL_CALL_END", "tool_call_id": tcid, "_t_ms": t_end},
    ]


def test_same_type_dispatches_get_distinct_labels_and_isolated_nested_tools():
    from autobots_devtools_shared_lib.dynagent.ui.activity_projection import ActivityProjection

    proj = ActivityProjection(mcp_servers={"spike_tools"})
    proj.observe({"type": "RUN_STARTED", "_t_ms": 0})

    # Coordinator model event first, so _first_agent (the main agent) is "assistant" and
    # subagent tools fold into their task rows instead of becoming top-level rows.
    proj.observe(_raw({
        "event": "on_chat_model_stream", "run_id": "COORD",
        "parent_ids": [], "metadata": {"lc_agent_name": "assistant"},
    }))

    # Two same-type dispatches (RAW on_tool_start registers them in StreamAttribution).
    proj.observe(_raw({
        "event": "on_tool_start", "name": "task", "run_id": "disp-A",
        "data": {"input": {"subagent_type": "general-purpose", "description": "Research Rust"}},
    }))
    proj.observe(_raw({
        "event": "on_tool_start", "name": "task", "run_id": "disp-B",
        "data": {"input": {"subagent_type": "general-purpose", "description": "Research Kotlin"}},
    }))
    # Each subagent's model-run points at its dispatch via parent_ids.
    proj.observe(_raw({
        "event": "on_chat_model_stream", "run_id": "model-A",
        "parent_ids": ["disp-A"], "metadata": {"lc_agent_name": "general-purpose"},
    }))
    proj.observe(_raw({
        "event": "on_chat_model_stream", "run_id": "model-B",
        "parent_ids": ["disp-B"], "metadata": {"lc_agent_name": "general-purpose"},
    }))
    # toolu -> dispatch bridge, from RAW on_tool_end(task) output ToolMessage.tool_call_id.
    proj.observe(_raw({
        "event": "on_tool_end", "name": "task", "run_id": "disp-A",
        "data": {"output": {"tool_call_id": "toolu-A"}},
    }))
    proj.observe(_raw({
        "event": "on_tool_end", "name": "task", "run_id": "disp-B",
        "data": {"output": {"tool_call_id": "toolu-B"}},
    }))

    # AG-UI task rows (keyed by toolu) + one nested MCP tool per dispatch.
    for ev in _agui_task_row("toolu-A", 10, 40):
        proj.observe(ev)
    for ev in _agui_task_row("toolu-B", 11, 41):
        proj.observe(ev)
    # Nested tool under dispatch A's model-run.
    proj.observe({
        "type": "TOOL_CALL_START", "tool_call_id": "nested-A",
        "tool_call_name": "spike_tools__grep", "parent_message_id": "lc_run--model-A", "_t_ms": 20,
    })
    proj.observe({"type": "TOOL_CALL_END", "tool_call_id": "nested-A", "_t_ms": 25})

    snap = proj.snapshot()
    rows = {r["title"]: r for r in snap["activity"] if r["title"].startswith("general-purpose")}
    assert set(rows) == {
        "general-purpose · Research Rust",
        "general-purpose · Research Kotlin",
    }
    # Nested grep folds only into dispatch A; dispatch B has no nested tool.
    assert rows["general-purpose · Research Rust"]["mono"] == "MCP grep"
    assert rows["general-purpose · Research Kotlin"]["mono"] == ""
```

- [ ] **Step 2: Run tests to verify the new one fails**

Run: `../.venv/bin/pytest tests/unit/test_activity_projection.py -v`
Expected: `test_same_type_dispatches_...` FAILs (titles are bare `general-purpose`, and grep folds into both rows). The edited golden tests also fail until Step 3.

- [ ] **Step 3: Embed StreamAttribution and add the joins**

Edit `src/autobots_devtools_shared_lib/dynagent/ui/activity_projection.py`.

3a. Add the import near the top (after the existing imports, line ~7):

```python
from autobots_devtools_shared_lib.dynagent.ui.stream_attribution import StreamAttribution
```

3b. In `__init__` (lines 49-60), add three fields after `self._run_agent`:

```python
        self._attr = StreamAttribution()
        self._model_dispatch: dict[str, str] = {}  # subagent model run_id -> dispatch run_id
        self._toolu_dispatch: dict[str, str] = {}  # AG-UI toolu id -> dispatch run_id
```

3c. Replace `_observe_raw` (lines 104-118) so it feeds the embedded attribution and records the two derived maps:

```python
    def _observe_raw(self, raw: dict[str, Any]) -> None:
        self._attr.observe(raw)
        name = str(raw.get("event") or "")

        if name == "on_tool_end" and raw.get("name") == "task":
            self._record_toolu_dispatch(raw)
            return

        if not name.startswith("on_chat_model"):
            return
        run_id = raw.get("run_id")
        agent = (raw.get("metadata") or {}).get("lc_agent_name")
        if run_id and agent:
            self._run_agent[run_id] = agent
            if self._first_agent is None:
                self._first_agent = agent
        dispatch = self._attr.dispatch_of(raw)
        if run_id and dispatch:
            self._model_dispatch[run_id] = dispatch
        if name == "on_chat_model_end" and agent:
            usage = ((raw.get("data") or {}).get("output") or {}).get("usage_metadata")
            if usage:
                self._tokens[agent] = self._tokens.get(agent, 0) + usage.get("total_tokens", 0)
                self.dirty = True

    def _record_toolu_dispatch(self, raw: dict[str, Any]) -> None:
        """Bridge the AG-UI toolu id to the RAW dispatch run_id via the task's ToolMessage."""
        dispatch = raw.get("run_id")
        if not dispatch:
            return
        toolu = _find_tool_call_id(raw.get("data", {}).get("output"))
        if toolu:
            self._toolu_dispatch[toolu] = dispatch
```

3d. Add a module-level helper (near the other pure helpers, after `_format_sub`):

```python
def _find_tool_call_id(output: Any) -> str | None:
    """Recursively find a ToolMessage's tool_call_id in a RAW on_tool_end output."""
    if isinstance(output, dict):
        tcid = output.get("tool_call_id")
        if isinstance(tcid, str):
            return tcid
        for value in output.values():
            found = _find_tool_call_id(value)
            if found:
                return found
    elif isinstance(output, list):
        for value in output:
            found = _find_tool_call_id(value)
            if found:
                return found
    return None
```

3e. Replace `_nested_mono` (lines 127-138) to filter by dispatch, not agent-type name:

```python
    def _nested_mono(self, dispatch_id: str | None) -> str:
        """Summarise a sub-agent dispatch's own tool calls into a mono chip."""
        if dispatch_id is None:
            return ""
        nested = [
            t
            for t in self._tools.values()
            if t.name != "task"
            and self._model_dispatch.get(t.parent_run_id or "") == dispatch_id
        ]
        if not nested:
            return ""
        mcp = next((t for t in nested if self._is_mcp(t.name)), None)
        chosen = mcp or nested[0]
        return f"MCP {_short(chosen.name)}" if self._is_mcp(chosen.name) else _short(chosen.name)
```

3f. Update the `task` branch of `snapshot()` (lines 150-161) to use the dispatch label + dispatch-scoped nested rollup:

```python
            if tool.name == "task":
                dispatch_id = self._toolu_dispatch.get(tcid)
                if dispatch_id is not None:
                    title = self._attr.dispatch_label(dispatch_id)
                else:
                    title = tool.subagent_type or "sub-agent"
                activity.append(
                    {
                        "dot": _INFO,
                        "glow": tool.running,
                        "title": title,
                        "mono": self._nested_mono(dispatch_id),
                        "sub": _format_sub(
                            tool.running, ms, self._tokens.get(tool.subagent_type or "")
                        ),
                        "isRunning": tool.running,
                    }
                )
                continue
```

Note: token totals in `sub` remain keyed by `subagent_type` (via `self._tokens`), matching the existing behavior — the fixture's `9220 tok` / `4361 tok` assertions must stay green. Only `title` and `mono` change semantics.

- [ ] **Step 4: Run tests to verify all pass**

Run: `../.venv/bin/pytest tests/unit/test_activity_projection.py -v`
Expected: PASS — edited golden tests, the fallback-title test, and the new same-type test.

- [ ] **Step 5: Full UI + attribution regression**

Run: `../.venv/bin/pytest tests/unit/test_stream_attribution.py tests/unit/test_activity_projection.py tests/unit/test_chainlit_step_renderer.py tests/unit/test_rail_stream_touch.py tests/unit/test_agui_app.py tests/unit/test_agui_endpoint.py -v`
Expected: PASS. `stats` on the frozen fixture (`{"tokens": 29385, "tools": 4, "latency": 9910}`) must be unchanged.

- [ ] **Step 6: Lint, format, type-check**

Run: `../.venv/bin/ruff check src/autobots_devtools_shared_lib/dynagent/ui/activity_projection.py tests/unit/test_activity_projection.py && ../.venv/bin/ruff format src/autobots_devtools_shared_lib/dynagent/ui/activity_projection.py && make type-check`
Expected: no errors.

- [ ] **Step 7: Commit**

```bash
git add src/autobots_devtools_shared_lib/dynagent/ui/activity_projection.py tests/unit/test_activity_projection.py
git commit -m "feat(ui): dispatch-scoped labels and nested rollup in activity rail

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Full-suite verification

**Files:** none (verification only).

- [ ] **Step 1: Run the whole shared-lib test suite with coverage**

Run: `make test`
Expected: PASS. No regression in `dynagent/ui`.

- [ ] **Step 2: Format-check + lint + type-check the repo**

Run: `make check-format && make lint && make type-check`
Expected: no errors.

- [ ] **Step 3 (manual smoke, optional but recommended):** Start AMA and issue the reproducing prompt.

Run (from `autobots-agents-mer/`): `./sbin/run_ama.sh`
Then in the UI send: `plan for research of pros and cons for latest 3 programming languages` and confirm the three same-type subagents render as three separate, distinctly-labeled `🧵 general-purpose · …` steps with non-interleaved text, and the AMA web activity-rail shows three distinct rows.

---

## Notes for the implementer

- **Why dispatch run_id, not lc_agent_name:** N parallel subagents of the same type share one `lc_agent_name`; only the `task` dispatch `run_id` is unique per dispatch. This is the entire fix.
- **UUIDv7 trap:** two dispatch run_ids share a time-prefix. Every id comparison is full-string equality. Do not `startswith`, do not truncate for matching.
- **Legacy fallback is load-bearing:** the existing renderer tests (and classic nurture/designer domains) have no `parent_ids`. `subagent_key` returning `lc_agent_name` in that case is what keeps them working. Do not remove it.
- **Two namespaces in the projection:** rail rows are AG-UI (`toolu_…`), attribution is RAW (`run_id`). The `on_tool_end(task)` ToolMessage `tool_call_id` is the only bridge — keep `_record_toolu_dispatch`.
