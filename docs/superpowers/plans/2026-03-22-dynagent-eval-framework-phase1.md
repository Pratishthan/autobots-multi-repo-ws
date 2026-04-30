# Dynagent Eval Framework — Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the foundation of the eval framework: Pydantic models, YAML loader, linear runner, deterministic assertions, Level 1 cost tracking, Langfuse scoring, and pytest plugin — validated with proof-of-concept eval cases.

**Architecture:** A new `eval/` package inside `autobots-devtools-shared-lib` that wraps OpenEvals for assertions, queries Langfuse for cost data, and exposes a pytest plugin for test discovery. Agents are invoked identically to production via `invoke_agent()` — no mocks.

**Tech Stack:** Python 3.12, Pydantic v2, OpenEvals, Langfuse SDK, jsonschema, tiktoken, pytest

**Spec:** `docs/superpowers/specs/2026-03-22-dynagent-eval-framework-design.md`

---

## File Structure

All new files live under `autobots-devtools-shared-lib/` (abbreviated as `shared-lib/` below).

| File | Responsibility |
|------|----------------|
| `shared-lib/src/autobots_devtools_shared_lib/eval/__init__.py` | Public API: `load_eval_cases`, `EvalCase`, `EvalResult` |
| `shared-lib/src/autobots_devtools_shared_lib/eval/models/__init__.py` | Package init |
| `shared-lib/src/autobots_devtools_shared_lib/eval/models/eval_case.py` | Pydantic models: `EvalCase`, `Turn`, `Assertion`, `CostConfig`, `RetryConfig` |
| `shared-lib/src/autobots_devtools_shared_lib/eval/models/result.py` | Dataclasses: `AssertionResult`, `TurnResult`, `EvalResult`, `AgentOutput` |
| `shared-lib/src/autobots_devtools_shared_lib/eval/models/cost.py` | Dataclasses: `ToolAttribution`, `TokenAttribution`, `TurnCost`, `CostReport` |
| `shared-lib/src/autobots_devtools_shared_lib/eval/core/__init__.py` | Package init |
| `shared-lib/src/autobots_devtools_shared_lib/eval/core/loader.py` | `load_eval_cases(eval_dir, tags)` — YAML discovery + Pydantic parsing |
| `shared-lib/src/autobots_devtools_shared_lib/eval/core/runner.py` | `run_linear_eval(eval_case, config, trace_metadata)` — drives linear conversation + assertions |
| `shared-lib/src/autobots_devtools_shared_lib/eval/core/cost_tracker.py` | `query_langfuse(session_id)` — Level 1 token attribution from Langfuse spans |
| `shared-lib/src/autobots_devtools_shared_lib/eval/assertions/__init__.py` | Package init |
| `shared-lib/src/autobots_devtools_shared_lib/eval/assertions/registry.py` | `REGISTRY` dict, `register_assertion()`, `resolve_assertion()` |
| `shared-lib/src/autobots_devtools_shared_lib/eval/assertions/deterministic.py` | `contains`, `regex`, `exact_match`, `json_match`, `schema_match`, `tool_called`, `tool_sequence`, `no_extra_tools`, `tools_unordered` |
| `shared-lib/src/autobots_devtools_shared_lib/eval/scoring/__init__.py` | Package init |
| `shared-lib/src/autobots_devtools_shared_lib/eval/scoring/langfuse_scorer.py` | `post_scores(session_id, eval_result)` — posts assertion results to Langfuse |
| `shared-lib/src/autobots_devtools_shared_lib/eval/pytest_plugin/__init__.py` | Package init |
| `shared-lib/src/autobots_devtools_shared_lib/eval/pytest_plugin/plugin.py` | `pytest_addoption`, `pytest_configure`, `pytest_sessionfinish` |
| `shared-lib/src/autobots_devtools_shared_lib/eval/pytest_plugin/fixtures.py` | `dynagent_eval` fixture |
| `shared-lib/src/autobots_devtools_shared_lib/eval/pytest_plugin/reporting.py` | `write_cost_report(path, results)` — JSON + terminal summary |

Tests:

| File | What it tests |
|------|---------------|
| `shared-lib/tests/unit/eval/test_eval_case_models.py` | Pydantic model validation (valid + invalid YAML shapes) |
| `shared-lib/tests/unit/eval/test_loader.py` | YAML discovery, parsing, tag filtering |
| `shared-lib/tests/unit/eval/test_deterministic_assertions.py` | All deterministic assertion functions |
| `shared-lib/tests/unit/eval/test_registry.py` | Registry lookup, custom assertion registration |
| `shared-lib/tests/unit/eval/test_result_models.py` | Result dataclass behavior (summary, passed logic) |
| `shared-lib/tests/unit/eval/test_cost_models.py` | Cost dataclass behavior |
| `shared-lib/tests/unit/eval/test_runner.py` | Linear runner with mocked invoke_agent |
| `shared-lib/tests/unit/eval/test_cost_tracker.py` | Cost tracker with mocked Langfuse client |
| `shared-lib/tests/unit/eval/test_langfuse_scorer.py` | Scorer with mocked Langfuse client |
| `shared-lib/tests/unit/eval/test_reporting.py` | Cost report JSON + terminal output |
| `shared-lib/tests/unit/eval/test_plugin.py` | Pytest plugin option registration |

Test fixtures:

| File | Purpose |
|------|---------|
| `shared-lib/tests/unit/eval/conftest.py` | Shared fixtures for eval tests |
| `shared-lib/tests/unit/eval/fixtures/` | YAML eval case files for loader tests |

---

## Conventions

- **Imports**: Use full package paths (`from autobots_devtools_shared_lib.eval.models.eval_case import EvalCase`)
- **File headers**: Each file starts with `# ABOUTME:` comments (2 lines) describing what the file does — this is an existing codebase convention
- **Formatting**: Ruff, line-length 100
- **Type checking**: Pyright basic mode
- **Tests**: pytest with `asyncio_mode = "auto"`, tests in `tests/unit/eval/`
- **Activate venv**: `source /Users/pralhad/work/src/ws-autobots/.venv/bin/activate` before running any commands
- **Run tests from**: `cd /Users/pralhad/work/src/ws-autobots/autobots-devtools-shared-lib`
- **Run single test**: `make test-one TEST=tests/unit/eval/test_file.py::test_func`
- **Run all eval tests**: `pytest tests/unit/eval/ -v`
- **Lint**: `make lint` (from `autobots-devtools-shared-lib/`)
- **Type check**: `make type-check` (from `autobots-devtools-shared-lib/`)

---

## Task 1: Add Dependencies

**Files:**
- Modify: `autobots-devtools-shared-lib/pyproject.toml`

- [ ] **Step 1: Add openevals, tiktoken, and pytest-xdist to pyproject.toml**

Open `autobots-devtools-shared-lib/pyproject.toml`. In the `dependencies` list, add:

```toml
    "openevals>=0.1.0",
    "tiktoken>=0.7.0",
```

`jsonschema` is already a dependency. `pydantic` is already a dependency (via `pydantic-settings`). `langfuse` is already a dependency.

In the `[dependency-groups]` `dev` list, add:

```toml
    "pytest-xdist>=3.0.0",
```

- [ ] **Step 2: Add pytest plugin entry point**

