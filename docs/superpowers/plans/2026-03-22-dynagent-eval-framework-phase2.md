# Dynagent Eval Framework — Phase 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add LLM-as-judge assertions, Level 2 cost utilization analysis, `--eval-cost-deep` flag support, and retry logic for flaky assertions — building on the Phase 1 foundation.

**Architecture:** A new `llm_judge.py` module wraps OpenEvals `create_llm_as_judge` for criteria-based evaluation. The existing `cost_tracker.py` gains `analyze_tool_utilization()` for per-tool LLM scoring plus a `deep: bool` flag on `query_langfuse()` to run Level 2 analysis. The runner gains retry support for assertion types listed in `RetryConfig.only_for`, and respects `assertion.on_judge_error` to convert inconclusive results to warnings. All new assertions are registered in the existing registry.

**Tech Stack:** Python 3.12, OpenEvals (`create_llm_as_judge`), LangChain `init_chat_model`, Langfuse SDK, tiktoken, pytest

**Spec:** `docs/superpowers/specs/2026-03-22-dynagent-eval-framework-design.md` — Phase 2 (Section 15)

**Out of scope for this plan:** The spec's Phase 2 also mentions "Updated nurture evals with LLM judge assertions" — this involves adding `llm_judge` assertions to MER eval YAML files in `autobots-agents-mer/`. That work lives in a separate repo and will be a follow-up task after Phase 2 framework code is merged.

---

## File Structure

All files live under `autobots-devtools-shared-lib/` (abbreviated as `shared-lib/` below).

| File | Responsibility |
|------|----------------|
| `shared-lib/src/autobots_devtools_shared_lib/eval/assertions/llm_judge.py` | `llm_judge` and `trajectory_quality` assertion functions wrapping OpenEvals |
| `shared-lib/src/autobots_devtools_shared_lib/eval/assertions/registry.py` | **Modify:** wire `llm_judge` and `trajectory_quality` into registry |
| `shared-lib/src/autobots_devtools_shared_lib/eval/core/cost_tracker.py` | **Modify:** add `analyze_tool_utilization()` + `deep` parameter to `query_langfuse()` for Level 2 utilization |
| `shared-lib/src/autobots_devtools_shared_lib/eval/core/runner.py` | **Modify:** add retry logic for flaky assertions |
| `shared-lib/src/autobots_devtools_shared_lib/eval/models/eval_case.py` | **Modify:** add `on_judge_error` field to `Assertion` model |
| `shared-lib/src/autobots_devtools_shared_lib/eval/pytest_plugin/fixtures.py` | **Modify:** pass `--eval-cost-deep` flag to cost tracker |
| `shared-lib/src/autobots_devtools_shared_lib/eval/__init__.py` | **Modify:** no changes needed (existing exports sufficient) |

Tests:

| File | What it tests |
|------|---------------|
| `shared-lib/tests/unit/eval/test_llm_judge.py` | LLM judge assertion functions with mocked OpenEvals |
| `shared-lib/tests/unit/eval/test_registry.py` | **Modify:** add `llm_judge` and `trajectory_quality` to builtin list |
| `shared-lib/tests/unit/eval/test_cost_tracker_deep.py` | Level 2 utilization analysis with mocked LLM |
| `shared-lib/tests/unit/eval/test_runner_retry.py` | Retry logic for flaky assertions |
| `shared-lib/tests/unit/eval/test_eval_case_models.py` | **Modify:** add test for `on_judge_error` field |

---

## Conventions

- **Imports**: Use full package paths (`from autobots_devtools_shared_lib.eval.assertions.llm_judge import llm_judge`)
- **File headers**: Each file starts with `# ABOUTME:` comments (2 lines)
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

## Task 1: Add `on_judge_error` to Assertion Model

**Files:**
- Modify: `shared-lib/src/autobots_devtools_shared_lib/eval/models/eval_case.py`
- Modify: `shared-lib/tests/unit/eval/test_eval_case_models.py`

LLM-as-judge assertions can fail due to LLM errors (timeouts, rate limits). The YAML schema allows `on_judge_error: warn` (default) or `on_judge_error: fail`. This field lives on the `Assertion` model since it's parsed from the YAML assertion config dict.

- [ ] **Step 1: Write failing test for `on_judge_error` parsing**

Add to `tests/unit/eval/test_eval_case_models.py`:

```python
def test_assertion_on_judge_error_default():
    """on_judge_error defaults to 'warn' when not specified."""
    a = Assertion.model_validate({"llm_judge": {"criteria": "Is it good?", "threshold": 0.8}})
    assert a.on_judge_error == "warn"


def test_assertion_on_judge_error_explicit():
    """on_judge_error can be set to 'fail'."""
    a = Assertion.model_validate({
        "llm_judge": {"criteria": "Is it good?", "threshold": 0.8, "on_judge_error": "fail"}
    })
    assert a.on_judge_error == "fail"


def test_assertion_on_judge_error_invalid():
    """on_judge_error rejects invalid values."""
    with pytest.raises(ValidationError):
        Assertion.model_validate({
            "llm_judge": {"criteria": "Is it good?", "on_judge_error": "ignore"}
        })
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /Users/pralhad/work/src/ws-autobots/autobots-devtools-shared-lib
source /Users/pralhad/work/src/ws-autobots/.venv/bin/activate
pytest tests/unit/eval/test_eval_case_models.py::test_assertion_on_judge_error_default -v
```

Expected: FAIL — `AttributeError: 'Assertion' object has no attribute 'on_judge_error'`

- [ ] **Step 3: Implement `on_judge_error` on Assertion model**

In `src/autobots_devtools_shared_lib/eval/models/eval_case.py`, update the `Assertion` class:

