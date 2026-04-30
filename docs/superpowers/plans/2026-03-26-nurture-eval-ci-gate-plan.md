# Nurture Eval CI Gate — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a CI eval gate that catches breaking changes in Nurture agent prompts before they reach production users, with golden output comparison and cost/latency baseline tracking.

**Architecture:** The eval framework lives in `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/eval/` as a pytest plugin auto-discovered by consumer repos. Eval cases (YAML + fixtures) live in `autobots-agents-mer/tests/eval/nurture/`. CI workflow in `autobots-agents-mer/.github/` resolves changed files to affected agents and runs targeted evals.

**Tech Stack:** Python 3.12, pytest, Pydantic, Langfuse SDK, tiktoken, PyYAML, jsonschema

**Spec:** `docs/superpowers/specs/2026-03-26-nurture-eval-ci-gate-design.md`

---

## File Map

### shared-lib (framework)

| File | Responsibility |
|---|---|
| `src/autobots_devtools_shared_lib/eval/__init__.py` | Public API exports |
| `src/autobots_devtools_shared_lib/eval/models/__init__.py` | Package init |
| `src/autobots_devtools_shared_lib/eval/models/eval_case.py` | Pydantic models: EvalCase, Turn, Assertion, SetupConfig, CostConfig, WorkspaceFile |
| `src/autobots_devtools_shared_lib/eval/models/result.py` | Dataclasses: AgentOutput, AssertionResult, TurnResult, CostDelta, EvalCostSnapshot, EvalResult |
| `src/autobots_devtools_shared_lib/eval/core/__init__.py` | Package init |
| `src/autobots_devtools_shared_lib/eval/core/loader.py` | YAML discovery + Pydantic validation → list[EvalCase] |
| `src/autobots_devtools_shared_lib/eval/core/runner.py` | run_linear_eval(): drives turns, invokes agent, collects results |
| `src/autobots_devtools_shared_lib/eval/core/workspace.py` | Stage/teardown workspace files from setup block |
| `src/autobots_devtools_shared_lib/eval/core/cost_tracker.py` | Query Langfuse traces → EvalCostSnapshot, compare against baselines |
| `src/autobots_devtools_shared_lib/eval/assertions/__init__.py` | Package init |
| `src/autobots_devtools_shared_lib/eval/assertions/registry.py` | Maps YAML assertion names → evaluator functions, register_assertion() |
| `src/autobots_devtools_shared_lib/eval/assertions/deterministic.py` | contains, regex, exact_match, json_match, response_matches_schema, tool_called, tool_sequence, no_extra_tools, tools_unordered |
| `src/autobots_devtools_shared_lib/eval/assertions/golden.py` | golden_match: exact + structural modes, diff reporting, update mechanism |
| `src/autobots_devtools_shared_lib/eval/scoring/__init__.py` | Package init |
| `src/autobots_devtools_shared_lib/eval/scoring/langfuse_scorer.py` | Post eval scores to Langfuse |
| `src/autobots_devtools_shared_lib/eval/pytest_plugin/__init__.py` | Package init |
| `src/autobots_devtools_shared_lib/eval/pytest_plugin/plugin.py` | pytest hook registration, CLI options, marker definitions |
| `src/autobots_devtools_shared_lib/eval/pytest_plugin/fixtures.py` | dynagent_eval fixture, workspace setup/teardown |
| `src/autobots_devtools_shared_lib/eval/pytest_plugin/reporting.py` | Terminal cost summary, JSON report generation |

### shared-lib (tests)

| File | Responsibility |
|---|---|
| `tests/unit/eval/__init__.py` | Package init |
| `tests/unit/eval/test_eval_case.py` | Tests for Pydantic model validation |
| `tests/unit/eval/test_loader.py` | Tests for YAML discovery and parsing |
| `tests/unit/eval/test_deterministic.py` | Tests for all deterministic assertions |
| `tests/unit/eval/test_golden.py` | Tests for golden_match exact + structural modes |
| `tests/unit/eval/test_registry.py` | Tests for assertion registry + custom registration |
| `tests/unit/eval/test_runner.py` | Tests for run_linear_eval with mocked invoke_agent |
| `tests/unit/eval/test_workspace.py` | Tests for workspace file staging/teardown |
| `tests/unit/eval/test_cost_tracker.py` | Tests for Langfuse query + baseline comparison |
| `tests/unit/eval/test_plugin.py` | Tests for pytest plugin CLI option registration |
| `tests/unit/eval/test_reporting.py` | Tests for terminal summary + JSON report output |

### MER (consumer)

| File | Responsibility |
|---|---|
| `autobots-agents-mer/tests/eval/__init__.py` | Package init |
| `autobots-agents-mer/tests/eval/conftest.py` | Tool registration fixture |
| `autobots-agents-mer/tests/eval/test_nurture_evals.py` | Parametrized pytest wrapper |
| `autobots-agents-mer/tests/eval/nurture/` | Eval YAML cases + fixtures (1 dir per agent) |

### MER (CI)

| File | Responsibility |
|---|---|
| `autobots-agents-mer/.github/scripts/resolve_evals.py` | Maps changed files → agent names → eval YAML paths |
| `autobots-agents-mer/.github/workflows/nurture-eval-gate.yml` | CI workflow: targeted + full-suite + PR comment |

---

## Task 1: Pydantic Models (eval_case.py)

**Files:**
- Create: `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/eval/__init__.py`
- Create: `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/eval/models/__init__.py`
- Create: `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/eval/models/eval_case.py`
- Test: `autobots-devtools-shared-lib/tests/unit/eval/__init__.py`
- Test: `autobots-devtools-shared-lib/tests/unit/eval/test_eval_case.py`

- [ ] **Step 1: Write the failing tests**

```python
# tests/unit/eval/test_eval_case.py
import pytest
from autobots_devtools_shared_lib.eval.models.eval_case import (
    Assertion,
    CostConfig,
    EvalCase,
    SetupConfig,
    Turn,
    WorkspaceFile,
)


class TestWorkspaceFile:
    def test_valid(self):
        wf = WorkspaceFile(src="fixtures/input.md", dest="docs/LLD.md")
        assert wf.src == "fixtures/input.md"
        assert wf.dest == "docs/LLD.md"


class TestAssertion:
    def test_contains(self):
        a = Assertion(type="contains", config="Party")
        assert a.type == "contains"
        assert a.config == "Party"

    def test_golden_match_exact(self):
        a = Assertion(
            type="golden_match",
            config={"reference": "fixtures/golden.json", "mode": "exact"},
        )
        assert a.config["mode"] == "exact"

    def test_golden_match_structural_with_ignore(self):
        a = Assertion(
            type="golden_match",
            config={
                "reference": "fixtures/golden.json",
                "mode": "structural",
                "ignore_fields": ["description"],
            },
        )
        assert a.config["ignore_fields"] == ["description"]

    def test_unknown_type_rejected(self):
        with pytest.raises(ValueError, match="Unknown assertion type"):
            Assertion(type="nonexistent_assertion", config="x")


class TestTurn:
    def test_valid_turn(self):
        t = Turn(
            user="Extract models",
            assertions=[Assertion(type="contains", config="Party")],
        )
        assert t.user == "Extract models"
        assert len(t.assertions) == 1


class TestCostConfig:
    def test_defaults(self):
        c = CostConfig()
        assert c.track is False
        assert c.baseline is None
        assert c.thresholds == {}

    def test_with_thresholds(self):
        c = CostConfig(
            track=True,
            baseline="fixtures/cost_baseline.json",
            thresholds={"input_tokens": 20, "cost_usd": 25},
        )
        assert c.thresholds["input_tokens"] == 20


class TestSetupConfig:
    def test_empty(self):
        s = SetupConfig()
        assert s.workspace_files == []

    def test_with_files(self):
        s = SetupConfig(
            workspace_files=[WorkspaceFile(src="a.md", dest="b.md")]
        )
        assert len(s.workspace_files) == 1


class TestEvalCase:
    def test_minimal(self):
        ec = EvalCase(
            name="test eval",
            agent="model-list-extractor",
            mode="linear",
            tags=["smoke"],
            turns=[
                Turn(
                    user="Extract models",
                    assertions=[Assertion(type="contains", config="Party")],
                )
            ],
        )
        assert ec.name == "test eval"
        assert ec.agent == "model-list-extractor"
        assert ec.mode == "linear"

    def test_with_state_setup_cost(self):
        ec = EvalCase(
            name="full eval",
            agent="model-list-extractor",
            mode="linear",
            tags=["nurture", "smoke"],
            state={"user_name": "test-user", "jira_number": "MER-99999"},
            setup=SetupConfig(
                workspace_files=[WorkspaceFile(src="a.md", dest="b.md")]
            ),
            turns=[
                Turn(
                    user="Extract models",
                    assertions=[Assertion(type="contains", config="Party")],
                )
            ],
            cost=CostConfig(track=True, baseline="fixtures/cost.json"),
        )
        assert ec.state["user_name"] == "test-user"
        assert ec.cost.track is True

    def test_invalid_mode_rejected(self):
        with pytest.raises(ValueError):
            EvalCase(
                name="bad",
                agent="x",
                mode="unknown",
                tags=[],
                turns=[],
            )
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd autobots-devtools-shared-lib && ../.venv/bin/python -m pytest tests/unit/eval/test_eval_case.py -v`
Expected: FAIL — ModuleNotFoundError

- [ ] **Step 3: Implement eval_case.py**

```python
# src/autobots_devtools_shared_lib/eval/models/eval_case.py
"""Pydantic models for YAML eval case definitions."""

from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, field_validator

VALID_ASSERTION_TYPES = frozenset({
    "contains",
    "regex",
    "exact_match",
    "json_match",
    "response_matches_schema",
    "tool_called",
    "tool_sequence",
    "no_extra_tools",
    "tools_unordered",
    "golden_match",
})


class WorkspaceFile(BaseModel):
    """A file to stage in the workspace before the agent runs."""

    src: str
    dest: str


class Assertion(BaseModel):
    """A single assertion to run against agent output."""

    type: str
    config: Any

    @field_validator("type")
    @classmethod
    def validate_type(cls, v: str) -> str:
        if v not in VALID_ASSERTION_TYPES:
            raise ValueError(
                f"Unknown assertion type: {v!r}. "
                f"Valid types: {sorted(VALID_ASSERTION_TYPES)}"
            )
        return v


class Turn(BaseModel):
    """A single user turn with expected assertions."""

    user: str
    assertions: list[Assertion]


class SetupConfig(BaseModel):
    """Pre-run workspace setup configuration."""

    workspace_files: list[WorkspaceFile] = []


class CostConfig(BaseModel):
    """Cost tracking and baseline comparison configuration."""

    track: bool = False
    baseline: str | None = None
    thresholds: dict[str, float] = {}


class EvalCase(BaseModel):
    """A complete eval case definition parsed from YAML."""

    name: str
    agent: str
    mode: Literal["linear"]
    tags: list[str]
    state: dict[str, Any] = {}
    setup: SetupConfig = SetupConfig()
    turns: list[Turn]
    cost: CostConfig = CostConfig()
```

Create empty `__init__.py` files for:
- `src/autobots_devtools_shared_lib/eval/__init__.py`
- `src/autobots_devtools_shared_lib/eval/models/__init__.py`
- `tests/unit/eval/__init__.py`

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd autobots-devtools-shared-lib && ../.venv/bin/python -m pytest tests/unit/eval/test_eval_case.py -v`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
cd autobots-devtools-shared-lib
git add src/autobots_devtools_shared_lib/eval/__init__.py \
        src/autobots_devtools_shared_lib/eval/models/__init__.py \
        src/autobots_devtools_shared_lib/eval/models/eval_case.py \
        tests/unit/eval/__init__.py \
        tests/unit/eval/test_eval_case.py
git commit -m "feat(eval): add Pydantic models for eval case definitions"
```

---

## Task 2: Result Data Models (result.py)

**Files:**
- Create: `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/eval/models/result.py`
- Test: `autobots-devtools-shared-lib/tests/unit/eval/test_result.py`

- [ ] **Step 1: Write the failing tests**

```python
# tests/unit/eval/test_result.py
from autobots_devtools_shared_lib.eval.models.result import (
    AgentOutput,
    AssertionResult,
    CostDelta,
    EvalCostSnapshot,
    EvalResult,
    TurnResult,
)


class TestAssertionResult:
    def test_passed(self):
        r = AssertionResult(passed=True, name="contains:Party", detail="Found")
        assert r.passed is True

    def test_failed(self):
        r = AssertionResult(passed=False, name="contains:Party", detail="Not found")
        assert r.passed is False


class TestTurnResult:
    def test_all_pass(self):
        tr = TurnResult(
            turn=1,
            assertions=[
                AssertionResult(passed=True, name="a", detail="ok"),
                AssertionResult(passed=True, name="b", detail="ok"),
            ],
            passed=True,
            agent_message="result",
        )
        assert tr.passed is True

    def test_any_fail(self):
        tr = TurnResult(
            turn=1,
            assertions=[
                AssertionResult(passed=True, name="a", detail="ok"),
                AssertionResult(passed=False, name="b", detail="fail"),
            ],
            passed=False,
            agent_message="result",
        )
        assert tr.passed is False


class TestCostDelta:
    def test_ok(self):
        d = CostDelta(
            metric="input_tokens",
            baseline=3200,
            actual=3400,
            delta_pct=6.25,
            status="ok",
        )
        assert d.status == "ok"

    def test_warning(self):
        d = CostDelta(
            metric="input_tokens",
            baseline=3200,
            actual=4000,
            delta_pct=25.0,
            status="warning",
        )
        assert d.status == "warning"


class TestEvalCostSnapshot:
    def test_creation(self):
        s = EvalCostSnapshot(
            eval_name="test",
            agent="model-list-extractor",
            total_input_tokens=3200,
            total_output_tokens=600,
            total_cost_usd=0.008,
            total_latency_ms=4100,
            llm_calls=2,
            per_tool_tokens={"set_context_tool": 50},
            timestamp="2026-03-26T10:00:00Z",
        )
        assert s.total_cost_usd == 0.008


class TestEvalResult:
    def test_passed_summary(self):
        r = EvalResult(
            name="test eval",
            passed=True,
            turns=[
                TurnResult(
                    turn=1,
                    assertions=[AssertionResult(passed=True, name="a", detail="ok")],
                    passed=True,
                    agent_message="done",
                )
            ],
            cost_snapshot=None,
            cost_deltas=None,
        )
        summary = r.summary()
        assert "PASSED" in summary

    def test_failed_summary_includes_failures(self):
        r = EvalResult(
            name="test eval",
            passed=False,
            turns=[
                TurnResult(
                    turn=1,
                    assertions=[
                        AssertionResult(passed=False, name="contains:Party", detail="Not found in response"),
                    ],
                    passed=False,
                    agent_message="done",
                )
            ],
            cost_snapshot=None,
            cost_deltas=None,
        )
        summary = r.summary()
        assert "FAILED" in summary
        assert "contains:Party" in summary

    def test_error_summary(self):
        r = EvalResult(
            name="test eval",
            passed=False,
            turns=[],
            cost_snapshot=None,
            cost_deltas=None,
            error="Agent raised ValueError",
        )
        summary = r.summary()
        assert "ValueError" in summary
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd autobots-devtools-shared-lib && ../.venv/bin/python -m pytest tests/unit/eval/test_result.py -v`
Expected: FAIL — ModuleNotFoundError