In `pyproject.toml`, add a new section after `[tool.poetry.plugins]` (or create it if it doesn't exist):

```toml
[project.entry-points."pytest11"]
dynagent_eval = "autobots_devtools_shared_lib.eval.pytest_plugin.plugin"
```

- [ ] **Step 3: Install dependencies**

```bash
cd /Users/pralhad/work/src/ws-autobots/autobots-devtools-shared-lib
source /Users/pralhad/work/src/ws-autobots/.venv/bin/activate
pip install -e ".[dev]"
```

Verify: `python -c "import openevals; import tiktoken; print('OK')"`

- [ ] **Step 4: Commit**

```bash
cd /Users/pralhad/work/src/ws-autobots/autobots-devtools-shared-lib
git add pyproject.toml
git commit -m "feat(eval): add openevals, tiktoken, pytest-xdist dependencies"
```

---

## Task 2: Pydantic Models (eval_case.py)

**Files:**
- Create: `shared-lib/src/autobots_devtools_shared_lib/eval/__init__.py`
- Create: `shared-lib/src/autobots_devtools_shared_lib/eval/models/__init__.py`
- Create: `shared-lib/src/autobots_devtools_shared_lib/eval/models/eval_case.py`
- Test: `shared-lib/tests/unit/eval/test_eval_case_models.py`

- [ ] **Step 1: Create package structure**

Create empty `__init__.py` files:
- `src/autobots_devtools_shared_lib/eval/__init__.py`
- `src/autobots_devtools_shared_lib/eval/models/__init__.py`
- `src/autobots_devtools_shared_lib/eval/core/__init__.py`
- `src/autobots_devtools_shared_lib/eval/assertions/__init__.py`
- `src/autobots_devtools_shared_lib/eval/scoring/__init__.py`
- `src/autobots_devtools_shared_lib/eval/pytest_plugin/__init__.py`

Each `__init__.py` should have ABOUTME comments:
```python
# ABOUTME: Package init for the eval <subpackage> module.
# ABOUTME: <one-line description>.
```

- [ ] **Step 2: Write failing tests for Pydantic models**

Create `tests/unit/eval/__init__.py` (empty) and `tests/unit/eval/test_eval_case_models.py`:

```python
# ABOUTME: Tests for eval case Pydantic models.
# ABOUTME: Validates YAML-shaped dicts parse correctly into EvalCase models.

import pytest
from pydantic import ValidationError

from autobots_devtools_shared_lib.eval.models.eval_case import (
    Assertion,
    CostConfig,
    EvalCase,
    RetryConfig,
    Turn,
)


def test_minimal_linear_eval_case():
    """Minimal linear eval case with one turn and one assertion."""
    data = {
        "name": "test eval",
        "agent": "coordinator",
        "mode": "linear",
        "tags": ["smoke"],
        "state": {"user_name": "test"},
        "turns": [
            {
                "user": "Hello",
                "assertions": [{"contains": "hi"}],
            }
        ],
        "cost": {"track": False},
    }
    case = EvalCase.model_validate(data)
    assert case.name == "test eval"
    assert case.mode == "linear"
    assert len(case.turns) == 1
    assert len(case.turns[0].assertions) == 1


def test_linear_eval_case_with_multiple_assertions():
    """Linear case with tool_called, contains, and response_matches_schema."""
    data = {
        "name": "multi-assertion",
        "agent": "model-list-extractor",
        "mode": "linear",
        "tags": ["nurture"],
        "state": {"user_name": "test", "repo_name": "fbp-core"},
        "turns": [
            {
                "user": "Extract models",
                "assertions": [
                    {"tool_called": "mer_read_file_tool"},
                    {"contains": "Party"},
                    {"response_matches_schema": "schemas/model_list.json"},
                ],
            }
        ],
        "cost": {"track": True},
    }
    case = EvalCase.model_validate(data)
    assert len(case.turns[0].assertions) == 3
    assert case.turns[0].assertions[0].name == "tool_called"
    assert case.turns[0].assertions[0].config == "mer_read_file_tool"


def test_assertion_parsing_simple_string():
    """Assertion with string value like contains: 'hello'."""
    a = Assertion.model_validate({"contains": "hello"})
    assert a.name == "contains"
    assert a.config == "hello"


def test_assertion_parsing_dict_value():
    """Assertion with dict value like llm_judge: {criteria: ..., threshold: ...}."""
    a = Assertion.model_validate({
        "llm_judge": {"criteria": "Is it correct?", "threshold": 0.8}
    })
    assert a.name == "llm_judge"
    assert a.config["criteria"] == "Is it correct?"
    assert a.config["threshold"] == 0.8


def test_assertion_parsing_list_value():
    """Assertion with list value like tool_sequence: [...]."""
    a = Assertion.model_validate({
        "tool_sequence": [
            {"tool": "set_context_tool"},
            {"tool": "mer_read_file_tool"},
        ]
    })
    assert a.name == "tool_sequence"
    assert len(a.config) == 2


def test_cost_config_defaults():
    """CostConfig has sensible defaults."""
    c = CostConfig.model_validate({})
    assert c.track is False


def test_retry_config_defaults():
    """RetryConfig has sensible defaults."""
    r = RetryConfig.model_validate({})
    assert r.count == 0
    assert r.only_for == []


def test_invalid_mode_rejected():
    """Mode must be 'linear' or 'goal'."""
    with pytest.raises(ValidationError):
        EvalCase.model_validate({
            "name": "bad",
            "agent": "x",
            "mode": "invalid",
            "tags": [],
            "state": {},
            "turns": [],
            "cost": {},
        })


def test_linear_requires_turns():
    """Linear mode must have at least one turn."""
    with pytest.raises(ValidationError):
        EvalCase.model_validate({
            "name": "bad",
            "agent": "x",
            "mode": "linear",
            "tags": [],
            "state": {},
            "turns": [],
            "cost": {},
        })
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
cd /Users/pralhad/work/src/ws-autobots/autobots-devtools-shared-lib
pytest tests/unit/eval/test_eval_case_models.py -v
```

Expected: FAIL — `ModuleNotFoundError: No module named 'autobots_devtools_shared_lib.eval.models.eval_case'`

- [ ] **Step 4: Implement eval_case.py**

Create `src/autobots_devtools_shared_lib/eval/models/eval_case.py`:

```python
# ABOUTME: Pydantic models for YAML eval case definitions.
# ABOUTME: Parses eval YAML into typed, validated EvalCase objects.

from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, field_validator, model_validator


class Assertion(BaseModel):
    """Single assertion parsed from YAML.

    YAML format is {assertion_name: config_value}, e.g.:
      - contains: "hello"
      - tool_called: "my_tool"
      - llm_judge: {criteria: "...", threshold: 0.8}
      - tool_sequence: [{tool: "a"}, {tool: "b"}]
    """

    name: str
    config: Any

    @model_validator(mode="before")
    @classmethod
    def parse_yaml_dict(cls, data: Any) -> dict[str, Any]:
        if isinstance(data, dict) and "name" not in data:
            if len(data) != 1:
                msg = f"Assertion must have exactly one key, got {list(data.keys())}"
                raise ValueError(msg)
            name, config = next(iter(data.items()))
            return {"name": name, "config": config}
        return data


class CostConfig(BaseModel):
    """Cost tracking configuration."""

    track: bool = False


class RetryConfig(BaseModel):
    """Retry configuration for flaky assertions."""

    count: int = 0
    only_for: list[str] = []


class Turn(BaseModel):
    """Single conversation turn: user message + assertions on agent response."""

    user: str
    assertions: list[Assertion] = []


class EvalCase(BaseModel):
    """Top-level eval case parsed from YAML."""

    name: str
    agent: str
    mode: Literal["linear", "goal"]
    tags: list[str] = []
    state: dict[str, Any] = {}
    turns: list[Turn] | None = None
    retry: RetryConfig = RetryConfig()
    cost: CostConfig = CostConfig()

    @field_validator("turns")
    @classmethod
    def linear_requires_turns(cls, v: list[Turn] | None, info: Any) -> list[Turn] | None:
        if info.data.get("mode") == "linear" and (v is None or len(v) == 0):
            msg = "Linear mode requires at least one turn"
            raise ValueError(msg)
        return v
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
pytest tests/unit/eval/test_eval_case_models.py -v
```

Expected: all tests PASS.

- [ ] **Step 6: Run lint and type check**

```bash
make lint && make type-check
```

Fix any issues.

- [ ] **Step 7: Commit**

```bash
git add src/autobots_devtools_shared_lib/eval/ tests/unit/eval/
git commit -m "feat(eval): add Pydantic models for eval case YAML parsing"
```

---

## Task 3: Result Models (result.py + cost.py)

**Files:**
- Create: `shared-lib/src/autobots_devtools_shared_lib/eval/models/result.py`
- Create: `shared-lib/src/autobots_devtools_shared_lib/eval/models/cost.py`
- Test: `shared-lib/tests/unit/eval/test_result_models.py`
- Test: `shared-lib/tests/unit/eval/test_cost_models.py`

- [ ] **Step 1: Write failing tests for result models**

Create `tests/unit/eval/test_result_models.py`:

```python
# ABOUTME: Tests for eval result dataclasses.
# ABOUTME: Validates EvalResult.summary(), TurnResult.passed logic, etc.

from autobots_devtools_shared_lib.eval.models.result import (
    AgentOutput,
    AssertionResult,
    EvalResult,
    TurnResult,
)


def test_turn_result_passed_when_all_assertions_pass():
    turn = TurnResult(
        turn=1,
        assertions=[
            AssertionResult(passed=True, name="contains", detail="found"),
            AssertionResult(passed=True, name="tool_called", detail="ok"),
        ],
        passed=True,
        agent_message="hello",
    )
    assert turn.passed is True


def test_turn_result_failed_when_any_assertion_fails():
    turn = TurnResult(
        turn=1,
        assertions=[
            AssertionResult(passed=True, name="contains", detail="found"),
            AssertionResult(passed=False, name="tool_called", detail="not found"),
        ],
        passed=False,
        agent_message="hello",
    )
    assert turn.passed is False


def test_eval_result_summary_on_failure():
    result = EvalResult(
        name="test eval",
        passed=False,
        turns=[
            TurnResult(
                turn=1,
                assertions=[
                    AssertionResult(passed=False, name="contains:Party", detail="not found"),
                ],
                passed=False,
                agent_message="no models found",
            )
        ],
        cost_report=None,
    )
    summary = result.summary()
    assert "test eval" in summary
    assert "FAILED" in summary or "contains:Party" in summary


def test_eval_result_summary_on_pass():
    result = EvalResult(
        name="test eval",
        passed=True,
        turns=[
            TurnResult(
                turn=1,
                assertions=[
                    AssertionResult(passed=True, name="contains", detail="found"),
                ],
                passed=True,
                agent_message="hello",
            )
        ],
        cost_report=None,
    )
    summary = result.summary()
    assert "test eval" in summary


def test_assertion_result_inconclusive():
    r = AssertionResult(passed=False, name="llm_judge", detail="timeout", inconclusive=True)
    assert r.inconclusive is True


def test_agent_output_creation():
    output = AgentOutput(
        messages=[],
        structured_response=None,
        agent_name="coordinator",
        raw_state={},
    )
    assert output.agent_name == "coordinator"
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
pytest tests/unit/eval/test_result_models.py -v
```

Expected: FAIL — `ModuleNotFoundError`

- [ ] **Step 3: Implement result.py**

Create `src/autobots_devtools_shared_lib/eval/models/result.py`:

```python
# ABOUTME: Dataclasses for eval execution results.
# ABOUTME: AgentOutput wraps invoke_agent output; AssertionResult/TurnResult/EvalResult track pass/fail.

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from langchain_core.messages import BaseMessage

from autobots_devtools_shared_lib.eval.models.cost import CostReport


@dataclass
class AgentOutput:
    """Normalized output from invoke_agent for assertion evaluation."""

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
    inconclusive: bool = False


@dataclass
class TurnResult:
    """Result of all assertions for a single conversation turn."""

    turn: int
    assertions: list[AssertionResult]
    passed: bool
    agent_message: str | None
    error: str | None = None


@dataclass
class EvalResult:
    """Overall result of an eval case execution."""

    name: str
    passed: bool
    turns: list[TurnResult]
    cost_report: CostReport | None
    termination_reason: str | None = None
    error: str | None = None

    def summary(self) -> str:
        """Human-readable summary for pytest failure output."""
        lines = [f"Eval: {self.name}"]
        status = "PASSED" if self.passed else "FAILED"
        lines.append(f"Status: {status}")

        if self.error:
            lines.append(f"Error: {self.error}")

        for turn in self.turns:
            if not turn.passed:
                lines.append(f"  Turn {turn.turn}:")
                for a in turn.assertions:
                    if not a.passed:
                        flag = " (inconclusive)" if a.inconclusive else ""
                        lines.append(f"    FAIL {a.name}: {a.detail}{flag}")

        return "\n".join(lines)
```

- [ ] **Step 4: Write failing tests for cost models**

Create `tests/unit/eval/test_cost_models.py`:

```python
# ABOUTME: Tests for cost analysis dataclasses.
# ABOUTME: Validates CostReport aggregation and ToolAttribution fields.

from autobots_devtools_shared_lib.eval.models.cost import (
    CostReport,
    TokenAttribution,
    ToolAttribution,
    TurnCost,
)


def test_tool_attribution_creation():
    t = ToolAttribution(
        tool_name="mer_read_file_tool(docs/file.md)",
        tool_input="docs/file.md",
        result_tokens=1900,
    )
    assert t.utilization is None
    assert t.recommendation is None


def test_turn_cost_with_attribution():
    attr = TokenAttribution(
        system_prompt_tokens=800,
        conversation_history_tokens=150,
        tool_result_tokens=2100,
        tools=[],
        overhead_tokens=150,
    )
    tc = TurnCost(
        turn=1,
        model="gemini-2.0-flash",
        input_tokens=3200,
        output_tokens=600,
        cost_usd=0.035,
        latency_ms=1200,
        attribution=attr,
    )
    assert tc.input_tokens == 3200


def test_cost_report_creation():
    report = CostReport(
        eval_name="test",
        agent="coordinator",
        turns=[],
        total_input_tokens=3200,
        total_output_tokens=600,
        total_cost_usd=0.035,
        total_latency_ms=1200,
        llm_calls=2,
        lowest_utilization_tools=[],
        recommendations=[],
    )
    assert report.total_cost_usd == 0.035
```

- [ ] **Step 5: Implement cost.py**

Create `src/autobots_devtools_shared_lib/eval/models/cost.py`:

```python
# ABOUTME: Dataclasses for cost analysis and token attribution.
# ABOUTME: ToolAttribution tracks per-tool token usage; CostReport aggregates across turns.

from __future__ import annotations

from dataclasses import dataclass, field


@dataclass
class ToolAttribution:
    """Token usage for a single tool call."""

    tool_name: str
    tool_input: str
    result_tokens: int
    utilization: float | None = None
    used_content_summary: str | None = None
    recommendation: str | None = None


@dataclass
class TokenAttribution:
    """Breakdown of input tokens by source for a single LLM call."""

    system_prompt_tokens: int
    conversation_history_tokens: int
    tool_result_tokens: int
    tools: list[ToolAttribution]
    overhead_tokens: int


@dataclass
class TurnCost:
    """Cost data for a single conversation turn."""

    turn: int
    model: str
    input_tokens: int
    output_tokens: int
    cost_usd: float
    latency_ms: int
    attribution: TokenAttribution


@dataclass
class CostReport:
    """Aggregate cost report for an entire eval run."""

    eval_name: str
    agent: str
    turns: list[TurnCost]
    total_input_tokens: int
    total_output_tokens: int
    total_cost_usd: float
    total_latency_ms: int
    llm_calls: int
    lowest_utilization_tools: list[ToolAttribution]
    recommendations: list[str]
```

- [ ] **Step 6: Run all tests**

```bash
pytest tests/unit/eval/test_result_models.py tests/unit/eval/test_cost_models.py -v
```

Expected: all PASS.

- [ ] **Step 7: Lint and type check**

```bash
make lint && make type-check
```

- [ ] **Step 8: Commit**

```bash
git add src/autobots_devtools_shared_lib/eval/models/ tests/unit/eval/
git commit -m "feat(eval): add result and cost dataclasses"
```

---

## Task 4: Assertion Registry

**Files:**
- Create: `shared-lib/src/autobots_devtools_shared_lib/eval/assertions/registry.py`
- Test: `shared-lib/tests/unit/eval/test_registry.py`

- [ ] **Step 1: Write failing tests**

Create `tests/unit/eval/test_registry.py`:

```python
# ABOUTME: Tests for the assertion registry.
# ABOUTME: Validates lookup, registration of custom assertions, and unknown assertion error.

import pytest

from autobots_devtools_shared_lib.eval.assertions.registry import (
    register_assertion,
    resolve_assertion,
)
from autobots_devtools_shared_lib.eval.models.result import AgentOutput, AssertionResult


def test_resolve_builtin_contains():
    fn = resolve_assertion("contains")
    assert callable(fn)


def test_resolve_builtin_tool_called():
    fn = resolve_assertion("tool_called")
    assert callable(fn)


def test_resolve_unknown_raises():
    with pytest.raises(KeyError, match="no_such_assertion"):
        resolve_assertion("no_such_assertion")


def test_register_custom_assertion():
    def my_custom(agent_output: AgentOutput, config: object) -> AssertionResult:
        return AssertionResult(passed=True, name="my_custom", detail="ok")

    register_assertion("my_custom", my_custom)
    fn = resolve_assertion("my_custom")
    assert fn is my_custom


def test_resolve_all_builtins():
    """All spec-defined assertion names are resolvable."""
    builtins = [
        "contains",
        "regex",
        "exact_match",
        "json_match",
        "response_matches_schema",
        "tool_called",
        "tool_sequence",
        "no_extra_tools",
        "tools_unordered",
    ]
    for name in builtins:
        fn = resolve_assertion(name)
        assert callable(fn), f"{name} not callable"
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
pytest tests/unit/eval/test_registry.py -v
```

Expected: FAIL

- [ ] **Step 3: Implement registry.py**

Create `src/autobots_devtools_shared_lib/eval/assertions/registry.py`:

```python
# ABOUTME: Maps YAML assertion names to evaluator functions.
# ABOUTME: Supports built-in assertions and custom consumer-registered assertions.

from __future__ import annotations

from typing import Any, Protocol

from autobots_devtools_shared_lib.eval.models.result import AgentOutput, AssertionResult


class EvalFn(Protocol):
    """Protocol for assertion evaluator functions."""

    def __call__(self, agent_output: AgentOutput, config: Any) -> AssertionResult: ...


_REGISTRY: dict[str, EvalFn] = {}


def _register_builtins() -> None:
    """Lazily register built-in assertions on first access."""
    if _REGISTRY:
        return

    from autobots_devtools_shared_lib.eval.assertions.deterministic import (
        contains,
        exact_match,
        json_match,
        no_extra_tools,
        regex,
        schema_match,
        tool_called,
        tool_sequence,
        tools_unordered,
    )

    _REGISTRY.update({
        "contains": contains,
        "regex": regex,
        "exact_match": exact_match,
        "json_match": json_match,
        "response_matches_schema": schema_match,
        "tool_called": tool_called,
        "tool_sequence": tool_sequence,
        "no_extra_tools": no_extra_tools,
        "tools_unordered": tools_unordered,
    })


def register_assertion(name: str, fn: EvalFn) -> None:
    """Register a custom assertion evaluator."""
    _register_builtins()
    _REGISTRY[name] = fn


def resolve_assertion(name: str) -> EvalFn:
    """Look up an assertion evaluator by name. Raises KeyError if not found."""
    _register_builtins()
    if name not in _REGISTRY:
        available = ", ".join(sorted(_REGISTRY.keys()))
        msg = f"Unknown assertion '{name}'. Available: {available}"
        raise KeyError(msg)
    return _REGISTRY[name]
```

- [ ] **Step 4: Run tests — they will still fail** (deterministic.py doesn't exist yet)

This is expected. Proceed to Task 5 to implement deterministic.py, then come back and verify.

- [ ] **Step 5: Commit**

```bash
git add src/autobots_devtools_shared_lib/eval/assertions/registry.py tests/unit/eval/test_registry.py
git commit -m "feat(eval): add assertion registry with lookup and custom registration"
```

---

## Task 5: Deterministic Assertions

**Files:**
- Create: `shared-lib/src/autobots_devtools_shared_lib/eval/assertions/deterministic.py`
- Test: `shared-lib/tests/unit/eval/test_deterministic_assertions.py`

- [ ] **Step 1: Write failing tests**

Create `tests/unit/eval/test_deterministic_assertions.py`:

```python
# ABOUTME: Tests for deterministic assertion functions.
# ABOUTME: Tests contains, regex, exact_match, schema_match, and tool_called assertions.

from unittest.mock import MagicMock

from langchain_core.messages import AIMessage, HumanMessage, ToolMessage

from autobots_devtools_shared_lib.eval.assertions.deterministic import (
    contains,
    exact_match,
    regex,
    schema_match,
    tool_called,
)
from autobots_devtools_shared_lib.eval.models.result import AgentOutput


def _make_output(content: str, tool_calls: list | None = None) -> AgentOutput:
    """Helper to build AgentOutput with a simple AI message."""
    ai_msg = AIMessage(content=content)
    if tool_calls:
        ai_msg.tool_calls = tool_calls
    return AgentOutput(
        messages=[HumanMessage(content="test"), ai_msg],
        structured_response=None,
        agent_name="test",
        raw_state={},
    )


def test_contains_passes():
    output = _make_output("Hello world, Party is here")
    result = contains(output, "Party")
    assert result.passed is True


def test_contains_fails():
    output = _make_output("Hello world")
    result = contains(output, "Party")
    assert result.passed is False


def test_contains_case_insensitive():
    output = _make_output("Hello Party")
    result = contains(output, "party")
    assert result.passed is True


def test_regex_passes():
    output = _make_output("Found 3 models: Party, Address, Contact")
    result = regex(output, r"\d+ models")
    assert result.passed is True


def test_regex_fails():
    output = _make_output("No models found")
    result = regex(output, r"\d+ models")
    assert result.passed is False


def test_exact_match_passes():
    output = _make_output("hello")
    result = exact_match(output, "hello")
    assert result.passed is True


def test_exact_match_fails():
    output = _make_output("hello world")
    result = exact_match(output, "hello")
    assert result.passed is False


def test_schema_match_passes(tmp_path):
    schema_file = tmp_path / "test_schema.json"
    schema_file.write_text('{"type": "object", "required": ["models"]}')
    output = _make_output('{"models": ["Party"]}')
    result = schema_match(output, str(schema_file))
    assert result.passed is True


def test_schema_match_fails(tmp_path):
    schema_file = tmp_path / "test_schema.json"
    schema_file.write_text('{"type": "object", "required": ["models"]}')
    output = _make_output('{"items": ["Party"]}')
    result = schema_match(output, str(schema_file))
    assert result.passed is False


def test_tool_called_passes():
    output = _make_output(
        "done",
        tool_calls=[{"name": "mer_read_file_tool", "args": {}, "id": "1"}],
    )
    result = tool_called(output, "mer_read_file_tool")
    assert result.passed is True


def test_tool_called_fails():
    output = _make_output("done", tool_calls=[])
    result = tool_called(output, "mer_read_file_tool")
    assert result.passed is False
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
pytest tests/unit/eval/test_deterministic_assertions.py -v
```

Expected: FAIL

- [ ] **Step 3: Implement deterministic.py**

Create `src/autobots_devtools_shared_lib/eval/assertions/deterministic.py`:

```python
# ABOUTME: Deterministic assertion functions wrapping OpenEvals and built-in checks.
# ABOUTME: Each function takes AgentOutput + config and returns AssertionResult.

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

import jsonschema as js

from autobots_devtools_shared_lib.eval.models.result import AgentOutput, AssertionResult


def _last_ai_content(agent_output: AgentOutput) -> str:
    """Extract text content from the last AI message."""
    for msg in reversed(agent_output.messages):
        if hasattr(msg, "type") and msg.type == "ai" and msg.content:
            return str(msg.content)
    return ""


def _all_tool_names(agent_output: AgentOutput) -> list[str]:
    """Extract all tool names called across all messages."""
    names: list[str] = []
    for msg in agent_output.messages:
        if hasattr(msg, "tool_calls"):
            for tc in msg.tool_calls:
                if isinstance(tc, dict):
                    names.append(tc.get("name", ""))
                elif hasattr(tc, "name"):
                    names.append(tc.name)
    return names


def contains(agent_output: AgentOutput, config: Any) -> AssertionResult:
    """Check if agent response contains a substring (case-insensitive)."""
    text = _last_ai_content(agent_output).lower()
    target = str(config).lower()
    found = target in text
    return AssertionResult(
        passed=found,
        name=f"contains:{config}",
        detail=f"{'Found' if found else 'Not found'} in response",
    )


def regex(agent_output: AgentOutput, config: Any) -> AssertionResult:
    """Check if agent response matches a regex pattern."""
    text = _last_ai_content(agent_output)
    pattern = str(config)
    match = bool(re.search(pattern, text))
    return AssertionResult(
        passed=match,
        name=f"regex:{pattern}",
        detail=f"{'Matched' if match else 'No match'} for pattern",
    )


def exact_match(agent_output: AgentOutput, config: Any) -> AssertionResult:
    """Check if agent response exactly matches expected string."""
    text = _last_ai_content(agent_output)
    expected = str(config)
    passed = text.strip() == expected.strip()
    return AssertionResult(
        passed=passed,
        name="exact_match",
        detail=f"Expected: {expected[:100]}",
    )


def json_match(agent_output: AgentOutput, config: Any) -> AssertionResult:
    """Check if agent response JSON matches expected JSON."""
    text = _last_ai_content(agent_output)
    try:
        actual = json.loads(text)
        expected = config if isinstance(config, dict) else json.loads(str(config))
        passed = actual == expected
        return AssertionResult(
            passed=passed,
            name="json_match",
            detail="JSON matches" if passed else "JSON does not match",
        )
    except (json.JSONDecodeError, TypeError) as e:
        return AssertionResult(passed=False, name="json_match", detail=f"Parse error: {e}")


def schema_match(agent_output: AgentOutput, config: Any) -> AssertionResult:
    """Validate agent response JSON against a JSON schema file."""
    text = _last_ai_content(agent_output)
    schema_path = Path(str(config))
    try:
        schema = json.loads(schema_path.read_text())
        data = json.loads(text)
        js.validate(instance=data, schema=schema)
        return AssertionResult(passed=True, name="response_matches_schema", detail="Valid")
    except js.ValidationError as e:
        return AssertionResult(
            passed=False,
            name="response_matches_schema",
            detail=f"Schema validation failed: {e.message}",
        )
    except (json.JSONDecodeError, FileNotFoundError, OSError) as e:
        return AssertionResult(
            passed=False,
            name="response_matches_schema",
            detail=f"Error: {e}",
        )


def tool_called(agent_output: AgentOutput, config: Any) -> AssertionResult:
    """Check if a specific tool was called during the conversation."""
    target = str(config)
    called = _all_tool_names(agent_output)
    found = target in called
    return AssertionResult(
        passed=found,
        name=f"tool_called:{target}",
        detail=f"Tools called: {called}" if not found else "Found",
    )


def tool_sequence(agent_output: AgentOutput, config: Any) -> AssertionResult:
    """Check if tools were called in a specific order."""
    if not isinstance(config, list):
        return AssertionResult(
            passed=False, name="tool_sequence", detail="Config must be a list"
        )

    expected_names = [step["tool"] for step in config if isinstance(step, dict)]
    called = _all_tool_names(agent_output)

    # Check subsequence match (in order, not necessarily contiguous)
    idx = 0
    for name in called:
        if idx < len(expected_names) and name == expected_names[idx]:
            idx += 1
    passed = idx == len(expected_names)

    return AssertionResult(
        passed=passed,
        name="tool_sequence",
        detail=f"Expected: {expected_names}, Called: {called}",
    )


def no_extra_tools(agent_output: AgentOutput, config: Any) -> AssertionResult:
    """Check that no tools beyond the allowed set were called."""
    allowed = set(config) if isinstance(config, list) else {str(config)}
    called = set(_all_tool_names(agent_output))
    extra = called - allowed
    passed = len(extra) == 0
    return AssertionResult(
        passed=passed,
        name="no_extra_tools",
        detail=f"Extra tools: {extra}" if extra else "No extra tools",
    )


def tools_unordered(agent_output: AgentOutput, config: Any) -> AssertionResult:
    """Check that all expected tools were called (order doesn't matter)."""
    expected = set(config) if isinstance(config, list) else {str(config)}
    called = set(_all_tool_names(agent_output))
    missing = expected - called
    passed = len(missing) == 0
    return AssertionResult(
        passed=passed,
        name="tools_unordered",
        detail=f"Missing: {missing}" if missing else "All tools called",
    )
```

- [ ] **Step 4: Run all assertion tests**

```bash
pytest tests/unit/eval/test_deterministic_assertions.py tests/unit/eval/test_registry.py -v
```

Expected: all PASS.

- [ ] **Step 5: Lint and type check**

```bash
make lint && make type-check
```

- [ ] **Step 6: Commit**

```bash
git add src/autobots_devtools_shared_lib/eval/assertions/ tests/unit/eval/
git commit -m "feat(eval): add deterministic assertions and registry wiring"
```

---

## Task 6: YAML Loader

**Files:**
- Create: `shared-lib/src/autobots_devtools_shared_lib/eval/core/loader.py`
- Create: `shared-lib/tests/unit/eval/fixtures/` (test YAML files)
- Test: `shared-lib/tests/unit/eval/test_loader.py`

- [ ] **Step 1: Create test YAML fixtures**

Create `tests/unit/eval/fixtures/valid_linear.yaml`:

```yaml
eval:
  name: "Test linear eval"
  agent: "coordinator"
  mode: linear
  tags: ["smoke", "unit"]
  state:
    user_name: "test-user"
  turns:
    - user: "Hello"
      assertions:
        - contains: "hello"
        - tool_called: "get_agent_list"
  cost:
    track: false
```

Create `tests/unit/eval/fixtures/valid_linear_tagged.yaml`:

```yaml
eval:
  name: "Tagged eval"
  agent: "coordinator"
  mode: linear
  tags: ["integration"]
  state: {}
  turns:
    - user: "Test"
      assertions:
        - contains: "test"
  cost:
    track: false
```

Create `tests/unit/eval/fixtures/invalid_no_turns.yaml`:

```yaml
eval:
  name: "Bad eval"
  agent: "coordinator"
  mode: linear
  tags: []
  state: {}
  turns: []
  cost:
    track: false
```

- [ ] **Step 2: Write failing tests**

Create `tests/unit/eval/test_loader.py`:

```python
# ABOUTME: Tests for YAML eval case loader.
# ABOUTME: Validates discovery, parsing, tag filtering, and error handling.

from pathlib import Path

import pytest

from autobots_devtools_shared_lib.eval.core.loader import EvalConfigError, load_eval_cases

FIXTURES = Path(__file__).parent / "fixtures"


def test_load_valid_linear():
    cases = load_eval_cases(str(FIXTURES))
    names = [c.name for c in cases]
    assert "Test linear eval" in names


def test_load_with_tag_filter():
    cases = load_eval_cases(str(FIXTURES), tags=["smoke"])
    assert len(cases) >= 1
    assert all("smoke" in c.tags for c in cases)


def test_load_tag_filter_excludes():
    cases = load_eval_cases(str(FIXTURES), tags=["nonexistent"])
    assert len(cases) == 0


def test_load_invalid_raises():
    """Invalid YAML (linear with no turns) should raise EvalConfigError."""
    invalid_dir = FIXTURES / "invalid_only"
    invalid_dir.mkdir(exist_ok=True)
    invalid_file = invalid_dir / "bad.yaml"
    invalid_file.write_text(
        "eval:\n  name: bad\n  agent: x\n  mode: linear\n  tags: []\n"
        "  state: {}\n  turns: []\n  cost: {}\n"
    )
    try:
        with pytest.raises(EvalConfigError):
            load_eval_cases(str(invalid_dir))
    finally:
        invalid_file.unlink()
        invalid_dir.rmdir()


def test_load_empty_dir_returns_empty(tmp_path):
    """Empty directory returns empty list (no error)."""
    cases = load_eval_cases(str(tmp_path))
    assert cases == []
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
pytest tests/unit/eval/test_loader.py -v
```

- [ ] **Step 4: Implement loader.py**

Create `src/autobots_devtools_shared_lib/eval/core/loader.py`:

```python
# ABOUTME: YAML eval case discovery and parsing.
# ABOUTME: Recursively finds *.yaml files, validates with Pydantic, returns EvalCase list.

from __future__ import annotations

import logging
from pathlib import Path

import yaml
from pydantic import ValidationError

from autobots_devtools_shared_lib.eval.models.eval_case import EvalCase

logger = logging.getLogger(__name__)


class EvalConfigError(Exception):
    """Raised when an eval YAML file is invalid."""


def load_eval_cases(
    eval_dir: str,
    tags: list[str] | None = None,
) -> list[EvalCase]:
    """Discover and parse YAML eval cases from a directory.

    Args:
        eval_dir: Root directory to search for *.yaml files.
        tags: If provided, only return cases that have at least one matching tag.

    Returns:
        List of validated EvalCase objects.

    Raises:
        EvalConfigError: If a YAML file is malformed or fails validation.
    """
    root = Path(eval_dir)
    if not root.is_dir():
        logger.warning("Eval directory does not exist: %s", eval_dir)
        return []

    cases: list[EvalCase] = []

    for yaml_path in sorted(root.rglob("*.yaml")):
        try:
            raw = yaml.safe_load(yaml_path.read_text())
            if raw is None or "eval" not in raw:
                continue  # skip non-eval YAML files

            case = EvalCase.model_validate(raw["eval"])

            if tags and not set(tags) & set(case.tags):
                continue

            cases.append(case)
        except (ValidationError, KeyError, yaml.YAMLError) as e:
            raise EvalConfigError(f"Invalid eval case at {yaml_path}: {e}") from e

    return cases
```

- [ ] **Step 5: Run tests**

```bash
pytest tests/unit/eval/test_loader.py -v
```

Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add src/autobots_devtools_shared_lib/eval/core/ tests/unit/eval/
git commit -m "feat(eval): add YAML eval case loader with tag filtering"
```

---

## Task 7: Linear Runner

**Files:**
- Create: `shared-lib/src/autobots_devtools_shared_lib/eval/core/runner.py`
- Test: `shared-lib/tests/unit/eval/test_runner.py`

- [ ] **Step 1: Write failing tests**

Create `tests/unit/eval/test_runner.py`:

```python
# ABOUTME: Tests for the linear eval runner.
# ABOUTME: Uses mocked invoke_agent to verify turn execution and assertion flow.

from unittest.mock import AsyncMock, patch

import pytest
from langchain_core.messages import AIMessage, HumanMessage

from autobots_devtools_shared_lib.eval.core.runner import run_linear_eval
from autobots_devtools_shared_lib.eval.models.eval_case import (
    Assertion,
    CostConfig,
    EvalCase,
    Turn,
)


def _make_eval_case(assertions: list[dict]) -> EvalCase:
    return EvalCase(
        name="test eval",
        agent="coordinator",
        mode="linear",
        tags=["smoke"],
        state={"user_name": "test"},
        turns=[Turn(user="Hello", assertions=[Assertion.model_validate(a) for a in assertions])],
        cost=CostConfig(track=False),
    )


@pytest.fixture
def mock_invoke():
    with patch(
        "autobots_devtools_shared_lib.eval.core.runner.ainvoke_agent",
        new_callable=AsyncMock,
    ) as mock:
        mock.return_value = {
            "messages": [
                HumanMessage(content="Hello"),
                AIMessage(content="Hi there, Party is here"),
            ],
            "agent_name": "coordinator",
            "structured_response": None,
        }
        yield mock


async def test_linear_single_turn_passes(mock_invoke):
    case = _make_eval_case([{"contains": "Party"}])
    config = {"configurable": {"thread_id": "test-1"}}
    result = await run_linear_eval(case, config, trace_metadata=None)
    assert result.passed is True
    assert len(result.turns) == 1
    assert result.turns[0].passed is True


async def test_linear_single_turn_fails(mock_invoke):
    case = _make_eval_case([{"contains": "NotHere"}])
    config = {"configurable": {"thread_id": "test-2"}}
    result = await run_linear_eval(case, config, trace_metadata=None)
    assert result.passed is False
    assert result.turns[0].passed is False


async def test_linear_multiple_assertions(mock_invoke):
    case = _make_eval_case([{"contains": "Party"}, {"contains": "Hi"}])
    config = {"configurable": {"thread_id": "test-3"}}
    result = await run_linear_eval(case, config, trace_metadata=None)
    assert result.passed is True
    assert len(result.turns[0].assertions) == 2


async def test_linear_agent_error(mock_invoke):
    mock_invoke.side_effect = RuntimeError("LLM failed")
    case = _make_eval_case([{"contains": "anything"}])
    config = {"configurable": {"thread_id": "test-4"}}
    result = await run_linear_eval(case, config, trace_metadata=None)
    assert result.passed is False
    assert result.error is not None
    assert "LLM failed" in result.error
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
pytest tests/unit/eval/test_runner.py -v
```

- [ ] **Step 3: Implement runner.py**

Create `src/autobots_devtools_shared_lib/eval/core/runner.py`:

```python
# ABOUTME: Eval runner that drives agent conversations and collects assertion results.
# ABOUTME: Supports linear mode (Phase 1). Goal-based mode added in Phase 3.

from __future__ import annotations

import logging
from typing import Any

from langchain_core.messages import BaseMessage
from langchain_core.runnables import RunnableConfig

from autobots_devtools_shared_lib.common.observability.trace_metadata import TraceMetadata
from autobots_devtools_shared_lib.dynagent.agents.invocation_utils import ainvoke_agent
from autobots_devtools_shared_lib.eval.assertions.registry import resolve_assertion
from autobots_devtools_shared_lib.eval.models.eval_case import EvalCase
from autobots_devtools_shared_lib.eval.models.result import (
    AgentOutput,
    AssertionResult,
    EvalResult,
    TurnResult,
)

logger = logging.getLogger(__name__)


def _extract_last_ai_content(messages: list[BaseMessage]) -> str | None:
    """Get text content of the last AI message."""
    for msg in reversed(messages):
        if hasattr(msg, "type") and msg.type == "ai" and msg.content:
            return str(msg.content)
    return None


def _build_agent_output(result: dict[str, Any]) -> AgentOutput:
    """Convert invoke_agent result dict to AgentOutput."""
    return AgentOutput(
        messages=result.get("messages", []),
        structured_response=result.get("structured_response"),
        agent_name=result.get("agent_name", ""),
        raw_state=result,
    )


def _run_assertions(
    agent_output: AgentOutput,
    assertions: list[Any],
) -> list[AssertionResult]:
    """Run all assertions against an agent output."""
    results: list[AssertionResult] = []
    for assertion in assertions:
        try:
            eval_fn = resolve_assertion(assertion.name)
            result = eval_fn(agent_output, assertion.config)
            results.append(result)
        except Exception as e:
            results.append(
                AssertionResult(
                    passed=False,
                    name=assertion.name,
                    detail=f"Assertion error: {type(e).__name__}: {e}",
                )
            )
    return results


async def run_linear_eval(
    eval_case: EvalCase,
    config: RunnableConfig,
    trace_metadata: TraceMetadata | None,
) -> EvalResult:
    """Execute a linear eval: replay turns, run assertions after each."""
    turns: list[TurnResult] = []

    if not eval_case.turns:
        return EvalResult(
            name=eval_case.name,
            passed=False,
            turns=[],
            cost_report=None,
            error="No turns defined",
        )

    for turn_num, turn in enumerate(eval_case.turns, start=1):
        try:
            input_state: dict[str, Any] = {
                "messages": [{"role": "user", "content": turn.user}],
                **eval_case.state,
            }

            result = await ainvoke_agent(
                agent_name=eval_case.agent,
                input_state=input_state,
                config=config,
                enable_tracing=trace_metadata is not None,
                trace_metadata=trace_metadata,
            )

            agent_output = _build_agent_output(result)
            assertion_results = _run_assertions(agent_output, turn.assertions)
            all_passed = all(a.passed for a in assertion_results)

            turns.append(
                TurnResult(
                    turn=turn_num,
                    assertions=assertion_results,
                    passed=all_passed,
                    agent_message=_extract_last_ai_content(agent_output.messages),
                )
            )

        except Exception as e:
            logger.exception("Agent invocation failed on turn %d", turn_num)
            turns.append(
                TurnResult(
                    turn=turn_num,
                    assertions=[],
                    passed=False,
                    agent_message=None,
                    error=f"Agent error: {type(e).__name__}: {e}",
                )
            )
            return EvalResult(
                name=eval_case.name,
                passed=False,
                turns=turns,
                cost_report=None,
                termination_reason="agent_error",
                error=str(e),
            )

    all_turns_passed = all(t.passed for t in turns)
    return EvalResult(
        name=eval_case.name,
        passed=all_turns_passed,
        turns=turns,
        cost_report=None,  # Cost tracking wired in pytest fixture
    )
```

- [ ] **Step 4: Run tests**

```bash
pytest tests/unit/eval/test_runner.py -v
```

Expected: all PASS.

- [ ] **Step 5: Lint and type check**

```bash
make lint && make type-check
```

- [ ] **Step 6: Commit**

```bash
git add src/autobots_devtools_shared_lib/eval/core/runner.py tests/unit/eval/test_runner.py
git commit -m "feat(eval): add linear eval runner with assertion execution"
```

---

## Task 8: Cost Tracker (Level 1)

**Files:**
- Create: `shared-lib/src/autobots_devtools_shared_lib/eval/core/cost_tracker.py`
- Test: `shared-lib/tests/unit/eval/test_cost_tracker.py`

- [ ] **Step 1: Write failing tests**

Create `tests/unit/eval/test_cost_tracker.py`:

```python
# ABOUTME: Tests for the Level 1 cost tracker.
# ABOUTME: Validates Langfuse trace querying and token attribution with mocked client.

from unittest.mock import MagicMock, patch

from autobots_devtools_shared_lib.eval.core.cost_tracker import query_langfuse
from autobots_devtools_shared_lib.eval.models.cost import CostReport


def test_query_returns_none_when_langfuse_unavailable():
    with patch(
        "autobots_devtools_shared_lib.eval.core.cost_tracker.get_langfuse_client",
        return_value=None,
    ):
        result = query_langfuse("session-123")
        assert result is None


def test_query_returns_cost_report_with_mock_trace():
    mock_client = MagicMock()

    # Mock trace fetch
    mock_trace = MagicMock()
    mock_trace.observations = [
        MagicMock(
            type="GENERATION",
            model="gemini-2.0-flash",
            usage=MagicMock(input=3200, output=600, total=3800),
            calculated_total_cost=0.035,
            start_time=MagicMock(timestamp=MagicMock(return_value=1000)),
            end_time=MagicMock(timestamp=MagicMock(return_value=2200)),
        ),
    ]
    mock_client.fetch_trace.return_value = mock_trace

    # Mock session traces lookup
    mock_client.fetch_traces.return_value = MagicMock(data=[MagicMock(id="trace-1")])

    with patch(
        "autobots_devtools_shared_lib.eval.core.cost_tracker.get_langfuse_client",
        return_value=mock_client,
    ):
        result = query_langfuse("session-123")
        assert result is not None
        assert isinstance(result, CostReport)
        assert result.total_input_tokens > 0
```

- [ ] **Step 2: Implement cost_tracker.py**

Create `src/autobots_devtools_shared_lib/eval/core/cost_tracker.py`:

```python
# ABOUTME: Level 1 cost tracker that queries Langfuse for token attribution.
# ABOUTME: Extracts per-turn token counts, costs, and tool-level breakdown from trace spans.

from __future__ import annotations

import logging
from typing import Any

from autobots_devtools_shared_lib.common.observability.tracing import get_langfuse_client
from autobots_devtools_shared_lib.eval.models.cost import (
    CostReport,
    TokenAttribution,
    ToolAttribution,
    TurnCost,
)

logger = logging.getLogger(__name__)


def _estimate_tokens(text: str) -> int:
    """Rough token estimation. Uses len/4 as a fast heuristic."""
    if not text:
        return 0
    try:
        import tiktoken

        enc = tiktoken.get_encoding("cl100k_base")
        return len(enc.encode(text))
    except Exception:
        return len(text) // 4


def query_langfuse(session_id: str, partial: bool = False) -> CostReport | None:
    """Query Langfuse for trace data and build a Level 1 cost report.

    Args:
        session_id: The session ID used during the eval run.
        partial: If True, tolerate missing data (for error cases).

    Returns:
        CostReport if Langfuse is available and trace found, None otherwise.
    """
    client = get_langfuse_client()
    if client is None:
        logger.info("Langfuse not configured — cost report unavailable")
        return None

    try:
        # Fetch traces for this session
        traces_response = client.fetch_traces(session_id=session_id)
        traces = traces_response.data if traces_response else []

        if not traces:
            logger.warning("No traces found for session %s", session_id)
            return None

        all_turns: list[TurnCost] = []
        total_input = 0
        total_output = 0
        total_cost = 0.0
        total_latency = 0
        llm_calls = 0

        for trace in traces:
            trace_detail = client.fetch_trace(trace.id)
            if not trace_detail or not hasattr(trace_detail, "observations"):
                continue

            for obs in trace_detail.observations:
                if obs.type != "GENERATION":
                    continue

                llm_calls += 1
                input_tokens = getattr(obs.usage, "input", 0) or 0 if obs.usage else 0
                output_tokens = getattr(obs.usage, "output", 0) or 0 if obs.usage else 0
                cost = obs.calculated_total_cost or 0.0

                # Estimate latency
                latency_ms = 0
                if obs.start_time and obs.end_time:
                    try:
                        start_ts = obs.start_time.timestamp()
                        end_ts = obs.end_time.timestamp()
                        latency_ms = int((end_ts - start_ts) * 1000)
                    except Exception:
                        pass

                total_input += input_tokens
                total_output += output_tokens
                total_cost += cost
                total_latency += latency_ms

                # Build basic attribution (tool-level detail requires span walking)
                tool_attributions: list[ToolAttribution] = []
                attribution = TokenAttribution(
                    system_prompt_tokens=0,  # refined in future
                    conversation_history_tokens=0,
                    tool_result_tokens=0,
                    tools=tool_attributions,
                    overhead_tokens=0,
                )

                all_turns.append(
                    TurnCost(
                        turn=len(all_turns) + 1,
                        model=obs.model or "unknown",
                        input_tokens=input_tokens,
                        output_tokens=output_tokens,
                        cost_usd=cost,
                        latency_ms=latency_ms,
                        attribution=attribution,
                    )
                )

        return CostReport(
            eval_name="",  # set by caller
            agent="",  # set by caller
            turns=all_turns,
            total_input_tokens=total_input,
            total_output_tokens=total_output,
            total_cost_usd=total_cost,
            total_latency_ms=total_latency,
            llm_calls=llm_calls,
            lowest_utilization_tools=[],
            recommendations=[],
        )

    except Exception:
        logger.exception("Failed to query Langfuse for session %s", session_id)
        if partial:
            return None
        raise
```

- [ ] **Step 3: Run tests**

```bash
pytest tests/unit/eval/test_cost_tracker.py -v
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add src/autobots_devtools_shared_lib/eval/core/cost_tracker.py tests/unit/eval/test_cost_tracker.py
git commit -m "feat(eval): add Level 1 cost tracker with Langfuse trace querying"
```

---

## Task 9: Langfuse Scorer

**Files:**
- Create: `shared-lib/src/autobots_devtools_shared_lib/eval/scoring/langfuse_scorer.py`
- Test: `shared-lib/tests/unit/eval/test_langfuse_scorer.py`

- [ ] **Step 1: Write failing tests**

Create `tests/unit/eval/test_langfuse_scorer.py`:

```python
# ABOUTME: Tests for the Langfuse score posting module.
# ABOUTME: Validates scores are posted correctly and graceful degradation when unavailable.

from unittest.mock import MagicMock, patch

from autobots_devtools_shared_lib.eval.models.result import (
    AssertionResult,
    EvalResult,
    TurnResult,
)
from autobots_devtools_shared_lib.eval.scoring.langfuse_scorer import post_scores


def test_post_scores_skips_when_langfuse_unavailable():
    result = EvalResult(
        name="test", passed=True, turns=[], cost_report=None
    )
    with patch(
        "autobots_devtools_shared_lib.eval.scoring.langfuse_scorer.get_langfuse_client",
        return_value=None,
    ):
        # Should not raise
        post_scores("session-1", result)


def test_post_scores_calls_score():
    mock_client = MagicMock()
    result = EvalResult(
        name="test eval",
        passed=True,
        turns=[
            TurnResult(
                turn=1,
                assertions=[
                    AssertionResult(passed=True, name="contains:Party", detail="found"),
                ],
                passed=True,
                agent_message="hello",
            )
        ],
        cost_report=None,
    )
    with patch(
        "autobots_devtools_shared_lib.eval.scoring.langfuse_scorer.get_langfuse_client",
        return_value=mock_client,
    ):
        post_scores("session-1", result)
        assert mock_client.score.called
```

- [ ] **Step 2: Implement langfuse_scorer.py**

Create `src/autobots_devtools_shared_lib/eval/scoring/langfuse_scorer.py`:

```python
# ABOUTME: Posts eval assertion results as scores to Langfuse.
# ABOUTME: Enables eval result visualization alongside agent traces in Langfuse dashboard.

from __future__ import annotations

import logging

from autobots_devtools_shared_lib.common.observability.tracing import get_langfuse_client
from autobots_devtools_shared_lib.eval.models.result import EvalResult

logger = logging.getLogger(__name__)


def post_scores(session_id: str, result: EvalResult) -> None:
    """Post eval results as scores to Langfuse.

    Args:
        session_id: The session ID linking to the Langfuse trace.
        result: The eval result to score.
    """
    client = get_langfuse_client()
    if client is None:
        logger.info("Langfuse not configured — skipping score posting")
        return

    try:
        # Fetch trace ID for this session
        traces_response = client.fetch_traces(session_id=session_id)
        traces = traces_response.data if traces_response else []
        if not traces:
            logger.warning("No trace found for session %s — skipping scoring", session_id)
            return

        trace_id = traces[0].id

        # Post overall eval score
        client.score(
            trace_id=trace_id,
            name=f"eval:{result.name}",
            value=1.0 if result.passed else 0.0,
            comment=result.summary(),
        )

        # Post per-assertion scores
        for turn in result.turns:
            for assertion in turn.assertions:
                client.score(
                    trace_id=trace_id,
                    name=f"eval:turn{turn.turn}:{assertion.name}",
                    value=1.0 if assertion.passed else 0.0,
                    comment=assertion.detail,
                )

        client.flush()

    except Exception:
        logger.exception("Failed to post scores to Langfuse for session %s", session_id)
```

- [ ] **Step 3: Run tests**

```bash
pytest tests/unit/eval/test_langfuse_scorer.py -v
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add src/autobots_devtools_shared_lib/eval/scoring/ tests/unit/eval/test_langfuse_scorer.py
git commit -m "feat(eval): add Langfuse score posting for eval results"
```

---

## Task 10: Pytest Plugin + Fixtures

**Files:**
- Create: `shared-lib/src/autobots_devtools_shared_lib/eval/pytest_plugin/plugin.py`
- Create: `shared-lib/src/autobots_devtools_shared_lib/eval/pytest_plugin/fixtures.py`
- Create: `shared-lib/src/autobots_devtools_shared_lib/eval/pytest_plugin/reporting.py`
- Test: `shared-lib/tests/unit/eval/test_plugin.py`
- Test: `shared-lib/tests/unit/eval/test_reporting.py`

- [ ] **Step 1: Write failing tests for plugin**

Create `tests/unit/eval/test_plugin.py`:

```python
# ABOUTME: Tests for the pytest plugin option registration.
# ABOUTME: Validates CLI options are added and markers are registered.


def test_plugin_registers_options(pytestconfig):
    """Plugin should register --eval-dir, --eval-tags, etc."""
    # These will only work if the plugin is installed
    # For unit testing, just verify the module imports
    from autobots_devtools_shared_lib.eval.pytest_plugin.plugin import pytest_addoption

    assert callable(pytest_addoption)


def test_plugin_registers_markers():
    from autobots_devtools_shared_lib.eval.pytest_plugin.plugin import pytest_configure

    assert callable(pytest_configure)
```

- [ ] **Step 2: Write failing tests for reporting**

Create `tests/unit/eval/test_reporting.py`:

```python
# ABOUTME: Tests for cost report JSON writing and terminal summary.
# ABOUTME: Validates report format and file output.

import json
from pathlib import Path

from autobots_devtools_shared_lib.eval.models.cost import (
    CostReport,
    TokenAttribution,
    TurnCost,
)
from autobots_devtools_shared_lib.eval.models.result import EvalResult
from autobots_devtools_shared_lib.eval.pytest_plugin.reporting import (
    format_terminal_summary,
    write_cost_report,
)


def _make_report() -> CostReport:
    return CostReport(
        eval_name="test eval",
        agent="coordinator",
        turns=[
            TurnCost(
                turn=1,
                model="gemini-2.0-flash",
                input_tokens=3200,
                output_tokens=600,
                cost_usd=0.035,
                latency_ms=1200,
                attribution=TokenAttribution(
                    system_prompt_tokens=800,
                    conversation_history_tokens=150,
                    tool_result_tokens=2100,
                    tools=[],
                    overhead_tokens=150,
                ),
            )
        ],
        total_input_tokens=3200,
        total_output_tokens=600,
        total_cost_usd=0.035,
        total_latency_ms=1200,
        llm_calls=1,
        lowest_utilization_tools=[],
        recommendations=[],
    )


def test_write_cost_report_creates_json(tmp_path):
    report_path = tmp_path / "report.json"
    results = [
        EvalResult(name="test", passed=True, turns=[], cost_report=_make_report())
    ]
    write_cost_report(str(report_path), results)
    assert report_path.exists()
    data = json.loads(report_path.read_text())
    assert "summary" in data
    assert "evals" in data


def test_terminal_summary_format():
    results = [
        EvalResult(name="test", passed=True, turns=[], cost_report=_make_report())
    ]
    summary = format_terminal_summary(results)
    assert "eval cost summary" in summary.lower() or "total" in summary.lower()
```

- [ ] **Step 3: Implement plugin.py**

Create `src/autobots_devtools_shared_lib/eval/pytest_plugin/plugin.py`:

```python
# ABOUTME: Pytest plugin for the dynagent eval framework.
# ABOUTME: Registers CLI options, markers, and session-level cost report generation.

from __future__ import annotations

import pytest

from autobots_devtools_shared_lib.eval.pytest_plugin.reporting import (
    format_terminal_summary,
    write_cost_report,
)


def pytest_addoption(parser: pytest.Parser) -> None:
    """Register eval-specific CLI options."""
    group = parser.getgroup("dynagent-eval", "Dynagent eval framework options")
    group.addoption(
        "--eval-dir",
        default="evals",
        help="Root directory for eval YAML files (default: evals)",
    )
    group.addoption(
        "--eval-tags",
        default=None,
        help="Only run evals matching these tags (comma-separated)",
    )
    group.addoption(
        "--eval-cost-report",
        default=None,
        help="Path to write cost report JSON",
    )
    group.addoption(
        "--eval-cost-deep",
        action="store_true",
        default=False,
        help="Enable Level 2 utilization analysis (requires extra LLM calls)",
    )
    group.addoption(
        "--eval-no-langfuse-score",
        action="store_true",
        default=False,
        help="Skip posting scores to Langfuse",
    )


def pytest_configure(config: pytest.Config) -> None:
    """Register eval markers."""
    config.addinivalue_line("markers", "eval: marks a test as a dynagent eval")
    config.addinivalue_line("markers", "eval_linear: marks a linear mode eval")
    config.addinivalue_line("markers", "eval_goal: marks a goal-based eval")


def pytest_sessionfinish(session: pytest.Session, exitstatus: int) -> None:
    """Write cost report at end of test session."""
    eval_results = getattr(session.config, "_eval_cost_reports", None)
    if not eval_results:
        return

    report_path = session.config.getoption("--eval-cost-report", default=None)
    if report_path:
        write_cost_report(report_path, eval_results)

    # Print terminal summary
    summary = format_terminal_summary(eval_results)
    if summary:
        print(summary)  # noqa: T201
```

- [ ] **Step 4: Implement fixtures.py**

Create `src/autobots_devtools_shared_lib/eval/pytest_plugin/fixtures.py`:

```python
# ABOUTME: Pytest fixtures for the dynagent eval framework.
# ABOUTME: Provides dynagent_eval fixture that runs eval cases and collects results.

from __future__ import annotations

import uuid
from typing import Any

import pytest
from langchain_core.runnables import RunnableConfig

from autobots_devtools_shared_lib.common.observability.trace_metadata import TraceMetadata
from autobots_devtools_shared_lib.eval.core.cost_tracker import query_langfuse
from autobots_devtools_shared_lib.eval.core.runner import run_linear_eval
from autobots_devtools_shared_lib.eval.models.eval_case import EvalCase
from autobots_devtools_shared_lib.eval.models.result import EvalResult
from autobots_devtools_shared_lib.eval.scoring.langfuse_scorer import post_scores


@pytest.fixture
def dynagent_eval(request: pytest.FixtureRequest):
    """Core eval fixture. Runs an EvalCase and returns EvalResult.

    Handles:
    - Session/thread ID generation
    - TraceMetadata creation with eval tags
    - Running the eval (linear mode in Phase 1)
    - Cost report collection (if tracking enabled)
    - Langfuse score posting (unless --eval-no-langfuse-score)
    """
    post_langfuse = not request.config.getoption("--eval-no-langfuse-score", default=False)

    async def run(eval_case: EvalCase) -> EvalResult:
        session_id = str(uuid.uuid4())
        config: RunnableConfig = {
            "configurable": {
                "thread_id": session_id,
                "agent_name": eval_case.agent,
            }
        }
        trace_metadata = TraceMetadata(
            session_id=session_id,
            app_name=f"eval-{eval_case.agent}",
            tags=["eval", *eval_case.tags],
        )

        if eval_case.mode == "linear":
            result = await run_linear_eval(eval_case, config, trace_metadata)
        else:
            # Goal mode added in Phase 3
            result = EvalResult(
                name=eval_case.name,
                passed=False,
                turns=[],
                cost_report=None,
                error="Goal-based mode not yet implemented (Phase 3)",
            )

        # Collect cost report
        if eval_case.cost.track:
            cost_report = query_langfuse(session_id)
            if cost_report:
                cost_report.eval_name = eval_case.name
                cost_report.agent = eval_case.agent
                result.cost_report = cost_report

        # Post scores to Langfuse
        if post_langfuse:
            post_scores(session_id, result)

        # Stash for session-level report
        if not hasattr(request.config, "_eval_cost_reports"):
            request.config._eval_cost_reports = []
        request.config._eval_cost_reports.append(result)

        return result

    return run
```

- [ ] **Step 5: Implement reporting.py**

Create `src/autobots_devtools_shared_lib/eval/pytest_plugin/reporting.py`:

```python
# ABOUTME: Cost report generation for eval results.
# ABOUTME: Writes JSON reports and formats terminal summaries.

from __future__ import annotations

import json
import logging
from dataclasses import asdict
from datetime import datetime, timezone
from pathlib import Path

from autobots_devtools_shared_lib.eval.models.result import EvalResult

logger = logging.getLogger(__name__)


def write_cost_report(path: str, results: list[EvalResult]) -> None:
    """Write eval cost report as JSON.

    Args:
        path: File path for the JSON report.
        results: List of EvalResult objects from the test session.
    """
    report_path = Path(path)
    report_path.parent.mkdir(parents=True, exist_ok=True)

    total_cost = sum(
        r.cost_report.total_cost_usd for r in results if r.cost_report
    )
    total_tokens = sum(
        r.cost_report.total_input_tokens + r.cost_report.total_output_tokens
        for r in results
        if r.cost_report
    )

    report = {
        "timestamp": datetime.now(tz=timezone.utc).isoformat(),
        "summary": {
            "total_evals": len(results),
            "passed": sum(1 for r in results if r.passed),
            "failed": sum(1 for r in results if not r.passed),
            "total_cost_usd": round(total_cost, 6),
            "total_tokens": total_tokens,
        },
        "evals": [],
    }

    for r in results:
        eval_entry: dict = {
            "name": r.name,
            "passed": r.passed,
        }
        if r.cost_report:
            eval_entry["cost"] = {
                "total_input_tokens": r.cost_report.total_input_tokens,
                "total_output_tokens": r.cost_report.total_output_tokens,
                "total_cost_usd": round(r.cost_report.total_cost_usd, 6),
                "llm_calls": r.cost_report.llm_calls,
            }
            if r.cost_report.recommendations:
                eval_entry["recommendations"] = r.cost_report.recommendations
        report["evals"].append(eval_entry)

    report_path.write_text(json.dumps(report, indent=2))
    logger.info("Cost report written to %s", path)


def format_terminal_summary(results: list[EvalResult]) -> str:
    """Format a terminal-friendly cost summary.

    Args:
        results: List of EvalResult objects from the test session.

    Returns:
        Formatted string for terminal output.
    """
    has_cost = any(r.cost_report for r in results)
    if not has_cost:
        return ""

    total_cost = sum(
        r.cost_report.total_cost_usd for r in results if r.cost_report
    )
    total_evals = len(results)
    passed = sum(1 for r in results if r.passed)
    failed = total_evals - passed

    lines = [
        "",
        "=" * 60,
        f" Eval cost summary: ${total_cost:.4f} across {total_evals} evals"
        f" ({passed} passed, {failed} failed)",
        "=" * 60,
    ]

    # Collect recommendations
    all_recs = []
    for r in results:
        if r.cost_report and r.cost_report.recommendations:
            all_recs.extend(r.cost_report.recommendations)

    if all_recs:
        lines.append("")
        lines.append("Recommendations:")
        for rec in all_recs:
            lines.append(f"  -> {rec}")

    lines.append("=" * 60)
    return "\n".join(lines)
```

- [ ] **Step 6: Run all tests**

```bash
pytest tests/unit/eval/test_plugin.py tests/unit/eval/test_reporting.py -v
```

Expected: PASS.

- [ ] **Step 7: Lint and type check**

```bash
make lint && make type-check
```

- [ ] **Step 8: Commit**

```bash
git add src/autobots_devtools_shared_lib/eval/pytest_plugin/ tests/unit/eval/
git commit -m "feat(eval): add pytest plugin with fixtures and cost reporting"
```

---

## Task 11: Public API (__init__.py)

**Files:**
- Modify: `shared-lib/src/autobots_devtools_shared_lib/eval/__init__.py`

- [ ] **Step 1: Wire up public exports**

Update `src/autobots_devtools_shared_lib/eval/__init__.py`:

```python
# ABOUTME: Public API for the dynagent eval framework.
# ABOUTME: Import from here for a stable surface — loader, models, and result types.

from autobots_devtools_shared_lib.eval.assertions.registry import register_assertion
from autobots_devtools_shared_lib.eval.core.loader import EvalConfigError, load_eval_cases
from autobots_devtools_shared_lib.eval.models.cost import CostReport
from autobots_devtools_shared_lib.eval.models.eval_case import EvalCase
from autobots_devtools_shared_lib.eval.models.result import (
    AgentOutput,
    AssertionResult,
    EvalResult,
    TurnResult,
)

__all__ = [
    "AgentOutput",
    "AssertionResult",
    "CostReport",
    "EvalCase",
    "EvalConfigError",
    "EvalResult",
    "TurnResult",
    "load_eval_cases",
    "register_assertion",
]
```

- [ ] **Step 2: Verify import works**

```bash
python -c "from autobots_devtools_shared_lib.eval import load_eval_cases, EvalCase, EvalResult; print('OK')"
```

- [ ] **Step 3: Run all eval tests**

```bash
pytest tests/unit/eval/ -v
```

Expected: all PASS.

- [ ] **Step 4: Run full project checks**

```bash
make lint && make type-check && make test-fast
```

- [ ] **Step 5: Commit**

```bash
git add src/autobots_devtools_shared_lib/eval/__init__.py
git commit -m "feat(eval): wire up public API exports"
```

---

## Task 12: Integration Verification

Run the full test suite and quality checks to ensure the eval framework doesn't break existing code.

- [ ] **Step 1: Run all tests from shared-lib**

```bash
cd /Users/pralhad/work/src/ws-autobots/autobots-devtools-shared-lib
make test-fast
```

Expected: all existing tests still pass + all new eval tests pass.

- [ ] **Step 2: Run lint and type check**

```bash
make lint && make type-check
```

- [ ] **Step 3: Verify pytest plugin is discoverable**

```bash
pytest --co -q 2>&1 | head -20
```

The plugin should load without errors.

- [ ] **Step 4: Create a final summary commit if any fixups were needed**

```bash
git add -A
git status
# Only commit if there are changes
git commit -m "fix(eval): address lint/type-check issues from integration verification"
```