```python
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
    on_judge_error: Literal["warn", "fail"] = "warn"

    @model_validator(mode="before")
    @classmethod
    def parse_yaml_dict(cls, data: Any) -> dict[str, Any]:
        if isinstance(data, dict) and "name" not in data:
            if len(data) != 1:
                msg = f"Assertion must have exactly one key, got {list(data.keys())}"
                raise ValueError(msg)
            name, config = next(iter(data.items()))
            result: dict[str, Any] = {"name": name, "config": config}
            # Extract on_judge_error from dict config if present (without mutating input)
            if isinstance(config, dict) and "on_judge_error" in config:
                result["on_judge_error"] = config["on_judge_error"]
                result["config"] = {k: v for k, v in config.items() if k != "on_judge_error"}
            return result
        return data
```

Note: the `on_judge_error` key is extracted from the config dict and moved to the top-level field so the config dict passed to assertion functions is clean.

- [ ] **Step 4: Run tests to verify they pass**

```bash
pytest tests/unit/eval/test_eval_case_models.py -v
```

Expected: all tests PASS (both new and existing).

- [ ] **Step 5: Lint and type check**

```bash
make lint && make type-check
```

- [ ] **Step 6: Commit**

```bash
git add src/autobots_devtools_shared_lib/eval/models/eval_case.py tests/unit/eval/test_eval_case_models.py
git commit -m "feat(eval): add on_judge_error field to Assertion model for LLM judge error handling"
```

---

## Task 2: LLM-as-Judge Assertion (`llm_judge`)

**Files:**
- Create: `shared-lib/src/autobots_devtools_shared_lib/eval/assertions/llm_judge.py`
- Test: `shared-lib/tests/unit/eval/test_llm_judge.py`

The `llm_judge` assertion wraps OpenEvals `create_llm_as_judge` to evaluate free-text agent responses against criteria. Config shape from YAML:

```yaml
- llm_judge:
    criteria: "Response contains a valid list of domain models"
    threshold: 0.8  # optional, default 0.5
```

The function uses `continuous=True` so OpenEvals returns a float score (0.0–1.0). It compares against the threshold. The judge model is `gemini-2.0-flash` via LangChain `init_chat_model` (cheap, fast for judging).

- [ ] **Step 1: Write failing tests**

Create `tests/unit/eval/test_llm_judge.py`:

```python
# ABOUTME: Tests for LLM-as-judge assertion functions.
# ABOUTME: Uses mocked OpenEvals evaluator to verify scoring logic and error handling.

from unittest.mock import MagicMock, patch

import pytest
from langchain_core.messages import AIMessage, HumanMessage

from autobots_devtools_shared_lib.eval.assertions.llm_judge import llm_judge
from autobots_devtools_shared_lib.eval.models.result import AgentOutput


def _make_output(content: str) -> AgentOutput:
    """Helper to build AgentOutput with a simple AI message."""
    return AgentOutput(
        messages=[HumanMessage(content="test"), AIMessage(content=content)],
        structured_response=None,
        agent_name="test",
        raw_state={},
    )


def test_llm_judge_passes_above_threshold():
    mock_evaluator = MagicMock(return_value={"score": 0.9, "reasoning": "Good response"})
    with patch(
        "autobots_devtools_shared_lib.eval.assertions.llm_judge.create_llm_as_judge",
        return_value=mock_evaluator,
    ):
        output = _make_output("Here are the models: Party, Address, Contact")
        result = llm_judge(output, {"criteria": "Lists domain models", "threshold": 0.8})
        assert result.passed is True
        assert "0.9" in result.detail


def test_llm_judge_fails_below_threshold():
    mock_evaluator = MagicMock(return_value={"score": 0.3, "reasoning": "Incomplete"})
    with patch(
        "autobots_devtools_shared_lib.eval.assertions.llm_judge.create_llm_as_judge",
        return_value=mock_evaluator,
    ):
        output = _make_output("I don't know")
        result = llm_judge(output, {"criteria": "Lists domain models", "threshold": 0.8})
        assert result.passed is False
        assert "0.3" in result.detail


def test_llm_judge_default_threshold():
    """Default threshold is 0.5."""
    mock_evaluator = MagicMock(return_value={"score": 0.6, "reasoning": "Decent"})
    with patch(
        "autobots_devtools_shared_lib.eval.assertions.llm_judge.create_llm_as_judge",
        return_value=mock_evaluator,
    ):
        output = _make_output("Some response")
        result = llm_judge(output, {"criteria": "Is it helpful?"})
        assert result.passed is True


def test_llm_judge_error_returns_inconclusive():
    """When the judge LLM fails, return inconclusive result."""
    mock_evaluator = MagicMock(side_effect=RuntimeError("LLM timeout"))
    with patch(
        "autobots_devtools_shared_lib.eval.assertions.llm_judge.create_llm_as_judge",
        return_value=mock_evaluator,
    ):
        output = _make_output("Some response")
        result = llm_judge(output, {"criteria": "Is it good?"})
        assert result.passed is False
        assert result.inconclusive is True
        assert "LLM timeout" in result.detail


def test_llm_judge_string_config():
    """Simple string config treated as criteria with default threshold."""
    mock_evaluator = MagicMock(return_value={"score": 0.8, "reasoning": "Good"})
    with patch(
        "autobots_devtools_shared_lib.eval.assertions.llm_judge.create_llm_as_judge",
        return_value=mock_evaluator,
    ):
        output = _make_output("Response")
        result = llm_judge(output, "Is the response helpful?")
        assert result.passed is True
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
pytest tests/unit/eval/test_llm_judge.py -v
```