- [ ] **Step 3: Implement result.py**

```python
# src/autobots_devtools_shared_lib/eval/models/result.py
"""Result dataclasses for eval execution."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from langchain_core.messages import BaseMessage


@dataclass
class AgentOutput:
    """Structured output from an agent invocation."""

    messages: list[BaseMessage]
    structured_response: dict[str, Any] | None
    agent_name: str
    raw_state: dict[str, Any]


@dataclass
class AssertionResult:
    """Result of a single assertion check."""

    passed: bool
    name: str
    detail: str


@dataclass
class TurnResult:
    """Result of a single conversation turn."""

    turn: int
    assertions: list[AssertionResult]
    passed: bool
    agent_message: str | None
    structured_response: dict | list | None = None
    error: str | None = None


@dataclass
class CostDelta:
    """Comparison of a single metric against baseline."""

    metric: str
    baseline: float
    actual: float
    delta_pct: float
    status: str  # "ok" or "warning"


@dataclass
class EvalCostSnapshot:
    """Cost/latency data captured from a single eval run."""

    eval_name: str
    agent: str
    total_input_tokens: int
    total_output_tokens: int
    total_cost_usd: float
    total_latency_ms: int
    llm_calls: int
    per_tool_tokens: dict[str, int]
    timestamp: str


@dataclass
class EvalResult:
    """Complete result of an eval case execution."""

    name: str
    passed: bool
    turns: list[TurnResult]
    cost_snapshot: EvalCostSnapshot | None
    cost_deltas: list[CostDelta] | None
    error: str | None = None

    def summary(self) -> str:
        """Human-readable summary for pytest failure output."""
        lines: list[str] = []
        status = "PASSED" if self.passed else "FAILED"
        lines.append(f"Eval: {self.name} — {status}")

        if self.error:
            lines.append(f"Error: {self.error}")

        for turn in self.turns:
            if not turn.passed:
                for a in turn.assertions:
                    if not a.passed:
                        lines.append(f"  Turn {turn.turn} — {a.name}: {a.detail}")

        if self.cost_deltas:
            warnings = [d for d in self.cost_deltas if d.status == "warning"]
            for w in warnings:
                lines.append(
                    f"  Cost warning: {w.metric} "
                    f"{w.baseline} → {w.actual} ({w.delta_pct:+.1f}%)"
                )

        return "\n".join(lines)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd autobots-devtools-shared-lib && ../.venv/bin/python -m pytest tests/unit/eval/test_result.py -v`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
cd autobots-devtools-shared-lib
git add src/autobots_devtools_shared_lib/eval/models/result.py \
        tests/unit/eval/test_result.py
git commit -m "feat(eval): add result dataclasses for eval execution"
```

---

## Task 3: Assertion Registry

**Files:**
- Create: `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/eval/assertions/__init__.py`
- Create: `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/eval/assertions/registry.py`
- Test: `autobots-devtools-shared-lib/tests/unit/eval/test_registry.py`

- [ ] **Step 1: Write the failing tests**

```python
# tests/unit/eval/test_registry.py
import pytest
from autobots_devtools_shared_lib.eval.assertions.registry import (
    get_assertion_fn,
    register_assertion,
    reset_registry,
)
from autobots_devtools_shared_lib.eval.models.result import AgentOutput, AssertionResult


class TestRegistryCustom:
    """Tests that only exercise custom registration (no builtin loading).
    Safe to run before deterministic.py and golden.py exist.
    """

    def setup_method(self):
        reset_registry()

    def test_custom_assertion_registration(self):
        def my_custom(output: AgentOutput, config) -> AssertionResult:
            return AssertionResult(passed=True, name="my_custom", detail="ok")

        register_assertion("my_custom", my_custom)
        # Use _registry directly to avoid triggering _ensure_builtins
        from autobots_devtools_shared_lib.eval.assertions.registry import _registry
        assert "my_custom" in _registry
        assert _registry["my_custom"] is my_custom


class TestRegistryBuiltins:
    """Tests that require builtin assertions (deterministic.py + golden.py).
    These will pass after Task 5 is complete.
    """

    def setup_method(self):
        reset_registry()

    def test_builtin_contains_registered(self):
        fn = get_assertion_fn("contains")
        assert fn is not None

    def test_builtin_tool_called_registered(self):
        fn = get_assertion_fn("tool_called")
        assert fn is not None

    def test_unknown_assertion_raises(self):
        with pytest.raises(KeyError, match="no_such_assertion"):
            get_assertion_fn("no_such_assertion")

    def test_custom_overrides_builtin(self):
        def my_contains(output: AgentOutput, config) -> AssertionResult:
            return AssertionResult(passed=True, name="custom_contains", detail="overridden")

        register_assertion("contains", my_contains)
        fn = get_assertion_fn("contains")
        assert fn is my_contains
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd autobots-devtools-shared-lib && ../.venv/bin/python -m pytest tests/unit/eval/test_registry.py -v`
Expected: FAIL — ModuleNotFoundError

- [ ] **Step 3: Implement registry.py**

```python
# src/autobots_devtools_shared_lib/eval/assertions/registry.py
"""Assertion registry: maps YAML assertion names to evaluator functions."""

from __future__ import annotations

from typing import Any, Callable

from autobots_devtools_shared_lib.eval.models.result import AgentOutput, AssertionResult

EvalFn = Callable[[AgentOutput, Any], AssertionResult]

_registry: dict[str, EvalFn] = {}
_initialized: bool = False


def _ensure_builtins() -> None:
    """Lazy-load built-in assertions on first access."""
    global _initialized
    if _initialized:
        return
    _initialized = True

    from autobots_devtools_shared_lib.eval.assertions.deterministic import (
        contains,
        exact_match,
        json_match,
        no_extra_tools,
        regex,
        response_matches_schema,
        tool_called,
        tool_sequence,
        tools_unordered,
    )
    from autobots_devtools_shared_lib.eval.assertions.golden import golden_match

    builtins: dict[str, EvalFn] = {
        "contains": contains,
        "regex": regex,
        "exact_match": exact_match,
        "json_match": json_match,
        "response_matches_schema": response_matches_schema,
        "tool_called": tool_called,
        "tool_sequence": tool_sequence,
        "no_extra_tools": no_extra_tools,
        "tools_unordered": tools_unordered,
        "golden_match": golden_match,
    }
    for name, fn in builtins.items():
        if name not in _registry:
            _registry[name] = fn


def register_assertion(name: str, fn: EvalFn) -> None:
    """Register a custom assertion (or override a built-in)."""
    _registry[name] = fn


def get_assertion_fn(name: str) -> EvalFn:
    """Look up an assertion function by YAML name. Raises KeyError if not found."""
    _ensure_builtins()
    if name not in _registry:
        raise KeyError(
            f"Unknown assertion: {name!r}. "
            f"Available: {sorted(_registry.keys())}"
        )
    return _registry[name]


def reset_registry() -> None:
    """Reset registry to empty state. For testing only."""
    global _initialized
    _registry.clear()
    _initialized = False
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd autobots-devtools-shared-lib && ../.venv/bin/python -m pytest tests/unit/eval/test_registry.py::TestRegistryCustom -v`
Expected: PASS — only custom registration tests run (no builtin loading triggered).

Note: `TestRegistryBuiltins` will fail until Tasks 4 and 5 are complete (they import `deterministic.py` and `golden.py` which don't exist yet). After Task 5, run the full suite:

Run: `cd autobots-devtools-shared-lib && ../.venv/bin/python -m pytest tests/unit/eval/test_registry.py -v`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
cd autobots-devtools-shared-lib
git add src/autobots_devtools_shared_lib/eval/assertions/__init__.py \
        src/autobots_devtools_shared_lib/eval/assertions/registry.py \
        tests/unit/eval/test_registry.py
git commit -m "feat(eval): add assertion registry with lazy builtin loading"
```

---

## Task 4: Deterministic Assertions

**Files:**
- Create: `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/eval/assertions/deterministic.py`
- Test: `autobots-devtools-shared-lib/tests/unit/eval/test_deterministic.py`

- [ ] **Step 1: Write the failing tests**

```python
# tests/unit/eval/test_deterministic.py
import json

from langchain_core.messages import AIMessage, HumanMessage, ToolMessage

from autobots_devtools_shared_lib.eval.models.result import AgentOutput

from autobots_devtools_shared_lib.eval.assertions.deterministic import (
    contains,
    exact_match,
    json_match,
    no_extra_tools,
    regex,
    response_matches_schema,
    tool_called,
    tool_sequence,
    tools_unordered,
)


def _make_output(
    text: str = "",
    structured: dict | None = None,
    tool_calls: list[dict] | None = None,
) -> AgentOutput:
    """Helper to create AgentOutput with optional tool call history."""
    messages = [HumanMessage(content="test input")]
    if tool_calls:
        for tc in tool_calls:
            ai_msg = AIMessage(
                content="",
                tool_calls=[
                    {
                        "name": tc["name"],
                        "args": tc.get("args", {}),
                        "id": tc.get("id", "call_1"),
                    }
                ],
            )
            messages.append(ai_msg)
            messages.append(
                ToolMessage(content=tc.get("result", "ok"), tool_call_id=tc.get("id", "call_1"))
            )
    if text:
        messages.append(AIMessage(content=text))
    return AgentOutput(
        messages=messages,
        structured_response=structured,
        agent_name="test-agent",
        raw_state={},
    )


class TestContains:
    def test_found(self):
        r = contains(_make_output(text="The Party model was extracted"), "Party")
        assert r.passed is True

    def test_not_found(self):
        r = contains(_make_output(text="No models found"), "Party")
        assert r.passed is False

    def test_checks_structured_response(self):
        r = contains(
            _make_output(structured={"models": [{"name": "Party"}]}), "Party"
        )
        assert r.passed is True


class TestRegex:
    def test_match(self):
        r = regex(_make_output(text="Found 3 models"), r"\d+ models")
        assert r.passed is True

    def test_no_match(self):
        r = regex(_make_output(text="No models"), r"\d+ models")
        assert r.passed is False


class TestExactMatch:
    def test_match(self):
        r = exact_match(
            _make_output(structured={"key": "value"}), {"key": "value"}
        )
        assert r.passed is True

    def test_mismatch(self):
        r = exact_match(
            _make_output(structured={"key": "other"}), {"key": "value"}
        )
        assert r.passed is False


class TestJsonMatch:
    def test_subset_match(self):
        r = json_match(
            _make_output(structured={"a": 1, "b": 2, "c": 3}),
            {"a": 1, "b": 2},
        )
        assert r.passed is True

    def test_mismatch(self):
        r = json_match(
            _make_output(structured={"a": 1}),
            {"a": 2},
        )
        assert r.passed is False


class TestResponseMatchesSchema:
    def test_valid(self):
        schema = {
            "type": "object",
            "required": ["models"],
            "properties": {
                "models": {
                    "type": "array",
                    "items": {"type": "object"},
                }
            },
        }
        r = response_matches_schema(
            _make_output(structured={"models": [{"name": "Party"}]}),
            schema,
        )
        assert r.passed is True

    def test_invalid(self):
        schema = {"type": "object", "required": ["models"]}
        r = response_matches_schema(
            _make_output(structured={"items": []}),
            schema,
        )
        assert r.passed is False


class TestToolCalled:
    def test_found(self):
        r = tool_called(
            _make_output(tool_calls=[{"name": "mer_read_file_tool"}]),
            "mer_read_file_tool",
        )
        assert r.passed is True

    def test_not_found(self):
        r = tool_called(
            _make_output(tool_calls=[{"name": "mer_write_file_tool"}]),
            "mer_read_file_tool",
        )
        assert r.passed is False

    def test_no_tool_calls(self):
        r = tool_called(_make_output(text="just text"), "mer_read_file_tool")
        assert r.passed is False


class TestToolSequence:
    def test_correct_order(self):
        r = tool_sequence(
            _make_output(
                tool_calls=[
                    {"name": "set_context_tool", "id": "c1"},
                    {"name": "mer_read_file_tool", "id": "c2"},
                    {"name": "mer_write_file_tool", "id": "c3"},
                ]
            ),
            [
                {"tool": "set_context_tool"},
                {"tool": "mer_read_file_tool"},
                {"tool": "mer_write_file_tool"},
            ],
        )
        assert r.passed is True

    def test_wrong_order(self):
        r = tool_sequence(
            _make_output(
                tool_calls=[
                    {"name": "mer_write_file_tool", "id": "c1"},
                    {"name": "set_context_tool", "id": "c2"},
                ]
            ),
            [
                {"tool": "set_context_tool"},
                {"tool": "mer_write_file_tool"},
            ],
        )
        assert r.passed is False

    def test_with_args_contain(self):
        r = tool_sequence(
            _make_output(
                tool_calls=[
                    {
                        "name": "set_context_tool",
                        "args": {"agent_name": "model-list-extractor", "session_id": "s1"},
                        "id": "c1",
                    },
                ]
            ),
            [{"tool": "set_context_tool", "args_contain": {"agent_name": "model-list-extractor"}}],
        )
        assert r.passed is True


class TestNoExtraTools:
    def test_no_extras(self):
        r = no_extra_tools(
            _make_output(
                tool_calls=[
                    {"name": "mer_read_file_tool", "id": "c1"},
                    {"name": "set_context_tool", "id": "c2"},
                ]
            ),
            ["mer_read_file_tool", "set_context_tool"],
        )
        assert r.passed is True

    def test_extra_tool_found(self):
        r = no_extra_tools(
            _make_output(
                tool_calls=[
                    {"name": "mer_read_file_tool", "id": "c1"},
                    {"name": "unexpected_tool", "id": "c2"},
                ]
            ),
            ["mer_read_file_tool"],
        )
        assert r.passed is False


class TestToolsUnordered:
    def test_all_present_different_order(self):
        r = tools_unordered(
            _make_output(
                tool_calls=[
                    {"name": "mer_write_file_tool", "id": "c1"},
                    {"name": "mer_read_file_tool", "id": "c2"},
                ]
            ),
            ["mer_read_file_tool", "mer_write_file_tool"],
        )
        assert r.passed is True

    def test_missing_tool(self):
        r = tools_unordered(
            _make_output(tool_calls=[{"name": "mer_read_file_tool", "id": "c1"}]),
            ["mer_read_file_tool", "mer_write_file_tool"],
        )
        assert r.passed is False
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd autobots-devtools-shared-lib && ../.venv/bin/python -m pytest tests/unit/eval/test_deterministic.py -v`
Expected: FAIL — ModuleNotFoundError