Expected: FAIL — `ModuleNotFoundError: No module named 'autobots_devtools_shared_lib.eval.assertions.llm_judge'`

- [ ] **Step 3: Implement llm_judge.py**

Create `src/autobots_devtools_shared_lib/eval/assertions/llm_judge.py`:

```python
# ABOUTME: LLM-as-judge assertion functions wrapping OpenEvals.
# ABOUTME: Evaluates free-text agent responses against criteria using an LLM judge.

from __future__ import annotations

import logging
from typing import Any

from openevals.llm import create_llm_as_judge

from autobots_devtools_shared_lib.eval.models.result import AgentOutput, AssertionResult

logger = logging.getLogger(__name__)

# Default judge model — cheap and fast for evaluation
_DEFAULT_JUDGE_MODEL = "google_genai/gemini-2.0-flash"

_LLM_JUDGE_PROMPT = """You are evaluating an AI agent's response.

Criteria: {criteria}

Agent response:
{outputs}

Rate how well the response meets the criteria on a scale from 0.0 to 1.0."""


def _last_ai_content(agent_output: AgentOutput) -> str:
    """Extract text content from the last AI message."""
    for msg in reversed(agent_output.messages):
        if hasattr(msg, "type") and msg.type == "ai" and msg.content:
            return str(msg.content)
    return ""


def llm_judge(agent_output: AgentOutput, config: Any) -> AssertionResult:
    """Evaluate agent response against criteria using an LLM judge.

    Config can be:
      - str: criteria string (threshold defaults to 0.5)
      - dict: {"criteria": str, "threshold": float, "model": str (optional)}
    """
    if isinstance(config, str):
        criteria = config
        threshold = 0.5
        model = _DEFAULT_JUDGE_MODEL
    elif isinstance(config, dict):
        criteria = config.get("criteria", "")
        threshold = config.get("threshold", 0.5)
        model = config.get("model", _DEFAULT_JUDGE_MODEL)
    else:
        return AssertionResult(
            passed=False,
            name="llm_judge",
            detail=f"Invalid config type: {type(config).__name__}",
        )

    if not criteria:
        return AssertionResult(
            passed=False,
            name="llm_judge",
            detail="No criteria specified",
        )

    agent_text = _last_ai_content(agent_output)

    try:
        evaluator = create_llm_as_judge(
            prompt=_LLM_JUDGE_PROMPT,
            model=model,
            continuous=True,
            feedback_key="score",
        )

        result = evaluator(
            outputs=agent_text,
            criteria=criteria,
        )

        score = float(result.get("score", 0.0))
        reasoning = result.get("reasoning", "")
        passed = score >= threshold

        return AssertionResult(
            passed=passed,
            name="llm_judge",
            detail=f"Score: {score:.2f} (threshold: {threshold}). {reasoning}",
        )

    except Exception as e:
        logger.warning("LLM judge failed: %s", e)
        return AssertionResult(
            passed=False,
            name="llm_judge",
            detail=f"Judge error: {type(e).__name__}: {e}",
            inconclusive=True,
        )
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
pytest tests/unit/eval/test_llm_judge.py -v
```

Expected: all PASS.

- [ ] **Step 5: Lint and type check**

```bash
make lint && make type-check
```

- [ ] **Step 6: Commit**

```bash
git add src/autobots_devtools_shared_lib/eval/assertions/llm_judge.py tests/unit/eval/test_llm_judge.py
git commit -m "feat(eval): add LLM-as-judge assertion wrapping OpenEvals"
```

---

## Task 3: Wire LLM Judge into Registry

**Files:**
- Modify: `shared-lib/src/autobots_devtools_shared_lib/eval/assertions/registry.py`
- Modify: `shared-lib/tests/unit/eval/test_registry.py`

- [ ] **Step 1: Update test to include `llm_judge` and `trajectory_quality` in builtins list**

In `tests/unit/eval/test_registry.py`, update `test_resolve_all_builtins`:

```python
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
        "llm_judge",
        "trajectory_quality",
    ]
    for name in builtins:
        fn = resolve_assertion(name)
        assert callable(fn), f"{name} not callable"
```

- [ ] **Step 2: Run test to verify it fails**

```bash
pytest tests/unit/eval/test_registry.py::test_resolve_all_builtins -v
```

Expected: FAIL — `KeyError: "Unknown assertion 'llm_judge'"`

- [ ] **Step 3: Update registry.py to register `llm_judge` and `trajectory_quality`**

In `src/autobots_devtools_shared_lib/eval/assertions/registry.py`, update `_register_builtins`:

```python
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
    from autobots_devtools_shared_lib.eval.assertions.llm_judge import (
        llm_judge,
        trajectory_quality,
    )

    _REGISTRY.update(
        {
            "contains": contains,
            "regex": regex,
            "exact_match": exact_match,
            "json_match": json_match,
            "response_matches_schema": schema_match,
            "tool_called": tool_called,
            "tool_sequence": tool_sequence,
            "no_extra_tools": no_extra_tools,
            "tools_unordered": tools_unordered,
            "llm_judge": llm_judge,
            "trajectory_quality": trajectory_quality,
        }
    )
```

Note: `trajectory_quality` will be implemented in llm_judge.py in Task 4.