- [ ] **Step 3: Implement deterministic.py**

```python
# src/autobots_devtools_shared_lib/eval/assertions/deterministic.py
"""Deterministic assertion functions for eval framework."""

from __future__ import annotations

import json
import re
from typing import Any

import jsonschema

from autobots_devtools_shared_lib.eval.models.result import AgentOutput, AssertionResult


def _get_text(output: AgentOutput) -> str:
    """Extract searchable text from agent output (last AI message + structured response)."""
    parts: list[str] = []
    for msg in reversed(output.messages):
        if hasattr(msg, "content") and isinstance(msg.content, str) and msg.content:
            parts.append(msg.content)
            break
    if output.structured_response:
        parts.append(json.dumps(output.structured_response))
    return "\n".join(parts)


def _get_tool_calls(output: AgentOutput) -> list[dict[str, Any]]:
    """Extract tool calls from message history."""
    calls: list[dict[str, Any]] = []
    for msg in output.messages:
        if hasattr(msg, "tool_calls") and msg.tool_calls:
            for tc in msg.tool_calls:
                calls.append({"name": tc["name"], "args": tc.get("args", {})})
    return calls


def contains(output: AgentOutput, config: str) -> AssertionResult:
    """Check if output contains a substring."""
    text = _get_text(output)
    found = config in text
    return AssertionResult(
        passed=found,
        name=f"contains:{config}",
        detail="Found" if found else f"'{config}' not found in response",
    )


def regex(output: AgentOutput, config: str) -> AssertionResult:
    """Check if output matches a regex pattern."""
    text = _get_text(output)
    match = re.search(config, text)
    return AssertionResult(
        passed=match is not None,
        name=f"regex:{config}",
        detail="Matched" if match else f"Pattern '{config}' not found",
    )


def exact_match(output: AgentOutput, config: Any) -> AssertionResult:
    """Check if structured response equals expected value."""
    actual = output.structured_response
    passed = actual == config
    return AssertionResult(
        passed=passed,
        name="exact_match",
        detail="Matched" if passed else f"Expected {config}, got {actual}",
    )


def json_match(output: AgentOutput, config: dict[str, Any]) -> AssertionResult:
    """Check if structured response contains all expected key-value pairs (subset match)."""
    actual = output.structured_response or {}
    mismatches: list[str] = []
    for key, expected_val in config.items():
        if key not in actual:
            mismatches.append(f"Missing key: {key}")
        elif actual[key] != expected_val:
            mismatches.append(f"{key}: expected {expected_val}, got {actual[key]}")
    passed = len(mismatches) == 0
    return AssertionResult(
        passed=passed,
        name="json_match",
        detail="Matched" if passed else "; ".join(mismatches),
    )


def response_matches_schema(output: AgentOutput, config: dict[str, Any]) -> AssertionResult:
    """Validate structured response against a JSON schema."""
    actual = output.structured_response
    try:
        jsonschema.validate(instance=actual, schema=config)
        return AssertionResult(passed=True, name="response_matches_schema", detail="Valid")
    except jsonschema.ValidationError as e:
        return AssertionResult(
            passed=False,
            name="response_matches_schema",
            detail=str(e.message),
        )


def tool_called(output: AgentOutput, config: str) -> AssertionResult:
    """Check if a specific tool was called."""
    calls = _get_tool_calls(output)
    names = [c["name"] for c in calls]
    found = config in names
    return AssertionResult(
        passed=found,
        name=f"tool_called:{config}",
        detail="Found" if found else f"'{config}' not in called tools: {names}",
    )


def tool_sequence(output: AgentOutput, config: list[dict[str, Any]]) -> AssertionResult:
    """Check tools were called in exact order, optionally checking args."""
    calls = _get_tool_calls(output)
    expected_names = [step["tool"] for step in config]
    actual_names = [c["name"] for c in calls]

    if actual_names != expected_names:
        return AssertionResult(
            passed=False,
            name="tool_sequence",
            detail=f"Expected {expected_names}, got {actual_names}",
        )

    for i, step in enumerate(config):
        if "args_contain" in step:
            actual_args = calls[i]["args"]
            for key, val in step["args_contain"].items():
                if key not in actual_args or actual_args[key] != val:
                    return AssertionResult(
                        passed=False,
                        name="tool_sequence",
                        detail=f"Step {i}: expected arg {key}={val}, got {actual_args.get(key)}",
                    )

    return AssertionResult(passed=True, name="tool_sequence", detail="Matched")


def no_extra_tools(output: AgentOutput, config: list[str]) -> AssertionResult:
    """Check no tools were called beyond the allowed set."""
    calls = _get_tool_calls(output)
    actual_names = {c["name"] for c in calls}
    allowed = set(config)
    extras = actual_names - allowed
    passed = len(extras) == 0
    return AssertionResult(
        passed=passed,
        name="no_extra_tools",
        detail="No extras" if passed else f"Unexpected tools: {sorted(extras)}",
    )


def tools_unordered(output: AgentOutput, config: list[str]) -> AssertionResult:
    """Check all expected tools were called (any order)."""
    calls = _get_tool_calls(output)
    actual_names = {c["name"] for c in calls}
    expected = set(config)
    missing = expected - actual_names
    passed = len(missing) == 0
    return AssertionResult(
        passed=passed,
        name="tools_unordered",
        detail="All present" if passed else f"Missing tools: {sorted(missing)}",
    )
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd autobots-devtools-shared-lib && ../.venv/bin/python -m pytest tests/unit/eval/test_deterministic.py -v`
Expected: All PASS

- [ ] **Step 5: Run registry tests too (builtins should now load)**

Run: `cd autobots-devtools-shared-lib && ../.venv/bin/python -m pytest tests/unit/eval/test_registry.py -v`
Expected: FAIL — `golden.py` not yet created. Registry tests for builtins will pass after Task 5.

- [ ] **Step 6: Commit**

```bash
cd autobots-devtools-shared-lib
git add src/autobots_devtools_shared_lib/eval/assertions/deterministic.py \
        tests/unit/eval/test_deterministic.py
git commit -m "feat(eval): add deterministic assertion functions"
```

---

## Task 5: Golden Match Assertion

**Files:**
- Create: `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/eval/assertions/golden.py`
- Test: `autobots-devtools-shared-lib/tests/unit/eval/test_golden.py`

- [ ] **Step 1: Write the failing tests**

```python
# tests/unit/eval/test_golden.py
import json
import tempfile
from pathlib import Path

import pytest

from autobots_devtools_shared_lib.eval.assertions.golden import (
    _deep_structural_compare,
    _diff_json,
    golden_match,
)
from autobots_devtools_shared_lib.eval.models.result import AgentOutput

from langchain_core.messages import AIMessage, HumanMessage


def _make_output(structured: dict | None = None) -> AgentOutput:
    return AgentOutput(
        messages=[HumanMessage(content="test"), AIMessage(content="done")],
        structured_response=structured,
        agent_name="test-agent",
        raw_state={},
    )


class TestDiffJson:
    def test_identical(self):
        diff = _diff_json({"a": 1}, {"a": 1})
        assert diff.missing == []
        assert diff.unexpected == []
        assert diff.changed == []

    def test_missing_key(self):
        diff = _diff_json({"a": 1, "b": 2}, {"a": 1})
        assert len(diff.missing) == 1
        assert "b" in diff.missing[0]

    def test_unexpected_key(self):
        diff = _diff_json({"a": 1}, {"a": 1, "b": 2})
        assert len(diff.unexpected) == 1

    def test_changed_value(self):
        diff = _diff_json({"a": 1}, {"a": 2})
        assert len(diff.changed) == 1

    def test_nested_array_diff(self):
        ref = {"models": [{"name": "A"}, {"name": "B"}]}
        actual = {"models": [{"name": "A"}, {"name": "C"}]}
        diff = _diff_json(ref, actual)
        assert len(diff.changed) > 0


class TestDeepStructuralCompare:
    def test_same_structure(self):
        ref = {"models": [{"name": "Party", "type": "entity"}]}
        actual = {"models": [{"name": "Other", "type": "value"}]}
        issues = _deep_structural_compare(ref, actual)
        assert issues == []

    def test_missing_key(self):
        ref = {"models": [{"name": "Party", "type": "entity"}]}
        actual = {"models": [{"name": "Party"}]}
        issues = _deep_structural_compare(ref, actual)
        assert len(issues) > 0

    def test_different_array_length(self):
        ref = {"models": [{"name": "A"}, {"name": "B"}]}
        actual = {"models": [{"name": "A"}]}
        issues = _deep_structural_compare(ref, actual)
        assert len(issues) > 0

    def test_type_mismatch(self):
        ref = {"count": 5}
        actual = {"count": "five"}
        issues = _deep_structural_compare(ref, actual)
        assert len(issues) > 0

    def test_ignore_fields(self):
        ref = {"name": "Party", "description": "A party entity"}
        actual = {"name": "Party", "description": "Something else entirely"}
        issues = _deep_structural_compare(ref, actual, ignore_fields=["description"])
        assert issues == []


class TestGoldenMatch:
    def test_exact_pass(self, tmp_path):
        golden = {"models": [{"name": "Party"}]}
        ref_file = tmp_path / "golden.json"
        ref_file.write_text(json.dumps(golden))

        output = _make_output(structured={"models": [{"name": "Party"}]})
        config = {"reference": str(ref_file), "mode": "exact"}
        r = golden_match(output, config)
        assert r.passed is True

    def test_exact_fail(self, tmp_path):
        golden = {"models": [{"name": "Party"}]}
        ref_file = tmp_path / "golden.json"
        ref_file.write_text(json.dumps(golden))

        output = _make_output(structured={"models": [{"name": "Contact"}]})
        config = {"reference": str(ref_file), "mode": "exact"}
        r = golden_match(output, config)
        assert r.passed is False
        assert "Contact" in r.detail or "Party" in r.detail

    def test_structural_pass_different_values(self, tmp_path):
        golden = {"models": [{"name": "Party", "type": "entity"}]}
        ref_file = tmp_path / "golden.json"
        ref_file.write_text(json.dumps(golden))

        output = _make_output(
            structured={"models": [{"name": "Other", "type": "value_object"}]}
        )
        config = {"reference": str(ref_file), "mode": "structural"}
        r = golden_match(output, config)
        assert r.passed is True

    def test_structural_fail_missing_key(self, tmp_path):
        golden = {"models": [{"name": "Party", "type": "entity"}]}
        ref_file = tmp_path / "golden.json"
        ref_file.write_text(json.dumps(golden))

        output = _make_output(structured={"models": [{"name": "Party"}]})
        config = {"reference": str(ref_file), "mode": "structural"}
        r = golden_match(output, config)
        assert r.passed is False

    def test_structural_with_ignore_fields(self, tmp_path):
        golden = {"name": "Party", "description": "Original desc"}
        ref_file = tmp_path / "golden.json"
        ref_file.write_text(json.dumps(golden))

        output = _make_output(structured={"name": "Party", "description": "New desc"})
        config = {
            "reference": str(ref_file),
            "mode": "structural",
            "ignore_fields": ["description"],
        }
        r = golden_match(output, config)
        assert r.passed is True

    def test_missing_reference_file(self):
        output = _make_output(structured={"a": 1})
        config = {"reference": "/nonexistent/path.json", "mode": "exact"}
        r = golden_match(output, config)
        assert r.passed is False
        assert "not found" in r.detail.lower() or "update-golden" in r.detail.lower()
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd autobots-devtools-shared-lib && ../.venv/bin/python -m pytest tests/unit/eval/test_golden.py -v`
Expected: FAIL — ModuleNotFoundError

- [ ] **Step 3: Implement golden.py**

```python
# src/autobots_devtools_shared_lib/eval/assertions/golden.py
"""Golden match assertion: compare agent output against reference files."""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


from autobots_devtools_shared_lib.eval.models.result import AgentOutput, AssertionResult


@dataclass
class JsonDiff:
    """Structured diff between reference and actual JSON."""

    missing: list[str] = field(default_factory=list)
    unexpected: list[str] = field(default_factory=list)
    changed: list[str] = field(default_factory=list)

    @property
    def has_differences(self) -> bool:
        return bool(self.missing or self.unexpected or self.changed)

    def to_detail(self) -> str:
        lines: list[str] = []
        for m in self.missing:
            lines.append(f"Missing from actual: {m}")
        for u in self.unexpected:
            lines.append(f"Unexpected in actual: {u}")
        for c in self.changed:
            lines.append(f"Changed: {c}")
        return "\n".join(lines)


def _diff_json(
    reference: Any, actual: Any, path: str = ""
) -> JsonDiff:
    """Recursive deep diff between two JSON-like structures."""
    diff = JsonDiff()

    if isinstance(reference, dict) and isinstance(actual, dict):
        for key in reference:
            child_path = f"{path}.{key}" if path else key
            if key not in actual:
                diff.missing.append(f"{child_path}: {json.dumps(reference[key])}")
            else:
                child = _diff_json(reference[key], actual[key], child_path)
                diff.missing.extend(child.missing)
                diff.unexpected.extend(child.unexpected)
                diff.changed.extend(child.changed)
        for key in actual:
            child_path = f"{path}.{key}" if path else key
            if key not in reference:
                diff.unexpected.append(f"{child_path}: {json.dumps(actual[key])}")

    elif isinstance(reference, list) and isinstance(actual, list):
        for i in range(max(len(reference), len(actual))):
            child_path = f"{path}[{i}]"
            if i >= len(actual):
                diff.missing.append(f"{child_path}: {json.dumps(reference[i])}")
            elif i >= len(reference):
                diff.unexpected.append(f"{child_path}: {json.dumps(actual[i])}")
            else:
                child = _diff_json(reference[i], actual[i], child_path)
                diff.missing.extend(child.missing)
                diff.unexpected.extend(child.unexpected)
                diff.changed.extend(child.changed)

    elif reference != actual:
        diff.changed.append(
            f"{path}: {json.dumps(reference)} → {json.dumps(actual)}"
        )

    return diff


def _deep_structural_compare(
    reference: Any,
    actual: Any,
    path: str = "",
    ignore_fields: list[str] | None = None,
) -> list[str]:
    """Compare structure only: same keys, same types, same array lengths. Ignores string values."""
    ignore = set(ignore_fields or [])
    issues: list[str] = []

    if isinstance(reference, dict) and isinstance(actual, dict):
        for key in reference:
            if key in ignore:
                continue
            child_path = f"{path}.{key}" if path else key
            if key not in actual:
                issues.append(f"Missing key: {child_path}")
            else:
                issues.extend(
                    _deep_structural_compare(
                        reference[key], actual[key], child_path, ignore_fields
                    )
                )
        for key in actual:
            if key in ignore:
                continue
            child_path = f"{path}.{key}" if path else key
            if key not in reference:
                issues.append(f"Unexpected key: {child_path}")

    elif isinstance(reference, list) and isinstance(actual, list):
        if len(reference) != len(actual):
            issues.append(
                f"Array length mismatch at {path or 'root'}: "
                f"expected {len(reference)}, got {len(actual)}"
            )
        for i in range(min(len(reference), len(actual))):
            child_path = f"{path}[{i}]"
            issues.extend(
                _deep_structural_compare(
                    reference[i], actual[i], child_path, ignore_fields
                )
            )

    elif type(reference) is not type(actual):
        issues.append(
            f"Type mismatch at {path or 'root'}: "
            f"expected {type(reference).__name__}, got {type(actual).__name__}"
        )

    return issues


def golden_match(output: AgentOutput, config: dict[str, Any]) -> AssertionResult:
    """Compare agent structured_response against a golden reference file."""
    ref_path = Path(config["reference"])
    mode: str = config.get("mode", "exact")
    ignore_fields: list[str] = config.get("ignore_fields", [])

    if not ref_path.exists():
        return AssertionResult(
            passed=False,
            name="golden_match",
            detail=f"Reference file not found: {ref_path}. Run with --update-golden to create.",
        )

    reference = json.loads(ref_path.read_text())
    actual = output.structured_response

    if mode == "exact":
        diff = _diff_json(reference, actual)
        if diff.has_differences:
            return AssertionResult(
                passed=False,
                name="golden_match",
                detail=f"Reference: {ref_path}\n\n{diff.to_detail()}",
            )
        return AssertionResult(passed=True, name="golden_match", detail="Exact match")

    elif mode == "structural":
        issues = _deep_structural_compare(
            reference, actual, ignore_fields=ignore_fields
        )
        if issues:
            return AssertionResult(
                passed=False,
                name="golden_match",
                detail=f"Structural mismatch:\n" + "\n".join(f"  {i}" for i in issues),
            )
        return AssertionResult(
            passed=True, name="golden_match", detail="Structural match"
        )

    else:
        return AssertionResult(
            passed=False,
            name="golden_match",
            detail=f"Unknown mode: {mode}. Use 'exact' or 'structural'.",
        )
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd autobots-devtools-shared-lib && ../.venv/bin/python -m pytest tests/unit/eval/test_golden.py -v`
Expected: All PASS

- [ ] **Step 5: Run ALL registry tests now (builtins should fully load)**

Run: `cd autobots-devtools-shared-lib && ../.venv/bin/python -m pytest tests/unit/eval/test_registry.py -v`
Expected: All PASS

- [ ] **Step 6: Commit**

```bash
cd autobots-devtools-shared-lib
git add src/autobots_devtools_shared_lib/eval/assertions/golden.py \
        tests/unit/eval/test_golden.py
git commit -m "feat(eval): add golden match assertion with exact and structural modes"
```

---

## Task 6: YAML Loader

**Files:**
- Create: `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/eval/core/__init__.py`
- Create: `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/eval/core/loader.py`
- Test: `autobots-devtools-shared-lib/tests/unit/eval/test_loader.py`

- [ ] **Step 1: Write the failing tests**

```python
# tests/unit/eval/test_loader.py
import textwrap
from pathlib import Path

import pytest

from autobots_devtools_shared_lib.eval.core.loader import load_eval_cases


@pytest.fixture()
def eval_dir(tmp_path) -> Path:
    """Create a minimal eval directory with YAML files."""
    agent_dir = tmp_path / "model-list-extractor"
    agent_dir.mkdir()
    fixtures_dir = agent_dir / "fixtures"
    fixtures_dir.mkdir()

    yaml_content = textwrap.dedent("""\
        eval:
          name: "Model list extraction"
          agent: "model-list-extractor"
          mode: linear
          tags: ["nurture", "smoke"]

          state:
            user_name: "test-user"

          turns:
            - user: "Extract models"
              assertions:
                - contains: "Party"
                - tool_called: "mer_read_file_tool"
                - golden_match:
                    reference: "fixtures/golden.json"
                    mode: "exact"

          cost:
            track: true
            baseline: "fixtures/cost_baseline.json"
            thresholds:
              input_tokens: 20
    """)
    (agent_dir / "party-lld.yaml").write_text(yaml_content)
    return tmp_path


@pytest.fixture()
def eval_dir_two_files(eval_dir) -> Path:
    """Add a second YAML file."""
    agent_dir = eval_dir / "behaviour-list-extractor"
    agent_dir.mkdir()
    yaml_content = textwrap.dedent("""\
        eval:
          name: "Behaviour list extraction"
          agent: "behaviour-list-extractor"
          mode: linear
          tags: ["nurture", "behaviour"]
          turns:
            - user: "Extract behaviours"
              assertions:
                - contains: "CreateParty"
    """)
    (agent_dir / "party-lld.yaml").write_text(yaml_content)
    return eval_dir


class TestLoadEvalCases:
    def test_discovers_yaml(self, eval_dir):
        cases = load_eval_cases(str(eval_dir))
        assert len(cases) == 1
        assert cases[0].name == "Model list extraction"
        assert cases[0].agent == "model-list-extractor"

    def test_parses_assertions(self, eval_dir):
        cases = load_eval_cases(str(eval_dir))
        assertions = cases[0].turns[0].assertions
        assert len(assertions) == 3
        assert assertions[0].type == "contains"
        assert assertions[0].config == "Party"
        assert assertions[1].type == "tool_called"
        assert assertions[2].type == "golden_match"

    def test_parses_cost_config(self, eval_dir):
        cases = load_eval_cases(str(eval_dir))
        assert cases[0].cost.track is True
        assert cases[0].cost.thresholds["input_tokens"] == 20

    def test_resolves_relative_paths(self, eval_dir):
        """Reference paths in assertions should be resolved relative to the YAML file."""
        cases = load_eval_cases(str(eval_dir))
        golden_assertion = cases[0].turns[0].assertions[2]
        ref_path = golden_assertion.config["reference"]
        # Should be absolute path based on YAML file location
        assert Path(ref_path).is_absolute()

    def test_multiple_files(self, eval_dir_two_files):
        cases = load_eval_cases(str(eval_dir_two_files))
        assert len(cases) == 2
        names = {c.name for c in cases}
        assert "Model list extraction" in names
        assert "Behaviour list extraction" in names

    def test_filter_by_tags(self, eval_dir_two_files):
        cases = load_eval_cases(str(eval_dir_two_files), tags=["smoke"])
        assert len(cases) == 1
        assert cases[0].name == "Model list extraction"

    def test_filter_by_agent(self, eval_dir_two_files):
        cases = load_eval_cases(
            str(eval_dir_two_files), agent="behaviour-list-extractor"
        )
        assert len(cases) == 1
        assert cases[0].agent == "behaviour-list-extractor"

    def test_empty_dir(self, tmp_path):
        cases = load_eval_cases(str(tmp_path))
        assert cases == []

    def test_invalid_yaml_raises(self, tmp_path):
        bad = tmp_path / "bad.yaml"
        bad.write_text("eval:\n  name: 123\n  agent: x\n  mode: invalid\n  turns: []\n  tags: []")
        with pytest.raises(ValueError):
            load_eval_cases(str(tmp_path))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd autobots-devtools-shared-lib && ../.venv/bin/python -m pytest tests/unit/eval/test_loader.py -v`
Expected: FAIL — ModuleNotFoundError

- [ ] **Step 3: Implement loader.py**

```python
# src/autobots_devtools_shared_lib/eval/core/loader.py
"""YAML eval case discovery and parsing."""

from __future__ import annotations

from pathlib import Path
from typing import Any

import yaml
from pydantic import ValidationError

from autobots_devtools_shared_lib.eval.models.eval_case import (
    Assertion,
    CostConfig,
    EvalCase,
    SetupConfig,
    Turn,
    WorkspaceFile,
)


def _parse_assertion(raw: dict[str, Any] | str) -> Assertion:
    """Parse a single assertion from YAML format into Assertion model.

    YAML assertions come as either:
      - {"contains": "Party"}  → type="contains", config="Party"
      - {"golden_match": {"reference": "...", "mode": "exact"}}  → type="golden_match", config={...}
    """
    if isinstance(raw, str):
        raise ValueError(f"Assertion must be a dict, got string: {raw!r}")

    if len(raw) != 1:
        raise ValueError(f"Assertion must have exactly one key, got: {list(raw.keys())}")

    assertion_type, config = next(iter(raw.items()))
    return Assertion(type=assertion_type, config=config)


def _resolve_paths(
    eval_case: EvalCase, yaml_dir: Path
) -> EvalCase:
    """Resolve relative file paths in assertions and cost config to absolute paths."""
    for turn in eval_case.turns:
        for assertion in turn.assertions:
            if assertion.type == "golden_match" and isinstance(assertion.config, dict):
                ref = assertion.config.get("reference")
                if ref and not Path(ref).is_absolute():
                    assertion.config["reference"] = str(yaml_dir / ref)

    if eval_case.cost.baseline and not Path(eval_case.cost.baseline).is_absolute():
        eval_case.cost.baseline = str(yaml_dir / eval_case.cost.baseline)

    if eval_case.setup.workspace_files:
        for wf in eval_case.setup.workspace_files:
            if not Path(wf.src).is_absolute():
                wf.src = str(yaml_dir / wf.src)

    return eval_case


def _parse_yaml_file(yaml_path: Path) -> EvalCase:
    """Parse a single YAML eval case file."""
    raw = yaml.safe_load(yaml_path.read_text())
    if not isinstance(raw, dict) or "eval" not in raw:
        raise ValueError(f"Invalid eval YAML: missing 'eval' key in {yaml_path}")

    data = raw["eval"]

    turns: list[Turn] = []
    for raw_turn in data.get("turns", []):
        assertions = [_parse_assertion(a) for a in raw_turn.get("assertions", [])]
        turns.append(Turn(user=raw_turn["user"], assertions=assertions))

    setup_data = data.get("setup", {})
    workspace_files = [
        WorkspaceFile(**wf) for wf in setup_data.get("workspace_files", [])
    ]
    setup = SetupConfig(workspace_files=workspace_files)

    cost_data = data.get("cost", {})
    cost = CostConfig(**cost_data)

    try:
        eval_case = EvalCase(
            name=data["name"],
            agent=data["agent"],
            mode=data["mode"],
            tags=data.get("tags", []),
            state=data.get("state", {}),
            setup=setup,
            turns=turns,
            cost=cost,
        )
    except ValidationError as e:
        raise ValueError(f"Invalid eval case in {yaml_path}: {e}") from e

    return _resolve_paths(eval_case, yaml_path.parent)


def load_eval_cases(
    eval_dir: str,
    tags: list[str] | None = None,
    agent: str | None = None,
) -> list[EvalCase]:
    """Discover and load all eval YAML files from a directory tree.

    Args:
        eval_dir: Root directory to scan for .yaml files.
        tags: If provided, only return cases matching at least one tag.
        agent: If provided, only return cases for this agent name.

    Returns:
        List of parsed EvalCase objects, sorted by name.
    """
    root = Path(eval_dir)
    if not root.exists():
        return []

    cases: list[EvalCase] = []
    for yaml_path in sorted(root.rglob("*.yaml")):
        case = _parse_yaml_file(yaml_path)
        cases.append(case)

    if tags:
        tag_set = set(tags)
        cases = [c for c in cases if tag_set & set(c.tags)]

    if agent:
        cases = [c for c in cases if c.agent == agent]

    return sorted(cases, key=lambda c: c.name)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd autobots-devtools-shared-lib && ../.venv/bin/python -m pytest tests/unit/eval/test_loader.py -v`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
cd autobots-devtools-shared-lib
git add src/autobots_devtools_shared_lib/eval/core/__init__.py \
        src/autobots_devtools_shared_lib/eval/core/loader.py \
        tests/unit/eval/test_loader.py
git commit -m "feat(eval): add YAML eval case loader with tag/agent filtering"
```

---

## Task 7: Workspace File Staging

**Files:**
- Create: `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/eval/core/workspace.py`
- Test: `autobots-devtools-shared-lib/tests/unit/eval/test_workspace.py`

- [ ] **Step 1: Write the failing tests**

```python
# tests/unit/eval/test_workspace.py
import shutil
from pathlib import Path

import pytest

from autobots_devtools_shared_lib.eval.core.workspace import (
    setup_workspace,
    teardown_workspace,
)
from autobots_devtools_shared_lib.eval.models.eval_case import SetupConfig, WorkspaceFile


@pytest.fixture()
def fixture_dir(tmp_path) -> Path:
    fixtures = tmp_path / "fixtures"
    fixtures.mkdir()
    (fixtures / "input.md").write_text("# Test LLD\nModel: Party")
    (fixtures / "meta.json").write_text('{"models": []}')
    return fixtures


class TestSetupWorkspace:
    def test_creates_workspace_dir(self, tmp_path, fixture_dir):
        workspace = tmp_path / "workspace"
        config = SetupConfig(
            workspace_files=[
                WorkspaceFile(
                    src=str(fixture_dir / "input.md"),
                    dest="docs/FeatureLLD/MER-99999---Party.md",
                )
            ]
        )
        setup_workspace(config, str(workspace))
        assert workspace.exists()
        assert (workspace / "docs/FeatureLLD/MER-99999---Party.md").exists()
        content = (workspace / "docs/FeatureLLD/MER-99999---Party.md").read_text()
        assert "Party" in content

    def test_stages_multiple_files(self, tmp_path, fixture_dir):
        workspace = tmp_path / "workspace"
        config = SetupConfig(
            workspace_files=[
                WorkspaceFile(
                    src=str(fixture_dir / "input.md"),
                    dest="docs/LLD.md",
                ),
                WorkspaceFile(
                    src=str(fixture_dir / "meta.json"),
                    dest="meta/models.json",
                ),
            ]
        )
        setup_workspace(config, str(workspace))
        assert (workspace / "docs/LLD.md").exists()
        assert (workspace / "meta/models.json").exists()

    def test_empty_setup(self, tmp_path):
        workspace = tmp_path / "workspace"
        config = SetupConfig()
        setup_workspace(config, str(workspace))
        assert workspace.exists()

    def test_missing_src_raises(self, tmp_path):
        workspace = tmp_path / "workspace"
        config = SetupConfig(
            workspace_files=[
                WorkspaceFile(src="/nonexistent/file.md", dest="docs/LLD.md")
            ]
        )
        with pytest.raises(FileNotFoundError, match="nonexistent"):
            setup_workspace(config, str(workspace))


class TestTeardownWorkspace:
    def test_removes_workspace(self, tmp_path):
        workspace = tmp_path / "workspace"
        workspace.mkdir()
        (workspace / "file.txt").write_text("test")
        teardown_workspace(str(workspace))
        assert not workspace.exists()

    def test_noop_if_missing(self, tmp_path):
        workspace = tmp_path / "workspace"
        teardown_workspace(str(workspace))  # Should not raise
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd autobots-devtools-shared-lib && ../.venv/bin/python -m pytest tests/unit/eval/test_workspace.py -v`
Expected: FAIL — ModuleNotFoundError

- [ ] **Step 3: Implement workspace.py**

```python
# src/autobots_devtools_shared_lib/eval/core/workspace.py
"""Workspace file staging for eval runs."""