- [ ] **Step 4: Run test — it will fail** (trajectory_quality doesn't exist yet)

This is expected. Do NOT commit yet — proceed to Task 4 to implement trajectory_quality, then both registry + trajectory_quality will be committed together.

---

## Task 4: Trajectory Quality Assertion + Registry Commit

> **Note on implementation approach:** The spec references OpenEvals `trajectory.llm`. The installed version (openevals 0.1.3) has no trajectory-specific evaluators. This task uses `create_llm_as_judge` with a custom trajectory-formatting prompt, which is functionally equivalent. When OpenEvals adds native trajectory evaluation, this can be upgraded without changing the YAML schema or test contracts.

**Files:**
- Modify: `shared-lib/src/autobots_devtools_shared_lib/eval/assertions/llm_judge.py`
- Modify: `shared-lib/tests/unit/eval/test_llm_judge.py`

The `trajectory_quality` assertion evaluates the overall quality of an agent's tool usage trajectory (not just the final response). It uses the full message history including tool calls.

- [ ] **Step 1: Add failing tests for trajectory_quality**

Add to `tests/unit/eval/test_llm_judge.py`:

```python
from autobots_devtools_shared_lib.eval.assertions.llm_judge import trajectory_quality


def test_trajectory_quality_passes():
    mock_evaluator = MagicMock(return_value={"score": 0.85, "reasoning": "Good tool usage"})
    with patch(
        "autobots_devtools_shared_lib.eval.assertions.llm_judge.create_llm_as_judge",
        return_value=mock_evaluator,
    ):
        output = _make_output("Done")
        result = trajectory_quality(
            output, {"criteria": "Agent used tools efficiently", "threshold": 0.7}
        )
        assert result.passed is True


def test_trajectory_quality_fails():
    mock_evaluator = MagicMock(return_value={"score": 0.3, "reasoning": "Redundant tool calls"})
    with patch(
        "autobots_devtools_shared_lib.eval.assertions.llm_judge.create_llm_as_judge",
        return_value=mock_evaluator,
    ):
        output = _make_output("Done")
        result = trajectory_quality(
            output, {"criteria": "Agent used tools efficiently", "threshold": 0.7}
        )
        assert result.passed is False


def test_trajectory_quality_error_returns_inconclusive():
    mock_evaluator = MagicMock(side_effect=RuntimeError("LLM error"))
    with patch(
        "autobots_devtools_shared_lib.eval.assertions.llm_judge.create_llm_as_judge",
        return_value=mock_evaluator,
    ):
        output = _make_output("Done")
        result = trajectory_quality(output, {"criteria": "Efficient"})
        assert result.passed is False
        assert result.inconclusive is True
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
pytest tests/unit/eval/test_llm_judge.py::test_trajectory_quality_passes -v
```

Expected: FAIL — `ImportError: cannot import name 'trajectory_quality'`

- [ ] **Step 3: Implement trajectory_quality**

Add to `src/autobots_devtools_shared_lib/eval/assertions/llm_judge.py`:

```python
_TRAJECTORY_PROMPT = """You are evaluating an AI agent's tool usage trajectory.

Criteria: {criteria}

Full conversation (messages and tool calls):
{outputs}

Rate how well the agent's tool usage meets the criteria on a scale from 0.0 to 1.0.
Consider: Were tools used efficiently? Were there redundant calls? Was the sequence logical?"""


def _format_trajectory(agent_output: AgentOutput) -> str:
    """Format the full message history including tool calls for the judge."""
    lines: list[str] = []
    for msg in agent_output.messages:
        msg_type = getattr(msg, "type", "unknown")
        content = str(msg.content) if msg.content else ""

        if msg_type == "human":
            lines.append(f"[User]: {content}")
        elif msg_type == "ai":
            lines.append(f"[Agent]: {content}")
            tool_calls = getattr(msg, "tool_calls", None)
            if tool_calls:
                for tc in tool_calls:
                    if isinstance(tc, dict):
                        lines.append(f"  -> Tool call: {tc.get('name', '?')}({tc.get('args', {})})")
                    elif hasattr(tc, "name"):
                        lines.append(f"  -> Tool call: {tc.name}({getattr(tc, 'args', {})})")
        elif msg_type == "tool":
            tool_name = getattr(msg, "name", "?")
            lines.append(f"[Tool result ({tool_name})]: {content[:200]}...")
    return "\n".join(lines)


def trajectory_quality(agent_output: AgentOutput, config: Any) -> AssertionResult:
    """Evaluate the quality of an agent's tool usage trajectory.

    Config: {"criteria": str, "threshold": float (default 0.5), "model": str (optional)}
    """
    if isinstance(config, str):
        criteria = config
        threshold = 0.5
        model = _DEFAULT_JUDGE_MODEL
    elif isinstance(config, dict):
        criteria = config.get("criteria", "")
        threshold = config.get("threshold", 0.5)
        model = config.get("model", _DEFAULT_JUDGE_MODEL)
    else:
        return AssertionResult(
            passed=False,
            name="trajectory_quality",
            detail=f"Invalid config type: {type(config).__name__}",
        )

    if not criteria:
        return AssertionResult(
            passed=False,
            name="trajectory_quality",
            detail="No criteria specified",
        )

    trajectory_text = _format_trajectory(agent_output)

    try:
        evaluator = create_llm_as_judge(
            prompt=_TRAJECTORY_PROMPT,
            model=model,
            continuous=True,
            feedback_key="score",
        )

        result = evaluator(
            outputs=trajectory_text,
            criteria=criteria,
        )

        score = float(result.get("score", 0.0))
        reasoning = result.get("reasoning", "")
        passed = score >= threshold

        return AssertionResult(
            passed=passed,
            name="trajectory_quality",
            detail=f"Score: {score:.2f} (threshold: {threshold}). {reasoning}",
        )

    except Exception as e:
        logger.warning("Trajectory quality judge failed: %s", e)
        return AssertionResult(
            passed=False,
            name="trajectory_quality",
            detail=f"Judge error: {type(e).__name__}: {e}",
            inconclusive=True,
        )
```

- [ ] **Step 4: Run all LLM judge tests and registry tests**

```bash
pytest tests/unit/eval/test_llm_judge.py tests/unit/eval/test_registry.py -v
```

Expected: all PASS.

- [ ] **Step 5: Lint and type check**

```bash
make lint && make type-check
```

- [ ] **Step 6: Commit (includes Task 3 registry changes)**

```bash
git add src/autobots_devtools_shared_lib/eval/assertions/llm_judge.py src/autobots_devtools_shared_lib/eval/assertions/registry.py tests/unit/eval/test_llm_judge.py tests/unit/eval/test_registry.py
git commit -m "feat(eval): add trajectory_quality assertion and wire LLM judges into registry"
```

---

## Task 5: Retry Logic + `on_judge_error` Runtime Behavior

**Files:**
- Modify: `shared-lib/src/autobots_devtools_shared_lib/eval/core/runner.py`
- Create: `shared-lib/tests/unit/eval/test_runner_retry.py`

LLM-as-judge assertions are inherently flaky. The `RetryConfig` model already exists (from Phase 1) with `count` and `only_for` fields. The runner needs to:
1. Retry failed inconclusive assertions that match `only_for` names, up to `count` times.
2. After retries are exhausted, consult `assertion.on_judge_error`: if `"warn"` and the result is `inconclusive`, treat it as passed (warn-only). If `"fail"`, it remains failed.

- [ ] **Step 1: Write failing tests for retry logic**

Create `tests/unit/eval/test_runner_retry.py`:

```python
# ABOUTME: Tests for the eval runner retry logic.
# ABOUTME: Validates flaky assertion retry with count limits and only_for filtering.

from unittest.mock import AsyncMock, MagicMock, call, patch

import pytest
from langchain_core.messages import AIMessage, HumanMessage

from autobots_devtools_shared_lib.eval.core.runner import run_linear_eval
from autobots_devtools_shared_lib.eval.models.eval_case import (
    Assertion,
    CostConfig,
    EvalCase,
    RetryConfig,
    Turn,
)


def _make_eval_case_with_retry(
    assertions: list[dict],
    retry_count: int = 2,
    only_for: list[str] | None = None,
) -> EvalCase:
    return EvalCase(
        name="retry test",
        agent="coordinator",
        mode="linear",
        tags=["smoke"],
        state={"user_name": "test"},
        turns=[Turn(user="Hello", assertions=[Assertion.model_validate(a) for a in assertions])],
        cost=CostConfig(track=False),
        retry=RetryConfig(count=retry_count, only_for=only_for or ["llm_judge"]),
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


async def test_retry_flaky_assertion_eventually_passes(mock_invoke):
    """Assertion fails first, passes on retry."""
    call_count = 0

    def mock_llm_judge(agent_output, config):
        nonlocal call_count
        call_count += 1
        from autobots_devtools_shared_lib.eval.models.result import AssertionResult

        if call_count == 1:
            return AssertionResult(
                passed=False, name="llm_judge", detail="Fail first time", inconclusive=True
            )
        return AssertionResult(passed=True, name="llm_judge", detail="Pass on retry")

    with patch(
        "autobots_devtools_shared_lib.eval.core.runner.resolve_assertion",
        return_value=mock_llm_judge,
    ):
        case = _make_eval_case_with_retry(
            [{"llm_judge": {"criteria": "Is it good?", "threshold": 0.5}}],
            retry_count=2,
        )
        config = {"configurable": {"thread_id": "retry-1"}}
        result = await run_linear_eval(case, config, trace_metadata=None)
        assert result.passed is True
        assert call_count == 2


async def test_retry_exhausted_still_fails(mock_invoke):
    """Assertion fails on all retries."""
    from autobots_devtools_shared_lib.eval.models.result import AssertionResult

    def mock_llm_judge(agent_output, config):
        return AssertionResult(
            passed=False, name="llm_judge", detail="Always fails", inconclusive=True
        )

    with patch(
        "autobots_devtools_shared_lib.eval.core.runner.resolve_assertion",
        return_value=mock_llm_judge,
    ):
        case = _make_eval_case_with_retry(
            [{"llm_judge": {"criteria": "Is it good?"}}],
            retry_count=2,
        )
        config = {"configurable": {"thread_id": "retry-2"}}
        result = await run_linear_eval(case, config, trace_metadata=None)
        assert result.passed is False


async def test_no_retry_for_deterministic_assertions(mock_invoke):
    """Deterministic assertions (contains) are never retried even if they fail."""
    case = _make_eval_case_with_retry(
        [{"contains": "NotHere"}],
        retry_count=3,
        only_for=["llm_judge"],
    )
    config = {"configurable": {"thread_id": "retry-3"}}
    result = await run_linear_eval(case, config, trace_metadata=None)
    assert result.passed is False
    # ainvoke_agent called once (no retry for contains)
    assert mock_invoke.call_count == 1


async def test_no_retry_when_count_zero(mock_invoke):
    """No retries when retry count is 0."""
    case = EvalCase(
        name="no retry",
        agent="coordinator",
        mode="linear",
        tags=["smoke"],
        state={"user_name": "test"},
        turns=[Turn(user="Hello", assertions=[Assertion.model_validate({"contains": "NotHere"})])],
        cost=CostConfig(track=False),
        retry=RetryConfig(count=0, only_for=[]),
    )
    config = {"configurable": {"thread_id": "retry-4"}}
    result = await run_linear_eval(case, config, trace_metadata=None)
    assert result.passed is False


async def test_on_judge_error_warn_treats_inconclusive_as_pass(mock_invoke):
    """When on_judge_error='warn' and result is inconclusive after retries, treat as passed."""
    from autobots_devtools_shared_lib.eval.models.result import AssertionResult

    def mock_llm_judge(agent_output, config):
        return AssertionResult(
            passed=False, name="llm_judge", detail="Judge timeout", inconclusive=True
        )

    with patch(
        "autobots_devtools_shared_lib.eval.core.runner.resolve_assertion",
        return_value=mock_llm_judge,
    ):
        case = _make_eval_case_with_retry(
            [{"llm_judge": {"criteria": "Is it good?"}}],  # on_judge_error defaults to "warn"
            retry_count=1,
        )
        config = {"configurable": {"thread_id": "retry-5"}}
        result = await run_linear_eval(case, config, trace_metadata=None)
        # on_judge_error=warn + inconclusive → treated as pass
        assert result.passed is True
        # But the assertion detail should note it was inconclusive
        assert result.turns[0].assertions[0].inconclusive is True


async def test_on_judge_error_fail_keeps_inconclusive_as_fail(mock_invoke):
    """When on_judge_error='fail' and result is inconclusive, it remains failed."""
    from autobots_devtools_shared_lib.eval.models.result import AssertionResult

    def mock_llm_judge(agent_output, config):
        return AssertionResult(
            passed=False, name="llm_judge", detail="Judge timeout", inconclusive=True
        )

    with patch(
        "autobots_devtools_shared_lib.eval.core.runner.resolve_assertion",
        return_value=mock_llm_judge,
    ):
        case = _make_eval_case_with_retry(
            [{"llm_judge": {"criteria": "Is it good?", "on_judge_error": "fail"}}],
            retry_count=1,
        )
        config = {"configurable": {"thread_id": "retry-6"}}
        result = await run_linear_eval(case, config, trace_metadata=None)
        assert result.passed is False
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
pytest tests/unit/eval/test_runner_retry.py -v
```

Expected: FAIL — tests fail because retry logic doesn't exist yet in the runner.

- [ ] **Step 3: Implement retry logic in runner.py**

Modify `src/autobots_devtools_shared_lib/eval/core/runner.py`. Update the `_run_assertions` function to accept retry config and retry eligible failed assertions:

```python
def _run_assertions(
    agent_output: AgentOutput,
    assertions: list[Any],
    retry_count: int = 0,
    retry_only_for: list[str] | None = None,
) -> list[AssertionResult]:
    """Run all assertions against an agent output, with optional retry for flaky assertions."""
    results: list[AssertionResult] = []
    retry_names = set(retry_only_for) if retry_only_for else set()

    for assertion in assertions:
        try:
            eval_fn = resolve_assertion(assertion.name)
            result = eval_fn(agent_output, assertion.config)

            # Retry logic: retry failed inconclusive assertions if eligible
            if (
                not result.passed
                and result.inconclusive
                and retry_count > 0
                and assertion.name in retry_names
            ):
                for attempt in range(retry_count):
                    logger.info(
                        "Retrying %s (attempt %d/%d)", assertion.name, attempt + 1, retry_count
                    )
                    result = eval_fn(agent_output, assertion.config)
                    if result.passed:
                        break

            # on_judge_error handling: if still inconclusive after retries
            on_judge_error = getattr(assertion, "on_judge_error", "warn")
            if not result.passed and result.inconclusive and on_judge_error == "warn":
                # Treat as passed but keep inconclusive flag for reporting
                result = AssertionResult(
                    passed=True,
                    name=result.name,
                    detail=f"{result.detail} (treated as pass: on_judge_error=warn)",
                    inconclusive=True,
                )

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
```

And update the call site in `run_linear_eval` to pass retry config:

```python
            assertion_results = _run_assertions(
                agent_output,
                turn.assertions,
                retry_count=eval_case.retry.count,
                retry_only_for=eval_case.retry.only_for,
            )
```

- [ ] **Step 4: Run tests**

```bash
pytest tests/unit/eval/test_runner_retry.py tests/unit/eval/test_runner.py -v
```

Expected: all PASS (both new retry tests and existing runner tests).

- [ ] **Step 5: Lint and type check**

```bash
make lint && make type-check
```

- [ ] **Step 6: Commit**

```bash
git add src/autobots_devtools_shared_lib/eval/core/runner.py tests/unit/eval/test_runner_retry.py
git commit -m "feat(eval): add retry logic for flaky LLM-as-judge assertions"
```

---

## Task 6: Level 2 Cost Utilization Analysis

**Files:**
- Modify: `shared-lib/src/autobots_devtools_shared_lib/eval/core/cost_tracker.py`
- Create: `shared-lib/tests/unit/eval/test_cost_tracker_deep.py`

Level 2 analysis sends each tool result (>50 tokens) to an LLM judge that scores utilization (0.0–1.0), summarizes what the agent used, and recommends optimizations for low utilization (<0.5). Tool results >10000 tokens are auto-flagged without a judge call.

- [ ] **Step 1: Write failing tests for Level 2 analysis**

Create `tests/unit/eval/test_cost_tracker_deep.py`:

```python
# ABOUTME: Tests for Level 2 cost utilization analysis.
# ABOUTME: Validates LLM-based tool utilization scoring with mocked judge.

from unittest.mock import MagicMock, patch

from autobots_devtools_shared_lib.eval.core.cost_tracker import analyze_tool_utilization
from autobots_devtools_shared_lib.eval.models.cost import ToolAttribution


def test_analyze_skips_small_tool_results():
    """Tool results under 50 tokens are skipped (not worth analyzing)."""
    attr = ToolAttribution(
        tool_name="get_context",
        tool_input="key",
        result_tokens=30,
    )
    result = analyze_tool_utilization(attr, agent_output_text="Used the context")
    assert result.utilization is None
    assert result.recommendation is None


def test_analyze_auto_flags_huge_results():
    """Tool results over 10000 tokens are auto-flagged without judge call."""
    attr = ToolAttribution(
        tool_name="mer_read_file_tool(huge_file.md)",
        tool_input="huge_file.md",
        result_tokens=12000,
    )
    result = analyze_tool_utilization(attr, agent_output_text="Used a small part")
    assert result.utilization is not None
    assert result.utilization < 0.1
    assert result.recommendation is not None
    assert "too large" in result.recommendation.lower() or "12000" in result.recommendation


def test_analyze_calls_judge_for_medium_results():
    """Tool results between 50 and 10000 tokens are sent to the judge."""
    mock_evaluator = MagicMock(
        return_value={
            "score": 0.3,
            "reasoning": "Agent only used model names from a large document",
        }
    )
    with patch(
        "autobots_devtools_shared_lib.eval.core.cost_tracker.create_llm_as_judge",
        return_value=mock_evaluator,
    ):
        attr = ToolAttribution(
            tool_name="mer_read_file_tool(feature_lld.md)",
            tool_input="feature_lld.md",
            result_tokens=1900,
        )
        result = analyze_tool_utilization(
            attr,
            agent_output_text="Found models: Party, Address, Contact",
            tool_result_text="Long LLD document content here...",
        )
        assert result.utilization == 0.3
        assert result.used_content_summary is not None


def test_analyze_no_recommendation_for_high_utilization():
    """High utilization tools get no recommendation."""
    mock_evaluator = MagicMock(
        return_value={
            "score": 0.9,
            "reasoning": "Agent used most of the content",
        }
    )
    with patch(
        "autobots_devtools_shared_lib.eval.core.cost_tracker.create_llm_as_judge",
        return_value=mock_evaluator,
    ):
        attr = ToolAttribution(
            tool_name="set_context_tool",
            tool_input="data",
            result_tokens=100,
        )
        result = analyze_tool_utilization(
            attr,
            agent_output_text="Used all the context data",
            tool_result_text="Context data...",
        )
        assert result.utilization == 0.9
        assert result.recommendation is None


def test_analyze_judge_error_returns_unchanged():
    """If the judge fails, return the attribution unchanged."""
    mock_evaluator = MagicMock(side_effect=RuntimeError("Judge failed"))
    with patch(
        "autobots_devtools_shared_lib.eval.core.cost_tracker.create_llm_as_judge",
        return_value=mock_evaluator,
    ):
        attr = ToolAttribution(
            tool_name="mer_read_file_tool",
            tool_input="file.md",
            result_tokens=500,
        )
        result = analyze_tool_utilization(
            attr,
            agent_output_text="Output",
            tool_result_text="File content",
        )
        assert result.utilization is None
        assert result.recommendation is None
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
pytest tests/unit/eval/test_cost_tracker_deep.py -v
```

Expected: FAIL — `ImportError: cannot import name 'analyze_tool_utilization'`

- [ ] **Step 3: Implement `analyze_tool_utilization` in cost_tracker.py**

Add to `src/autobots_devtools_shared_lib/eval/core/cost_tracker.py`:

```python
from openevals.llm import create_llm_as_judge

_UTILIZATION_JUDGE_MODEL = "google_genai/gemini-2.0-flash"

_UTILIZATION_PROMPT = """You are analyzing token efficiency in an AI agent's tool usage.

The agent called the tool: {tool_name}
The tool returned this content ({result_tokens} tokens):
<tool_result>{tool_result}</tool_result>

The agent then produced this output:
<agent_output>{agent_output}</agent_output>

Rate the utilization on a scale from 0.0 to 1.0:
- 1.0 means the agent used all of the tool result
- 0.0 means the agent used none of the tool result

Consider what specific parts of the tool result the agent actually used in its output."""


def analyze_tool_utilization(
    attribution: ToolAttribution,
    agent_output_text: str,
    tool_result_text: str | None = None,
) -> ToolAttribution:
    """Analyze how much of a tool's result was actually used by the agent.

    Args:
        attribution: The tool attribution to analyze.
        agent_output_text: The agent's final output text.
        tool_result_text: The raw tool result text (if available).

    Returns:
        Updated ToolAttribution with utilization, summary, and recommendation.
    """
    # Skip small results — not worth analyzing
    if attribution.result_tokens < 50:
        return attribution

    # Auto-flag huge results without a judge call
    if attribution.result_tokens > 10000:
        attribution.utilization = 0.05
        attribution.used_content_summary = "Auto-flagged: tool result too large for efficient use"
        attribution.recommendation = (
            f"Tool result is {attribution.result_tokens} tokens — almost certainly wasteful. "
            f"Pre-filter or split the input to reduce token consumption."
        )
        return attribution

    # Truncate tool result for judge (head + tail if >4000 tokens)
    display_result = tool_result_text or "(tool result text not available)"
    if len(display_result) > 16000:  # rough 4000-token proxy
        half = 8000
        display_result = display_result[:half] + "\n...[truncated]...\n" + display_result[-half:]

    try:
        evaluator = create_llm_as_judge(
            prompt=_UTILIZATION_PROMPT,
            model=_UTILIZATION_JUDGE_MODEL,
            continuous=True,
            feedback_key="score",
        )

        result = evaluator(
            outputs=agent_output_text,
            tool_name=attribution.tool_name,
            result_tokens=str(attribution.result_tokens),
            tool_result=display_result,
            agent_output=agent_output_text,
        )

        score = float(result.get("score", 0.0))
        reasoning = result.get("reasoning", "")

        attribution.utilization = score
        attribution.used_content_summary = reasoning

        if score < 0.5:
            attribution.recommendation = (
                f"Utilization is {score:.0%} ({attribution.result_tokens} tokens). "
                f"{reasoning}"
            )

        return attribution

    except Exception:
        logger.warning(
            "Utilization analysis failed for %s", attribution.tool_name, exc_info=True
        )
        return attribution
```

- [ ] **Step 4: Run tests**

```bash
pytest tests/unit/eval/test_cost_tracker_deep.py tests/unit/eval/test_cost_tracker.py -v
```

Expected: all PASS (both new and existing).

- [ ] **Step 5: Lint and type check**

```bash
make lint && make type-check
```

- [ ] **Step 6: Commit**

```bash
git add src/autobots_devtools_shared_lib/eval/core/cost_tracker.py tests/unit/eval/test_cost_tracker_deep.py
git commit -m "feat(eval): add Level 2 cost utilization analysis with LLM judge"
```

---

## Task 7: Wire `--eval-cost-deep` into Fixtures

**Files:**
- Modify: `shared-lib/src/autobots_devtools_shared_lib/eval/pytest_plugin/fixtures.py`

The `--eval-cost-deep` CLI flag is already registered in the plugin (Phase 1). Now the fixture needs to pass it through so the cost tracker performs Level 2 analysis when enabled.

- [ ] **Step 1: Update fixtures.py to pass deep flag**

In `src/autobots_devtools_shared_lib/eval/pytest_plugin/fixtures.py`, update the `dynagent_eval` fixture:

```python
@pytest.fixture
def dynagent_eval(request: pytest.FixtureRequest):
    """Core eval fixture. Runs an EvalCase and returns EvalResult."""
    post_langfuse = not request.config.getoption("--eval-no-langfuse-score", default=False)
    cost_deep = request.config.getoption("--eval-cost-deep", default=False)

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
            result = EvalResult(
                name=eval_case.name,
                passed=False,
                turns=[],
                cost_report=None,
                error="Goal-based mode not yet implemented (Phase 3)",
            )

        # Collect cost report
        if eval_case.cost.track:
            cost_report = query_langfuse(session_id, deep=cost_deep)
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

- [ ] **Step 2: Add `deep` parameter to `query_langfuse`**

In `src/autobots_devtools_shared_lib/eval/core/cost_tracker.py`, update the function signature:

```python
def query_langfuse(session_id: str, partial: bool = False, deep: bool = False) -> CostReport | None:
```

When `deep=True`, after building the basic `CostReport`, iterate through tool attributions and call `analyze_tool_utilization` for each. This requires extracting tool result texts from the Langfuse observations (SPAN type observations that are children of GENERATION observations).

Add this logic at the end of `query_langfuse`, before the `return` statement:

```python
        # Level 2: deep utilization analysis
        if deep:
            for turn_cost in all_turns:
                for tool_attr in turn_cost.attribution.tools:
                    analyze_tool_utilization(
                        tool_attr,
                        agent_output_text="",  # populated from trace in production
                    )

            # Collect lowest utilization tools and recommendations
            all_tool_attrs = [
                t for tc in all_turns for t in tc.attribution.tools if t.utilization is not None
            ]
            low_util = [t for t in all_tool_attrs if t.utilization is not None and t.utilization < 0.5]
            low_util.sort(key=lambda t: t.utilization or 0.0)

            report = CostReport(
                eval_name="",
                agent="",
                turns=all_turns,
                total_input_tokens=total_input,
                total_output_tokens=total_output,
                total_cost_usd=total_cost,
                total_latency_ms=total_latency,
                llm_calls=llm_calls,
                lowest_utilization_tools=low_util[:5],
                recommendations=[t.recommendation for t in low_util if t.recommendation],
            )
            return report
```

- [ ] **Step 3: Run all eval tests**

```bash
pytest tests/unit/eval/ -v
```

Expected: all PASS.

- [ ] **Step 4: Lint and type check**

```bash
make lint && make type-check
```

- [ ] **Step 5: Commit**

```bash
git add src/autobots_devtools_shared_lib/eval/pytest_plugin/fixtures.py src/autobots_devtools_shared_lib/eval/core/cost_tracker.py
git commit -m "feat(eval): wire --eval-cost-deep flag through fixture to cost tracker"
```

---

## Task 8: Update Public API + Integration Verification

**Files:**
- No new files needed — existing `__init__.py` exports are sufficient
- Run full test suite + quality checks

- [ ] **Step 1: Verify import paths work**

```bash
cd /Users/pralhad/work/src/ws-autobots/autobots-devtools-shared-lib
source /Users/pralhad/work/src/ws-autobots/.venv/bin/activate
python -c "
from autobots_devtools_shared_lib.eval import load_eval_cases, EvalCase, EvalResult, register_assertion
from autobots_devtools_shared_lib.eval.assertions.llm_judge import llm_judge, trajectory_quality
from autobots_devtools_shared_lib.eval.core.cost_tracker import analyze_tool_utilization
print('All imports OK')
"
```

- [ ] **Step 2: Run all eval tests**

```bash
pytest tests/unit/eval/ -v
```

Expected: all existing tests still pass + all new tests pass.

- [ ] **Step 3: Run lint and type check**

```bash
make lint && make type-check
```

- [ ] **Step 4: Run full project test suite**

```bash
make test-fast
```

Expected: all tests pass.

- [ ] **Step 5: Verify pytest plugin loads without errors**

```bash
pytest --co -q 2>&1 | head -20
```

The plugin should load without import errors.

- [ ] **Step 6: Create a final commit if any fixups were needed**

```bash
git add -A
git status
# Only commit if there are changes
git commit -m "fix(eval): address lint/type-check issues from Phase 2 integration verification"
```