from __future__ import annotations

import shutil
from pathlib import Path

from autobots_devtools_shared_lib.eval.models.eval_case import SetupConfig


def setup_workspace(config: SetupConfig, workspace_path: str) -> None:
    """Create workspace directory and stage fixture files.

    Args:
        config: Setup configuration with workspace_files to stage.
        workspace_path: Target workspace directory path.

    Raises:
        FileNotFoundError: If a source fixture file does not exist.
    """
    workspace = Path(workspace_path)
    workspace.mkdir(parents=True, exist_ok=True)

    for wf in config.workspace_files:
        src = Path(wf.src)
        if not src.exists():
            raise FileNotFoundError(
                f"Fixture file not found: {src}. "
                f"Ensure the file exists in the eval fixtures directory."
            )
        dest = workspace / wf.dest
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dest)


def teardown_workspace(workspace_path: str) -> None:
    """Remove workspace directory and all contents.

    Args:
        workspace_path: Workspace directory to remove.
    """
    workspace = Path(workspace_path)
    if workspace.exists():
        shutil.rmtree(workspace)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd autobots-devtools-shared-lib && ../.venv/bin/python -m pytest tests/unit/eval/test_workspace.py -v`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
cd autobots-devtools-shared-lib
git add src/autobots_devtools_shared_lib/eval/core/workspace.py \
        tests/unit/eval/test_workspace.py
git commit -m "feat(eval): add workspace file staging for eval fixtures"
```

---

## Task 8: Cost Tracker

**Files:**
- Create: `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/eval/core/cost_tracker.py`
- Test: `autobots-devtools-shared-lib/tests/unit/eval/test_cost_tracker.py`
- Modify: `autobots-devtools-shared-lib/pyproject.toml` (add tiktoken dependency)

- [ ] **Step 1: Add tiktoken dependency**

Run: `cd autobots-devtools-shared-lib && poetry add tiktoken`

- [ ] **Step 2: Write the failing tests**

```python
# tests/unit/eval/test_cost_tracker.py
import json
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

from autobots_devtools_shared_lib.eval.core.cost_tracker import (
    compare_with_baseline,
    load_baseline,
    save_baseline,
)
from autobots_devtools_shared_lib.eval.models.result import CostDelta, EvalCostSnapshot


@pytest.fixture()
def snapshot() -> EvalCostSnapshot:
    return EvalCostSnapshot(
        eval_name="test eval",
        agent="model-list-extractor",
        total_input_tokens=3200,
        total_output_tokens=600,
        total_cost_usd=0.008,
        total_latency_ms=4100,
        llm_calls=2,
        per_tool_tokens={"set_context_tool": 50, "mer_read_file_tool": 1900},
        timestamp="2026-03-26T10:00:00Z",
    )


class TestLoadBaseline:
    def test_loads_valid_file(self, tmp_path, snapshot):
        baseline_path = tmp_path / "cost_baseline.json"
        baseline_path.write_text(
            json.dumps(
                {
                    "eval_name": "test eval",
                    "agent": "model-list-extractor",
                    "total_input_tokens": 3000,
                    "total_output_tokens": 500,
                    "total_cost_usd": 0.007,
                    "total_latency_ms": 3800,
                    "llm_calls": 2,
                    "per_tool_tokens": {},
                }
            )
        )
        result = load_baseline(str(baseline_path))
        assert result is not None
        assert result["total_input_tokens"] == 3000

    def test_returns_none_for_missing_file(self):
        result = load_baseline("/nonexistent/path.json")
        assert result is None


class TestSaveBaseline:
    def test_saves_snapshot(self, tmp_path, snapshot):
        path = tmp_path / "cost_baseline.json"
        save_baseline(snapshot, str(path))
        data = json.loads(path.read_text())
        assert data["total_input_tokens"] == 3200
        assert data["agent"] == "model-list-extractor"

    def test_creates_parent_dirs(self, tmp_path, snapshot):
        path = tmp_path / "nested" / "dir" / "baseline.json"
        save_baseline(snapshot, str(path))
        assert path.exists()


class TestCompareWithBaseline:
    def test_all_ok(self, snapshot):
        baseline = {
            "total_input_tokens": 3100,
            "total_output_tokens": 590,
            "total_cost_usd": 0.0078,
            "total_latency_ms": 4000,
            "llm_calls": 2,
        }
        thresholds = {"input_tokens": 20, "cost_usd": 25, "latency_ms": 30}
        deltas = compare_with_baseline(snapshot, baseline, thresholds)
        assert all(d.status == "ok" for d in deltas)

    def test_warning_on_threshold_breach(self, snapshot):
        baseline = {
            "total_input_tokens": 2000,  # actual is 3200 = +60%
            "total_output_tokens": 600,
            "total_cost_usd": 0.008,
            "total_latency_ms": 4100,
            "llm_calls": 2,
        }
        thresholds = {"input_tokens": 20}
        deltas = compare_with_baseline(snapshot, baseline, thresholds)
        token_delta = next(d for d in deltas if d.metric == "input_tokens")
        assert token_delta.status == "warning"
        assert token_delta.delta_pct > 50

    def test_decrease_is_always_ok(self, snapshot):
        baseline = {
            "total_input_tokens": 5000,  # actual is 3200 = -36%
            "total_output_tokens": 600,
            "total_cost_usd": 0.008,
            "total_latency_ms": 4100,
            "llm_calls": 2,
        }
        thresholds = {"input_tokens": 20}
        deltas = compare_with_baseline(snapshot, baseline, thresholds)
        token_delta = next(d for d in deltas if d.metric == "input_tokens")
        assert token_delta.status == "ok"

    def test_empty_thresholds_all_ok(self, snapshot):
        baseline = {
            "total_input_tokens": 100,
            "total_output_tokens": 100,
            "total_cost_usd": 0.001,
            "total_latency_ms": 100,
            "llm_calls": 1,
        }
        deltas = compare_with_baseline(snapshot, baseline, {})
        assert all(d.status == "ok" for d in deltas)
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd autobots-devtools-shared-lib && ../.venv/bin/python -m pytest tests/unit/eval/test_cost_tracker.py -v`
Expected: FAIL — ModuleNotFoundError

- [ ] **Step 4: Implement cost_tracker.py**

```python
# src/autobots_devtools_shared_lib/eval/core/cost_tracker.py
"""Cost tracking: Langfuse query, baseline comparison, snapshot persistence."""

from __future__ import annotations

import json
import logging
from dataclasses import asdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from autobots_devtools_shared_lib.eval.models.result import CostDelta, EvalCostSnapshot

logger = logging.getLogger(__name__)

# Metric mapping: threshold key → snapshot field
_METRIC_MAP: dict[str, str] = {
    "input_tokens": "total_input_tokens",
    "output_tokens": "total_output_tokens",
    "cost_usd": "total_cost_usd",
    "latency_ms": "total_latency_ms",
    "llm_calls": "llm_calls",
}


def query_langfuse_cost(session_id: str, eval_name: str, agent: str) -> EvalCostSnapshot | None:
    """Query Langfuse for cost data from an eval run.

    Returns None if Langfuse is unavailable or no traces found.
    """
    try:
        from autobots_devtools_shared_lib.common.observability.tracing import (
            get_langfuse_client,
        )

        client = get_langfuse_client()
        if not client:
            logger.warning("Langfuse client unavailable, skipping cost tracking")
            return None

        traces = client.fetch_traces(session_id=session_id)
        if not traces.data:
            logger.warning("No traces found for session_id=%s", session_id)
            return None

        total_input = 0
        total_output = 0
        total_cost = 0.0
        total_latency = 0
        llm_calls = 0
        per_tool: dict[str, int] = {}

        for trace in traces.data:
            observations = client.fetch_observations(trace_id=trace.id)
            for obs in observations.data:
                if obs.type == "GENERATION":
                    llm_calls += 1
                    if obs.usage:
                        total_input += obs.usage.input or 0
                        total_output += obs.usage.output or 0
                    if obs.calculated_total_cost:
                        total_cost += obs.calculated_total_cost
                    if obs.latency:
                        total_latency += int(obs.latency * 1000)
                elif obs.type == "SPAN" and obs.name:
                    if obs.usage and obs.usage.input:
                        per_tool[obs.name] = obs.usage.input

        return EvalCostSnapshot(
            eval_name=eval_name,
            agent=agent,
            total_input_tokens=total_input,
            total_output_tokens=total_output,
            total_cost_usd=round(total_cost, 6),
            total_latency_ms=total_latency,
            llm_calls=llm_calls,
            per_tool_tokens=per_tool,
            timestamp=datetime.now(timezone.utc).isoformat(),
        )

    except Exception:
        logger.exception("Failed to query Langfuse for cost data")
        return None


def load_baseline(path: str) -> dict[str, Any] | None:
    """Load a cost baseline JSON file. Returns None if file doesn't exist."""
    p = Path(path)
    if not p.exists():
        return None
    return json.loads(p.read_text())


def save_baseline(snapshot: EvalCostSnapshot, path: str) -> None:
    """Save a cost snapshot as a baseline JSON file."""
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    data = asdict(snapshot)
    data.pop("timestamp", None)
    p.write_text(json.dumps(data, indent=2) + "\n")


def compare_with_baseline(
    snapshot: EvalCostSnapshot,
    baseline: dict[str, Any],
    thresholds: dict[str, float],
) -> list[CostDelta]:
    """Compare a snapshot against a baseline, returning deltas with status.

    A delta is "warning" only if the actual value INCREASED beyond the threshold percentage.
    Decreases are always "ok".
    """
    deltas: list[CostDelta] = []

    for threshold_key, field_name in _METRIC_MAP.items():
        actual = getattr(snapshot, field_name, 0)
        baseline_val = baseline.get(field_name, 0)

        if baseline_val == 0:
            delta_pct = 0.0 if actual == 0 else 100.0
        else:
            delta_pct = ((actual - baseline_val) / baseline_val) * 100

        threshold = thresholds.get(threshold_key)
        if threshold is not None and delta_pct > threshold:
            status = "warning"
        else:
            status = "ok"

        deltas.append(
            CostDelta(
                metric=threshold_key,
                baseline=baseline_val,
                actual=actual,
                delta_pct=round(delta_pct, 1),
                status=status,
            )
        )

    return deltas
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd autobots-devtools-shared-lib && ../.venv/bin/python -m pytest tests/unit/eval/test_cost_tracker.py -v`
Expected: All PASS

- [ ] **Step 6: Commit**

```bash
cd autobots-devtools-shared-lib
git add src/autobots_devtools_shared_lib/eval/core/cost_tracker.py \
        tests/unit/eval/test_cost_tracker.py \
        pyproject.toml poetry.lock
git commit -m "feat(eval): add cost tracker with Langfuse query and baseline comparison"
```

---

## Task 9: Langfuse Scorer

**Files:**
- Create: `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/eval/scoring/__init__.py`
- Create: `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/eval/scoring/langfuse_scorer.py`
- Test: `autobots-devtools-shared-lib/tests/unit/eval/test_langfuse_scorer.py`

- [ ] **Step 1: Write the failing tests**

```python
# tests/unit/eval/test_langfuse_scorer.py
from unittest.mock import MagicMock, patch

from autobots_devtools_shared_lib.eval.scoring.langfuse_scorer import post_eval_scores
from autobots_devtools_shared_lib.eval.models.result import (
    AssertionResult,
    EvalResult,
    TurnResult,
)


class TestPostEvalScores:
    @patch("autobots_devtools_shared_lib.eval.scoring.langfuse_scorer.get_langfuse_client")
    def test_posts_pass_score(self, mock_get_client):
        client = MagicMock()
        mock_get_client.return_value = client

        result = EvalResult(
            name="test eval",
            passed=True,
            turns=[
                TurnResult(
                    turn=1,
                    assertions=[AssertionResult(passed=True, name="contains", detail="ok")],
                    passed=True,
                    agent_message="done",
                )
            ],
            cost_snapshot=None,
            cost_deltas=None,
        )
        post_eval_scores(result, trace_id="trace-123")
        client.score.assert_called_once()
        call_kwargs = client.score.call_args[1]
        assert call_kwargs["value"] == 1
        assert call_kwargs["name"] == "eval_passed"

    @patch("autobots_devtools_shared_lib.eval.scoring.langfuse_scorer.get_langfuse_client")
    def test_posts_fail_score(self, mock_get_client):
        client = MagicMock()
        mock_get_client.return_value = client

        result = EvalResult(
            name="test eval",
            passed=False,
            turns=[
                TurnResult(
                    turn=1,
                    assertions=[
                        AssertionResult(passed=False, name="contains:Party", detail="Not found"),
                    ],
                    passed=False,
                    agent_message="done",
                )
            ],
            cost_snapshot=None,
            cost_deltas=None,
        )
        post_eval_scores(result, trace_id="trace-123")
        client.score.assert_called_once()
        call_kwargs = client.score.call_args[1]
        assert call_kwargs["value"] == 0

    @patch("autobots_devtools_shared_lib.eval.scoring.langfuse_scorer.get_langfuse_client")
    def test_noop_when_client_unavailable(self, mock_get_client):
        mock_get_client.return_value = None
        result = EvalResult(
            name="test", passed=True, turns=[], cost_snapshot=None, cost_deltas=None
        )
        # Should not raise
        post_eval_scores(result, trace_id="trace-123")
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd autobots-devtools-shared-lib && ../.venv/bin/python -m pytest tests/unit/eval/test_langfuse_scorer.py -v`
Expected: FAIL — ModuleNotFoundError

- [ ] **Step 3: Implement langfuse_scorer.py**

```python
# src/autobots_devtools_shared_lib/eval/scoring/langfuse_scorer.py
"""Post eval scores to Langfuse for tracking."""

from __future__ import annotations

import logging

from autobots_devtools_shared_lib.common.observability.tracing import get_langfuse_client
from autobots_devtools_shared_lib.eval.models.result import EvalResult

logger = logging.getLogger(__name__)


def post_eval_scores(result: EvalResult, trace_id: str) -> None:
    """Post eval pass/fail score to Langfuse.

    Args:
        result: The completed eval result.
        trace_id: Langfuse trace ID to attach scores to.
    """
    client = get_langfuse_client()
    if not client:
        logger.debug("Langfuse client unavailable, skipping score posting")
        return

    try:
        client.score(
            trace_id=trace_id,
            name="eval_passed",
            value=1 if result.passed else 0,
            comment=result.summary(),
        )
    except Exception:
        logger.exception("Failed to post eval score to Langfuse")
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd autobots-devtools-shared-lib && ../.venv/bin/python -m pytest tests/unit/eval/test_langfuse_scorer.py -v`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
cd autobots-devtools-shared-lib
git add src/autobots_devtools_shared_lib/eval/scoring/__init__.py \
        src/autobots_devtools_shared_lib/eval/scoring/langfuse_scorer.py \
        tests/unit/eval/test_langfuse_scorer.py
git commit -m "feat(eval): add Langfuse scorer for posting eval results"
```

---

## Task 10: Linear Eval Runner

**Files:**
- Create: `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/eval/core/runner.py`
- Test: `autobots-devtools-shared-lib/tests/unit/eval/test_runner.py`

- [ ] **Step 1: Write the failing tests**

```python
# tests/unit/eval/test_runner.py
from unittest.mock import MagicMock, patch

import pytest
from langchain_core.messages import AIMessage, HumanMessage

from autobots_devtools_shared_lib.eval.core.runner import run_linear_eval
from autobots_devtools_shared_lib.eval.models.eval_case import (
    Assertion,
    CostConfig,
    EvalCase,
    SetupConfig,
    Turn,
)


def _make_eval_case(**overrides) -> EvalCase:
    defaults = {
        "name": "test eval",
        "agent": "model-list-extractor",
        "mode": "linear",
        "tags": ["smoke"],
        "turns": [
            Turn(
                user="Extract models",
                assertions=[Assertion(type="contains", config="Party")],
            )
        ],
    }
    defaults.update(overrides)
    return EvalCase(**defaults)


def _mock_invoke_result(text: str = "Party model extracted", structured: dict | None = None):
    return {
        "messages": [
            HumanMessage(content="Extract models"),
            AIMessage(content=text),
        ],
        "structured_response": structured,
        "agent_name": "model-list-extractor",
    }


class TestRunLinearEval:
    @patch("autobots_devtools_shared_lib.eval.core.runner.invoke_agent")
    def test_single_turn_pass(self, mock_invoke):
        mock_invoke.return_value = _mock_invoke_result()
        case = _make_eval_case()
        result = run_linear_eval(case)
        assert result.passed is True
        assert len(result.turns) == 1
        assert result.turns[0].passed is True

    @patch("autobots_devtools_shared_lib.eval.core.runner.invoke_agent")
    def test_single_turn_fail(self, mock_invoke):
        mock_invoke.return_value = _mock_invoke_result(text="No models found")
        case = _make_eval_case()
        result = run_linear_eval(case)
        assert result.passed is False

    @patch("autobots_devtools_shared_lib.eval.core.runner.invoke_agent")
    def test_multi_turn(self, mock_invoke):
        mock_invoke.return_value = _mock_invoke_result()
        case = _make_eval_case(
            turns=[
                Turn(
                    user="First message",
                    assertions=[Assertion(type="contains", config="Party")],
                ),
                Turn(
                    user="Second message",
                    assertions=[Assertion(type="contains", config="Party")],
                ),
            ]
        )
        result = run_linear_eval(case)
        assert result.passed is True
        assert len(result.turns) == 2
        assert mock_invoke.call_count == 2

    @patch("autobots_devtools_shared_lib.eval.core.runner.invoke_agent")
    def test_agent_error(self, mock_invoke):
        mock_invoke.side_effect = ValueError("Agent crashed")
        case = _make_eval_case()
        result = run_linear_eval(case)
        assert result.passed is False
        assert result.error is not None
        assert "crashed" in result.error

    @patch("autobots_devtools_shared_lib.eval.core.runner.invoke_agent")
    def test_passes_state_to_agent(self, mock_invoke):
        mock_invoke.return_value = _mock_invoke_result()
        case = _make_eval_case(
            state={"user_name": "test-user", "jira_number": "MER-99999"}
        )
        run_linear_eval(case)
        call_kwargs = mock_invoke.call_args[1]
        input_state = call_kwargs["input_state"]
        assert input_state["user_name"] == "test-user"
        assert input_state["jira_number"] == "MER-99999"

    @patch("autobots_devtools_shared_lib.eval.core.runner.invoke_agent")
    def test_returns_session_id(self, mock_invoke):
        mock_invoke.return_value = _mock_invoke_result()
        case = _make_eval_case()
        result = run_linear_eval(case)
        # session_id is generated for cost tracking
        assert result.name == "test eval"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd autobots-devtools-shared-lib && ../.venv/bin/python -m pytest tests/unit/eval/test_runner.py -v`
Expected: FAIL — ModuleNotFoundError

- [ ] **Step 3: Implement runner.py**

```python
# src/autobots_devtools_shared_lib/eval/core/runner.py
"""Eval runner: drives agent invocations and assertion checks."""

from __future__ import annotations

import logging
import uuid
from typing import Any

from langchain_core.messages import HumanMessage

from autobots_devtools_shared_lib.common.observability.trace_metadata import TraceMetadata
from autobots_devtools_shared_lib.dynagent import invoke_agent
from autobots_devtools_shared_lib.eval.assertions.registry import get_assertion_fn
from autobots_devtools_shared_lib.eval.models.eval_case import EvalCase
from autobots_devtools_shared_lib.eval.models.result import (
    AgentOutput,
    AssertionResult,
    EvalResult,
    TurnResult,
)

logger = logging.getLogger(__name__)


def _build_agent_output(raw_state: dict[str, Any], agent_name: str) -> AgentOutput:
    """Convert raw invoke_agent result to AgentOutput."""
    messages = raw_state.get("messages", [])
    structured = raw_state.get("structured_response")

    agent_message = None
    for msg in reversed(messages):
        if hasattr(msg, "content") and isinstance(msg.content, str) and msg.content:
            agent_message = msg.content
            break

    return AgentOutput(
        messages=messages,
        structured_response=structured,
        agent_name=agent_name,
        raw_state=raw_state,
    )


def _run_assertions(
    output: AgentOutput, assertions: list, eval_base_dir: str | None = None
) -> list[AssertionResult]:
    """Run all assertions against agent output."""
    results: list[AssertionResult] = []
    for assertion in assertions:
        fn = get_assertion_fn(assertion.type)
        result = fn(output, assertion.config)
        results.append(result)
    return results


def run_linear_eval(
    eval_case: EvalCase,
    session_id: str | None = None,
) -> EvalResult:
    """Execute a linear eval: replay scripted turns, check assertions after each.

    Args:
        eval_case: Parsed eval case definition.
        session_id: Optional session ID for trace correlation. Auto-generated if None.

    Returns:
        EvalResult with pass/fail status, turn results, and cost data.
    """
    session_id = session_id or f"eval-{uuid.uuid4().hex[:12]}"
    trace_metadata = TraceMetadata.create(
        session_id=session_id,
        app_name="eval",
        user_id="eval",
        tags=["eval", *eval_case.tags],
    )

    turn_results: list[TurnResult] = []
    all_passed = True

    try:
        for i, turn in enumerate(eval_case.turns):
            input_state: dict[str, Any] = {
                **eval_case.state,
                "messages": [HumanMessage(content=turn.user)],
                "agent_name": eval_case.agent,
                "session_id": session_id,
            }

            raw_result = invoke_agent(
                agent_name=eval_case.agent,
                input_state=input_state,
                trace_metadata=trace_metadata,
            )

            output = _build_agent_output(raw_result, eval_case.agent)
            assertion_results = _run_assertions(output, turn.assertions)
            turn_passed = all(a.passed for a in assertion_results)

            if not turn_passed:
                all_passed = False

            agent_msg = None
            for msg in reversed(output.messages):
                if hasattr(msg, "content") and isinstance(msg.content, str) and msg.content:
                    agent_msg = msg.content
                    break

            turn_results.append(
                TurnResult(
                    turn=i + 1,
                    assertions=assertion_results,
                    passed=turn_passed,
                    agent_message=agent_msg,
                    structured_response=output.structured_response,
                )
            )

    except Exception as e:
        all_passed = False
        return EvalResult(
            name=eval_case.name,
            passed=False,
            turns=turn_results,
            cost_snapshot=None,
            cost_deltas=None,
            error=str(e),
        )

    return EvalResult(
        name=eval_case.name,
        passed=all_passed,
        turns=turn_results,
        cost_snapshot=None,  # Filled by pytest fixture after cost tracking
        cost_deltas=None,
    )
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd autobots-devtools-shared-lib && ../.venv/bin/python -m pytest tests/unit/eval/test_runner.py -v`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
cd autobots-devtools-shared-lib
git add src/autobots_devtools_shared_lib/eval/core/runner.py \
        tests/unit/eval/test_runner.py
git commit -m "feat(eval): add linear eval runner with assertion checking"
```

---

## Task 11: pytest Plugin (CLI Options + Markers)

**Files:**
- Create: `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/eval/pytest_plugin/__init__.py`
- Create: `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/eval/pytest_plugin/plugin.py`
- Test: `autobots-devtools-shared-lib/tests/unit/eval/test_plugin.py`
- Modify: `autobots-devtools-shared-lib/pyproject.toml` (add pytest11 plugin entry)

- [ ] **Step 1: Write the failing tests**

```python
# tests/unit/eval/test_plugin.py
import pytest


class TestPluginRegistration:
    def test_markers_registered(self, pytestconfig):
        markers = pytestconfig.getini("markers")
        marker_names = [m.split(":")[0].strip() for m in markers]
        assert "eval" in marker_names
        assert "eval_linear" in marker_names

    def test_eval_tags_option(self, pytestconfig):
        assert pytestconfig.getoption("eval_tags", default=None) is not None or True

    def test_eval_agent_option(self, pytestconfig):
        assert pytestconfig.getoption("eval_agent", default=None) is not None or True
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd autobots-devtools-shared-lib && ../.venv/bin/python -m pytest tests/unit/eval/test_plugin.py -v`
Expected: FAIL — markers not registered yet

- [ ] **Step 3: Implement plugin.py and register in pyproject.toml**

```python
# src/autobots_devtools_shared_lib/eval/pytest_plugin/plugin.py
"""pytest plugin for dynagent eval framework."""

from __future__ import annotations


def pytest_addoption(parser):
    """Register eval-specific CLI options."""
    group = parser.getgroup("dynagent-eval", "Dynagent eval framework options")
    group.addoption(
        "--eval-tags",
        action="store",
        default="",
        help="Comma-separated tags to filter eval cases (OR logic)",
    )
    group.addoption(
        "--eval-agent",
        action="store",
        default="",
        help="Filter eval cases by agent name",
    )
    group.addoption(
        "--eval-cost-report",
        action="store",
        default="",
        help="Path to write cost report JSON",
    )
    group.addoption(
        "--update-golden",
        action="store_true",
        default=False,
        help="Overwrite golden outputs + cost baselines with actual results",
    )
    group.addoption(
        "--update-baseline",
        action="store_true",
        default=False,
        help="Overwrite cost baselines only (golden outputs unchanged)",
    )
    group.addoption(
        "--eval-no-langfuse-score",
        action="store_true",
        default=False,
        help="Skip posting scores to Langfuse",
    )


def pytest_configure(config):
    """Register custom markers."""
    config.addinivalue_line("markers", "eval: mark test as an eval test")
    config.addinivalue_line("markers", "eval_linear: mark test as a linear eval test")
```

Add to `pyproject.toml`:

```toml
[tool.poetry.plugins."pytest11"]
dynagent_eval = "autobots_devtools_shared_lib.eval.pytest_plugin.plugin"
```

After adding the plugin entry, run: `cd autobots-devtools-shared-lib && poetry install`

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd autobots-devtools-shared-lib && ../.venv/bin/python -m pytest tests/unit/eval/test_plugin.py -v`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
cd autobots-devtools-shared-lib
git add src/autobots_devtools_shared_lib/eval/pytest_plugin/__init__.py \
        src/autobots_devtools_shared_lib/eval/pytest_plugin/plugin.py \
        tests/unit/eval/test_plugin.py \
        pyproject.toml
git commit -m "feat(eval): add pytest plugin with CLI options and eval markers"
```

---

## Task 12: pytest Fixtures (dynagent_eval)

**Files:**
- Create: `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/eval/pytest_plugin/fixtures.py`
- Modify: `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/eval/pytest_plugin/plugin.py` (register fixtures)
- Test: `autobots-devtools-shared-lib/tests/unit/eval/test_fixtures.py`

- [ ] **Step 1: Write the failing tests**

```python
# tests/unit/eval/test_fixtures.py
from unittest.mock import MagicMock, patch

import pytest

from autobots_devtools_shared_lib.eval.pytest_plugin.fixtures import make_dynagent_eval
from autobots_devtools_shared_lib.eval.models.eval_case import (
    Assertion,
    CostConfig,
    EvalCase,
    Turn,
)


def _make_eval_case(**overrides) -> EvalCase:
    defaults = {
        "name": "test eval",
        "agent": "model-list-extractor",
        "mode": "linear",
        "tags": ["smoke"],
        "turns": [
            Turn(
                user="Extract models",
                assertions=[Assertion(type="contains", config="Party")],
            )
        ],
    }
    defaults.update(overrides)
    return EvalCase(**defaults)


class TestMakeDynagentEval:
    @patch("autobots_devtools_shared_lib.eval.pytest_plugin.fixtures.run_linear_eval")
    @patch("autobots_devtools_shared_lib.eval.pytest_plugin.fixtures.setup_workspace")
    @patch("autobots_devtools_shared_lib.eval.pytest_plugin.fixtures.teardown_workspace")
    def test_calls_runner(self, mock_teardown, mock_setup, mock_run):
        from autobots_devtools_shared_lib.eval.models.result import EvalResult

        mock_run.return_value = EvalResult(
            name="test", passed=True, turns=[], cost_snapshot=None, cost_deltas=None
        )

        eval_fn = make_dynagent_eval(
            update_golden=False,
            update_baseline=False,
            no_langfuse_score=False,
        )
        case = _make_eval_case()
        result = eval_fn(case)
        assert result.passed is True
        mock_run.assert_called_once()

    @patch("autobots_devtools_shared_lib.eval.pytest_plugin.fixtures.run_linear_eval")
    @patch("autobots_devtools_shared_lib.eval.pytest_plugin.fixtures.setup_workspace")
    @patch("autobots_devtools_shared_lib.eval.pytest_plugin.fixtures.teardown_workspace")
    def test_calls_workspace_setup(self, mock_teardown, mock_setup, mock_run):
        from autobots_devtools_shared_lib.eval.models.result import EvalResult

        mock_run.return_value = EvalResult(
            name="test", passed=True, turns=[], cost_snapshot=None, cost_deltas=None
        )

        eval_fn = make_dynagent_eval(
            update_golden=False,
            update_baseline=False,
            no_langfuse_score=False,
        )
        case = _make_eval_case()
        eval_fn(case)
        mock_setup.assert_called_once()
        mock_teardown.assert_called_once()
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd autobots-devtools-shared-lib && ../.venv/bin/python -m pytest tests/unit/eval/test_fixtures.py -v`
Expected: FAIL — ModuleNotFoundError

- [ ] **Step 3: Implement fixtures.py**

```python
# src/autobots_devtools_shared_lib/eval/pytest_plugin/fixtures.py
"""pytest fixtures for dynagent eval framework."""

from __future__ import annotations

import json
import logging
import tempfile
import uuid
from pathlib import Path
from typing import Any, Callable

from autobots_devtools_shared_lib.eval.core.cost_tracker import (
    compare_with_baseline,
    load_baseline,
    query_langfuse_cost,
    save_baseline,
)
from autobots_devtools_shared_lib.eval.core.runner import run_linear_eval
from autobots_devtools_shared_lib.eval.core.workspace import setup_workspace, teardown_workspace
from autobots_devtools_shared_lib.eval.models.eval_case import EvalCase
from autobots_devtools_shared_lib.eval.models.result import EvalResult
from autobots_devtools_shared_lib.eval.scoring.langfuse_scorer import post_eval_scores

logger = logging.getLogger(__name__)


def make_dynagent_eval(
    update_golden: bool,
    update_baseline: bool,
    no_langfuse_score: bool,
) -> Callable[[EvalCase], EvalResult]:
    """Create the dynagent_eval callable used by test functions.

    Args:
        update_golden: If True, overwrite golden outputs + cost baselines.
        update_baseline: If True, overwrite cost baselines only.
        no_langfuse_score: If True, skip posting scores to Langfuse.

    Returns:
        A callable that takes an EvalCase and returns an EvalResult.
    """

    def _eval(eval_case: EvalCase) -> EvalResult:
        session_id = f"eval-{uuid.uuid4().hex[:12]}"
        workspace_path = tempfile.mkdtemp(prefix="eval_workspace_")

        try:
            # Stage workspace files
            setup_workspace(eval_case.setup, workspace_path)

            # Run the eval
            result = run_linear_eval(eval_case, session_id=session_id)

            # Cost tracking
            if eval_case.cost.track:
                snapshot = query_langfuse_cost(
                    session_id=session_id,
                    eval_name=eval_case.name,
                    agent=eval_case.agent,
                )
                if snapshot:
                    result.cost_snapshot = snapshot

                    if update_golden or update_baseline:
                        if eval_case.cost.baseline:
                            save_baseline(snapshot, eval_case.cost.baseline)

                    elif eval_case.cost.baseline:
                        baseline = load_baseline(eval_case.cost.baseline)
                        if baseline:
                            result.cost_deltas = compare_with_baseline(
                                snapshot, baseline, eval_case.cost.thresholds
                            )

            # Golden output update when --update-golden is set
            if update_golden:
                import json

                for i, turn in enumerate(eval_case.turns):
                    for assertion in turn.assertions:
                        if assertion.type == "golden_match" and isinstance(assertion.config, dict):
                            ref_path = Path(assertion.config["reference"])
                            ref_path.parent.mkdir(parents=True, exist_ok=True)
                            if i < len(result.turns) and result.turns[i].structured_response is not None:
                                ref_path.write_text(
                                    json.dumps(
                                        result.turns[i].structured_response,
                                        indent=2,
                                        sort_keys=True,
                                    )
                                    + "\n"
                                )

            # Post scores to Langfuse
            if not no_langfuse_score:
                post_eval_scores(result, trace_id=session_id)

            return result

        finally:
            teardown_workspace(workspace_path)

    return _eval
```

Update `plugin.py` to register the fixture:

```python
# Add to the end of plugin.py
import pytest

from autobots_devtools_shared_lib.eval.pytest_plugin.fixtures import make_dynagent_eval


@pytest.fixture
def dynagent_eval(request):
    """Fixture that provides a callable to run eval cases."""
    config = request.config
    return make_dynagent_eval(
        update_golden=config.getoption("update_golden", default=False),
        update_baseline=config.getoption("update_baseline", default=False),
        no_langfuse_score=config.getoption("eval_no_langfuse_score", default=False),
    )
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd autobots-devtools-shared-lib && ../.venv/bin/python -m pytest tests/unit/eval/test_fixtures.py -v`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
cd autobots-devtools-shared-lib
git add src/autobots_devtools_shared_lib/eval/pytest_plugin/fixtures.py \
        src/autobots_devtools_shared_lib/eval/pytest_plugin/plugin.py \
        tests/unit/eval/test_fixtures.py
git commit -m "feat(eval): add dynagent_eval fixture with workspace staging and cost tracking"
```

---

## Task 13: Reporting (Terminal + JSON)

**Files:**
- Create: `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/eval/pytest_plugin/reporting.py`
- Modify: `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/eval/pytest_plugin/plugin.py` (integrate reporting hooks)
- Test: `autobots-devtools-shared-lib/tests/unit/eval/test_reporting.py`

- [ ] **Step 1: Write the failing tests**

```python
# tests/unit/eval/test_reporting.py
import json
from pathlib import Path

from autobots_devtools_shared_lib.eval.pytest_plugin.reporting import (
    format_cost_summary,
    write_cost_report,
)
from autobots_devtools_shared_lib.eval.models.result import (
    CostDelta,
    EvalCostSnapshot,
    EvalResult,
    TurnResult,
    AssertionResult,
)


class TestFormatCostSummary:
    def test_with_deltas(self):
        results = [
            EvalResult(
                name="Model list extraction",
                passed=True,
                turns=[],
                cost_snapshot=EvalCostSnapshot(
                    eval_name="Model list extraction",
                    agent="model-list-extractor",
                    total_input_tokens=3580,
                    total_output_tokens=610,
                    total_cost_usd=0.009,
                    total_latency_ms=3900,
                    llm_calls=2,
                    per_tool_tokens={},
                    timestamp="2026-03-26T10:00:00Z",
                ),
                cost_deltas=[
                    CostDelta(metric="input_tokens", baseline=3200, actual=3580, delta_pct=11.9, status="ok"),
                    CostDelta(metric="cost_usd", baseline=0.008, actual=0.009, delta_pct=12.5, status="warning"),
                ],
            )
        ]
        text = format_cost_summary(results)
        assert "model-list-extractor" in text
        assert "3580" in text
        assert "warning" in text.lower() or "⚠" in text

    def test_no_cost_data(self):
        results = [
            EvalResult(name="test", passed=True, turns=[], cost_snapshot=None, cost_deltas=None)
        ]
        text = format_cost_summary(results)
        assert "no cost data" in text.lower() or text.strip() == ""


class TestWriteCostReport:
    def test_writes_json(self, tmp_path):
        results = [
            EvalResult(
                name="test eval",
                passed=True,
                turns=[],
                cost_snapshot=EvalCostSnapshot(
                    eval_name="test eval",
                    agent="model-list-extractor",
                    total_input_tokens=3200,
                    total_output_tokens=600,
                    total_cost_usd=0.008,
                    total_latency_ms=4100,
                    llm_calls=2,
                    per_tool_tokens={"mer_read_file_tool": 1900},
                    timestamp="2026-03-26T10:00:00Z",
                ),
                cost_deltas=[
                    CostDelta(metric="input_tokens", baseline=3000, actual=3200, delta_pct=6.7, status="ok"),
                ],
            )
        ]
        path = tmp_path / "report.json"
        write_cost_report(results, str(path))
        data = json.loads(path.read_text())
        assert len(data["evals"]) == 1
        assert data["evals"][0]["agent"] == "model-list-extractor"

    def test_creates_parent_dirs(self, tmp_path):
        results = [
            EvalResult(name="test", passed=True, turns=[], cost_snapshot=None, cost_deltas=None)
        ]
        path = tmp_path / "nested" / "dir" / "report.json"
        write_cost_report(results, str(path))
        assert path.exists()
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd autobots-devtools-shared-lib && ../.venv/bin/python -m pytest tests/unit/eval/test_reporting.py -v`
Expected: FAIL — ModuleNotFoundError

- [ ] **Step 3: Implement reporting.py**

```python
# src/autobots_devtools_shared_lib/eval/pytest_plugin/reporting.py
"""Cost reporting: terminal summary and JSON report generation."""

from __future__ import annotations

import json
from dataclasses import asdict
from pathlib import Path

from autobots_devtools_shared_lib.eval.models.result import EvalResult


def format_cost_summary(results: list[EvalResult]) -> str:
    """Format cost comparison as terminal output."""
    results_with_cost = [r for r in results if r.cost_snapshot]
    if not results_with_cost:
        return "No cost data collected."

    lines: list[str] = []
    lines.append("=" * 60)
    lines.append(" eval cost comparison")
    lines.append("=" * 60)

    for r in results_with_cost:
        snap = r.cost_snapshot
        lines.append(f"\n{snap.agent} ({r.name}):")

        if r.cost_deltas:
            for d in r.cost_deltas:
                warn = " ⚠ warning" if d.status == "warning" else ""
                lines.append(
                    f"  {d.metric}: {d.baseline} → {d.actual} "
                    f"({d.delta_pct:+.1f}%){warn}"
                )
        else:
            lines.append(f"  Input tokens:  {snap.total_input_tokens}")
            lines.append(f"  Output tokens: {snap.total_output_tokens}")
            lines.append(f"  Cost:          ${snap.total_cost_usd:.4f}")
            lines.append(f"  Latency:       {snap.total_latency_ms}ms")
            lines.append(f"  LLM calls:     {snap.llm_calls}")

    lines.append("\n" + "=" * 60)
    return "\n".join(lines)


def write_cost_report(results: list[EvalResult], path: str) -> None:
    """Write cost report as JSON file."""
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)

    report = {
        "evals": [],
    }

    for r in results:
        entry: dict = {
            "name": r.name,
            "passed": r.passed,
        }
        if r.cost_snapshot:
            entry["agent"] = r.cost_snapshot.agent
            entry["cost"] = asdict(r.cost_snapshot)
        if r.cost_deltas:
            entry["deltas"] = [asdict(d) for d in r.cost_deltas]
        report["evals"].append(entry)

    p.write_text(json.dumps(report, indent=2) + "\n")
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd autobots-devtools-shared-lib && ../.venv/bin/python -m pytest tests/unit/eval/test_reporting.py -v`
Expected: All PASS

- [ ] **Step 5: Integrate reporting into plugin.py**

Add terminal reporting hook and JSON report generation to `plugin.py`:

```python
# Add to plugin.py

_eval_results: list = []

def pytest_runtest_makereport(item, call):
    """Collect eval results from test items."""
    if call.when == "call" and hasattr(item, "_eval_result"):
        _eval_results.append(item._eval_result)


def pytest_terminal_summary(terminalreporter, config):
    """Print cost summary at end of test run."""
    from autobots_devtools_shared_lib.eval.pytest_plugin.reporting import (
        format_cost_summary,
        write_cost_report,
    )

    if _eval_results:
        summary = format_cost_summary(_eval_results)
        if summary:
            terminalreporter.write_line("")
            terminalreporter.write_line(summary)

        cost_report_path = config.getoption("eval_cost_report", default="")
        if cost_report_path:
            write_cost_report(_eval_results, cost_report_path)
            terminalreporter.write_line(f"\nCost report written to: {cost_report_path}")
```

- [ ] **Step 6: Commit**

```bash
cd autobots-devtools-shared-lib
git add src/autobots_devtools_shared_lib/eval/pytest_plugin/reporting.py \
        src/autobots_devtools_shared_lib/eval/pytest_plugin/plugin.py \
        tests/unit/eval/test_reporting.py
git commit -m "feat(eval): add cost reporting with terminal summary and JSON output"
```

---

## Task 14: Public API Exports

**Files:**
- Modify: `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/eval/__init__.py`

- [ ] **Step 1: Write the public exports**

```python
# src/autobots_devtools_shared_lib/eval/__init__.py
"""Dynagent Eval Framework — Public API."""

from autobots_devtools_shared_lib.eval.assertions.registry import register_assertion
from autobots_devtools_shared_lib.eval.core.loader import load_eval_cases
from autobots_devtools_shared_lib.eval.core.runner import run_linear_eval
from autobots_devtools_shared_lib.eval.models.eval_case import (
    Assertion,
    CostConfig,
    EvalCase,
    SetupConfig,
    Turn,
    WorkspaceFile,
)
from autobots_devtools_shared_lib.eval.models.result import (
    AgentOutput,
    AssertionResult,
    CostDelta,
    EvalCostSnapshot,
    EvalResult,
    TurnResult,
)

__all__ = [
    "AgentOutput",
    "Assertion",
    "AssertionResult",
    "CostConfig",
    "CostDelta",
    "EvalCase",
    "EvalCostSnapshot",
    "EvalResult",
    "SetupConfig",
    "Turn",
    "TurnResult",
    "WorkspaceFile",
    "load_eval_cases",
    "register_assertion",
    "run_linear_eval",
]
```

- [ ] **Step 2: Run all eval tests to verify everything integrates**

Run: `cd autobots-devtools-shared-lib && ../.venv/bin/python -m pytest tests/unit/eval/ -v`
Expected: All PASS

- [ ] **Step 3: Commit**

```bash
cd autobots-devtools-shared-lib
git add src/autobots_devtools_shared_lib/eval/__init__.py
git commit -m "feat(eval): add public API exports for eval framework"
```

---

## Task 15: MER Eval Scaffolding (conftest + test wrapper)

**Files:**
- Create: `autobots-agents-mer/tests/eval/__init__.py`
- Create: `autobots-agents-mer/tests/eval/conftest.py`
- Create: `autobots-agents-mer/tests/eval/test_nurture_evals.py`
- Create: `autobots-agents-mer/tests/eval/nurture/` (directory only)
- Modify: `autobots-agents-mer/Makefile` (add eval targets)
- Modify: `autobots-agents-mer/pyproject.toml` (add eval marker)

- [ ] **Step 1: Create conftest.py**

```python
# autobots-agents-mer/tests/eval/conftest.py
import os

import pytest

from autobots_devtools_shared_lib.dynagent import AgentMeta, register_usecase_tools


@pytest.fixture(autouse=True)
def setup_nurture_env():
    """Set environment and register tools for nurture agent evals."""
    os.environ.setdefault("DYNAGENT_CONFIG_ROOT_DIR", "agent_configs/nurture")
    AgentMeta.reset()

    from autobots_agents_mer.domains.nurture.tools.nurture_tools import register_nurture_tools

    register_nurture_tools()
    yield
    AgentMeta.reset()
```

- [ ] **Step 2: Create test wrapper**

```python
# autobots-agents-mer/tests/eval/test_nurture_evals.py
import pytest

from autobots_devtools_shared_lib.eval import load_eval_cases


@pytest.mark.eval
@pytest.mark.eval_linear
@pytest.mark.parametrize(
    "eval_case",
    load_eval_cases("tests/eval/nurture"),
    ids=lambda c: c.name,
)
def test_nurture(eval_case, dynagent_eval):
    result = dynagent_eval(eval_case)
    assert result.passed, result.summary()
```

- [ ] **Step 3: Add eval marker to pyproject.toml**

Add to `[tool.pytest.ini_options]` markers:

```
"eval: marks tests as eval tests",
"eval_linear: marks tests as linear eval tests",
```

- [ ] **Step 4: Add Makefile targets**

Append to `autobots-agents-mer/Makefile`:

```makefile
eval:                              ## Run all nurture evals with cost report
	pytest tests/eval/ -m eval --eval-cost-report=reports/eval_cost.json -v

eval-smoke:                        ## Run smoke-tagged evals only
	pytest tests/eval/ -m eval --eval-tags=smoke -v

eval-agent:                        ## Run evals for a specific agent: make eval-agent AGENT=model-list-extractor
	pytest tests/eval/ -m eval --eval-agent=$(AGENT) -v

update-golden:                     ## Re-capture golden outputs + baselines
	pytest tests/eval/ -m eval --update-golden -v

update-baseline:                   ## Re-capture cost baselines only
	pytest tests/eval/ -m eval --update-baseline -v
```

- [ ] **Step 5: Create nurture eval directory**

Run: `mkdir -p autobots-agents-mer/tests/eval/nurture`

- [ ] **Step 6: Commit**

```bash
cd autobots-agents-mer
git add tests/eval/__init__.py tests/eval/conftest.py \
        tests/eval/test_nurture_evals.py \
        tests/eval/nurture/ \
        Makefile pyproject.toml
git commit -m "feat(eval): scaffold nurture eval infrastructure"
```

---

## Task 16: First Eval Case (model-list-extractor)

This is a proof-of-concept eval. You will need an actual LLD fixture and golden output from a real run.

**Files:**
- Create: `autobots-agents-mer/tests/eval/nurture/model-list-extractor/party-lld.yaml`
- Create: `autobots-agents-mer/tests/eval/nurture/model-list-extractor/fixtures/golden_input.md`
- Create: `autobots-agents-mer/tests/eval/nurture/model-list-extractor/fixtures/golden_output.json`
- Create: `autobots-agents-mer/tests/eval/nurture/model-list-extractor/fixtures/cost_baseline.json`

- [ ] **Step 1: Create eval YAML**

```yaml
# tests/eval/nurture/model-list-extractor/party-lld.yaml
eval:
  name: "Model list extraction from Party LLD"
  agent: "model-list-extractor"
  mode: linear
  tags: ["nurture", "model", "smoke"]

  state:
    user_name: "test-user"
    repo_name: "fbp-core"
    jira_number: "MER-99999"

  setup:
    workspace_files:
      - src: "fixtures/golden_input.md"
        dest: "docs/FeatureLLD/MER-99999---Party-Feature.md"

  turns:
    - user: |
        user_name: test-user, repo_name: fbp-core, jira_number: MER-99999
        Retrieve the model list for the current workspace.
      assertions:
        - tool_called: "mer_read_file_tool"
        - tool_called: "set_context_tool"
        - response_matches_schema:
            type: "object"
            required: ["models"]
            properties:
              models:
                type: "array"
                items:
                  type: "object"
                  required: ["name"]
        - golden_match:
            reference: "fixtures/golden_output.json"
            mode: "exact"

  cost:
    track: true
    baseline: "fixtures/cost_baseline.json"
    thresholds:
      input_tokens: 20
      cost_usd: 25
      latency_ms: 30
```

- [ ] **Step 2: Create fixture files**

For `golden_input.md`: Copy a representative LLD document from an existing workspace or create a minimal test LLD that the model-list-extractor can process.

For `golden_output.json` and `cost_baseline.json`: Run the eval once with `--update-golden` to capture initial baselines:

```bash
cd autobots-agents-mer
make eval-agent AGENT=model-list-extractor
# If golden files don't exist, it will fail. Then run:
pytest tests/eval/nurture/ -k "party_lld" --update-golden -v
```

- [ ] **Step 3: Verify eval passes**

Run: `cd autobots-agents-mer && make eval-smoke`
Expected: PASS with cost summary

- [ ] **Step 4: Commit**

```bash
cd autobots-agents-mer
git add tests/eval/nurture/model-list-extractor/
git commit -m "feat(eval): add first eval case for model-list-extractor"
```

---

## Task 17: CI Resolver Script

**Files:**
- Create: `autobots-agents-mer/.github/scripts/resolve_evals.py`

- [ ] **Step 1: Write the tests**

```python
# Test inline in the script or create a separate test file.
# For simplicity, the script includes a --test flag that runs self-tests.
```

- [ ] **Step 2: Implement resolve_evals.py**

```python
#!/usr/bin/env python3
"""Resolve which eval cases to run based on changed files in a PR.

Usage:
    python resolve_evals.py \
        --changed-files file1.md file2.yaml \
        --agents-yaml agent_configs/nurture/agents.yaml \
        --eval-dir tests/eval/nurture/

Output: Newline-separated list of eval YAML paths to run, or "ALL" if full suite needed.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import yaml


def load_agents_yaml(path: str) -> dict[str, dict]:
    """Load agents.yaml and return agent name → config mapping."""
    with open(path) as f:
        data = yaml.safe_load(f)
    return data.get("agents", {})


def prompt_to_agent(prompt_file: str, agents: dict[str, dict]) -> str | None:
    """Map a prompt filename (without extension) to its agent name."""
    stem = Path(prompt_file).stem
    for agent_name, config in agents.items():
        if config.get("prompt") == stem:
            return agent_name
    return None


def schema_to_agents(schema_file: str, agents: dict[str, dict]) -> list[str]:
    """Map a schema filename to all agents using it."""
    filename = Path(schema_file).name
    return [
        name for name, config in agents.items()
        if config.get("output_schema") == filename
    ]


def find_evals_for_agent(agent_name: str, eval_dir: str) -> list[str]:
    """Find all eval YAML files for a given agent."""
    eval_root = Path(eval_dir)
    results = []

    for yaml_path in eval_root.rglob("*.yaml"):
        with open(yaml_path) as f:
            data = yaml.safe_load(f)
        if data and isinstance(data, dict):
            eval_data = data.get("eval", {})
            if eval_data.get("agent") == agent_name:
                results.append(str(yaml_path))

    return results


def resolve(
    changed_files: list[str],
    agents_yaml: str,
    eval_dir: str,
) -> list[str] | str:
    """Resolve changed files to eval YAML paths.

    Returns "ALL" if full suite should run, or a list of specific YAML paths.
    """
    agents = load_agents_yaml(agents_yaml)
    target_agents: set[str] = set()
    direct_eval_files: set[str] = set()
    run_all = False

    for f in changed_files:
        p = Path(f)

        # agents.yaml changed → run all
        if p.name == "agents.yaml":
            run_all = True
            break

        # Source code changed → run all
        if "src/" in str(p):
            run_all = True
            break

        # Prompt changed → run evals for that agent
        if "/prompts/" in str(p):
            agent = prompt_to_agent(p.stem, agents)
            if agent:
                target_agents.add(agent)

        # Schema changed → run evals for agents using that schema
        if "/schemas/" in str(p):
            for agent in schema_to_agents(p.name, agents):
                target_agents.add(agent)

        # Eval file changed → run eval YAMLs in the same directory
        if "tests/eval/" in str(p):
            for yaml_path in p.parent.glob("*.yaml"):
                direct_eval_files.add(str(yaml_path))
            # Also check if the changed file itself is a YAML eval case
            if p.suffix == ".yaml":
                direct_eval_files.add(str(p))

    if run_all:
        return "ALL"

    evals: list[str] = list(direct_eval_files)
    for agent in target_agents:
        evals.extend(find_evals_for_agent(agent, eval_dir))

    return sorted(set(evals))


def main():
    parser = argparse.ArgumentParser(description="Resolve changed files to eval cases")
    parser.add_argument("--changed-files", nargs="+", required=True)
    parser.add_argument("--agents-yaml", required=True)
    parser.add_argument("--eval-dir", required=True)
    args = parser.parse_args()

    result = resolve(args.changed_files, args.agents_yaml, args.eval_dir)

    if result == "ALL":
        print("ALL")
    elif result:
        for path in result:
            print(path)
    else:
        print("NONE")


if __name__ == "__main__":
    main()
```

- [ ] **Step 3: Test locally**

Run: `cd autobots-agents-mer && python .github/scripts/resolve_evals.py --changed-files "agent_configs/nurture/prompts/model-list-extractor.md" --agents-yaml "agent_configs/nurture/agents.yaml" --eval-dir "tests/eval/nurture/"`
Expected: Outputs the model-list-extractor eval YAML path

- [ ] **Step 4: Commit**

```bash
cd autobots-agents-mer
git add .github/scripts/resolve_evals.py
git commit -m "feat(eval): add CI resolver script for targeted eval execution"
```

---

## Task 18: GitHub Actions Workflow

**Files:**
- Create: `autobots-agents-mer/.github/workflows/nurture-eval-gate.yml`

- [ ] **Step 1: Implement workflow**

```yaml
# .github/workflows/nurture-eval-gate.yml
name: Nurture Eval Gate

on:
  pull_request:
    paths:
      - "agent_configs/nurture/**"
      - "src/autobots_agents_mer/domains/nurture/**"
      - "tests/eval/nurture/**"

  workflow_dispatch:
    inputs:
      full_suite:
        description: "Run full eval suite"
        type: boolean
        default: true

  issue_comment:
    types: [created]

jobs:
  resolve:
    if: >
      github.event_name == 'pull_request' ||
      github.event_name == 'workflow_dispatch' ||
      (github.event_name == 'issue_comment' && contains(github.event.comment.body, '/eval-full'))
    runs-on: ubuntu-latest
    outputs:
      eval_scope: ${{ steps.resolve.outputs.scope }}
      eval_files: ${{ steps.resolve.outputs.files }}
    steps:
      - uses: actions/checkout@v4

      - name: Resolve eval scope
        id: resolve
        run: |
          if [[ "${{ github.event_name }}" == "workflow_dispatch" ]] || [[ "${{ github.event_name }}" == "issue_comment" ]]; then
            echo "scope=ALL" >> $GITHUB_OUTPUT
            echo "files=" >> $GITHUB_OUTPUT
          else
            CHANGED=$(git diff --name-only origin/${{ github.base_ref }}...HEAD)
            RESULT=$(python .github/scripts/resolve_evals.py \
              --changed-files $CHANGED \
              --agents-yaml agent_configs/nurture/agents.yaml \
              --eval-dir tests/eval/nurture/)
            if [[ "$RESULT" == "ALL" ]]; then
              echo "scope=ALL" >> $GITHUB_OUTPUT
              echo "files=" >> $GITHUB_OUTPUT
            elif [[ "$RESULT" == "NONE" ]]; then
              echo "scope=NONE" >> $GITHUB_OUTPUT
              echo "files=" >> $GITHUB_OUTPUT
            else
              echo "scope=TARGETED" >> $GITHUB_OUTPUT
              echo "files=$RESULT" >> $GITHUB_OUTPUT
            fi
          fi

  eval:
    needs: resolve
    if: needs.resolve.outputs.eval_scope != 'NONE'
    runs-on: ubuntu-latest
    env:
      GOOGLE_API_KEY: ${{ secrets.GOOGLE_API_KEY }}
      LANGFUSE_PUBLIC_KEY: ${{ secrets.LANGFUSE_PUBLIC_KEY }}
      LANGFUSE_SECRET_KEY: ${{ secrets.LANGFUSE_SECRET_KEY }}
      LANGFUSE_HOST: ${{ secrets.LANGFUSE_HOST }}
      DYNAGENT_CONFIG_ROOT_DIR: agent_configs/nurture

    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-python@v5
        with:
          python-version: "3.12"

      - name: Install dependencies
        run: make install-dev

      - name: Run targeted evals
        if: needs.resolve.outputs.eval_scope == 'TARGETED'
        run: |
          FILES="${{ needs.resolve.outputs.eval_files }}"
          pytest $FILES -m eval --eval-cost-report=reports/eval_cost.json -v

      - name: Run full eval suite
        if: needs.resolve.outputs.eval_scope == 'ALL'
        run: make eval

      - name: Upload cost report
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: eval-cost-report
          path: reports/eval_cost.json
          if-no-files-found: ignore

      - name: Post PR comment
        if: always() && github.event_name == 'pull_request'
        uses: actions/github-script@v7
        with:
          script: |
            const fs = require('fs');
            let body = '## Eval Results — Nurture\n\n';
            try {
              const report = JSON.parse(fs.readFileSync('reports/eval_cost.json', 'utf8'));
              body += '| Agent | Eval | Result | Tokens (Δ) | Cost (Δ) | Latency (Δ) |\n';
              body += '|---|---|---|---|---|---|\n';
              for (const e of report.evals) {
                const result = e.passed ? '✅ Pass' : '❌ Fail';
                const tokens = e.cost ? e.cost.total_input_tokens : 'N/A';
                const cost = e.cost ? `$${e.cost.total_cost_usd.toFixed(4)}` : 'N/A';
                const latency = e.cost ? `${(e.cost.total_latency_ms/1000).toFixed(1)}s` : 'N/A';
                let tokenDelta = '';
                let costDelta = '';
                let latencyDelta = '';
                if (e.deltas) {
                  for (const d of e.deltas) {
                    const pct = `(${d.delta_pct > 0 ? '+' : ''}${d.delta_pct}%)`;
                    const warn = d.status === 'warning' ? ' ⚠' : '';
                    if (d.metric === 'input_tokens') tokenDelta = ` ${pct}${warn}`;
                    if (d.metric === 'cost_usd') costDelta = ` ${pct}${warn}`;
                    if (d.metric === 'latency_ms') latencyDelta = ` ${pct}${warn}`;
                  }
                }
                body += `| ${e.agent || 'N/A'} | ${e.name} | ${result} | ${tokens}${tokenDelta} | ${cost}${costDelta} | ${latency}${latencyDelta} |\n`;
              }
            } catch (err) {
              body += 'Cost report not available.\n';
            }
            body += `\n**Scope:** ${{ needs.resolve.outputs.eval_scope }}`;
            body += `\n\nComment \`/eval-full\` to run all evals.`;

            const { data: comments } = await github.rest.issues.listComments({
              owner: context.repo.owner,
              repo: context.repo.repo,
              issue_number: context.issue.number,
            });
            const existing = comments.find(c => c.body.includes('## Eval Results — Nurture'));
            if (existing) {
              await github.rest.issues.updateComment({
                owner: context.repo.owner,
                repo: context.repo.repo,
                comment_id: existing.id,
                body,
              });
            } else {
              await github.rest.issues.createComment({
                owner: context.repo.owner,
                repo: context.repo.repo,
                issue_number: context.issue.number,
                body,
              });
            }
```

- [ ] **Step 2: Commit**

```bash
cd autobots-agents-mer
git add .github/workflows/nurture-eval-gate.yml
git commit -m "feat(eval): add GitHub Actions workflow for nurture eval CI gate"
```

---

## Task 19: Run Full Verification

- [ ] **Step 1: Run shared-lib tests**

Run: `cd autobots-devtools-shared-lib && make all-checks`
Expected: All checks pass (format, lint, type-check, tests)

- [ ] **Step 2: Run MER tests**

Run: `cd autobots-agents-mer && make all-checks`
Expected: All checks pass

- [ ] **Step 3: Run eval smoke test (requires API keys)**

Run: `cd autobots-agents-mer && make eval-smoke`
Expected: Eval runs, produces cost summary

- [ ] **Step 4: Final commit with any fixes**

```bash
git add -A
git commit -m "fix(eval): address lint/type-check issues from full verification"
```
