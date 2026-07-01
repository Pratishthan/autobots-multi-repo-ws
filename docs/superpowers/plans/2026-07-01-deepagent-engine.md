# Deep Agent Engine (`create_base_deepagent`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a second, parallel dynagent engine — `create_base_deepagent`, wrapping deepagents' `create_deep_agent` — so open-ended AMA-style assistants can run alongside the existing deterministic Nurture pipeline.

**Architecture:** Mirror how `create_base_agent` wraps LangChain's `create_agent`. A new factory reads a domain's default agent (prompt + tools) from the existing `AgentMeta`/config plumbing, resolves the prompt once with `format_map`, and hands model/tools/prompt/state/checkpointer to `create_deep_agent`. deepagents supplies planning, virtual filesystem, sub-agents, summarization, and prompt-caching natively — so the deep engine deliberately does **not** attach `inject_agent` or our `SummarizationMiddleware`. Nurture and `create_base_agent` are untouched.

**Tech Stack:** Python 3.12+, `deepagents==0.6.12`, LangChain 1.3.x / LangGraph, Pydantic settings, pytest (`asyncio_mode = "auto"`), Ruff (line-length 100, double quotes), Pyright basic.

## Global Constraints

- Target dependency pins (shared venv — must satisfy all four repos): `deepagents==0.6.12`, `langchain>=1.3.11,<2.0.0`, `langchain-core>=1.4.8,<2.0.0`, `langchain-anthropic>=1.4.7,<2.0.0`, `langchain-google-genai>=4.2.5,<5.0.0`. `langgraph` is transitive and must resolve to a version exposing `langgraph.stream`.
- Do **not** modify `create_base_agent`, `inject_agent`, or the Nurture pipeline. The react engine and its tests must stay green.
- The deep engine must **not** re-add `SummarizationMiddleware` (deepagents ships its own).
- Deep-agent domains use a config file named `deep-agents.yaml` (not `agents.yaml`), selected via the `agents_config_filename` setting.
- Deep-engine state must subclass `deepagents.DeepAgentState` (not `Dynagent`).
- Code style: Ruff line-length 100, double quotes; every new module starts with two `# ABOUTME:` comment lines (existing convention). Type-check with Pyright basic.
- Commit from **inside each repo** (pre-commit hooks run there), not the workspace root.

---

### Task 1: Phase 0 — Dependency upgrade & workspace verification (BLOCKER)

Nothing else can proceed until deepagents imports. Root cause: the installed langchain stack (`langchain 1.2.13` / `langchain-core 1.2.20`) is *below* deepagents' floor, so the newer langgraph exposing `langgraph.stream` is never installed and `import deepagents` fails.

**Files:**
- Modify: `autobots-devtools-shared-lib/pyproject.toml` (dependencies block, lines ~14-32)
- Test: `autobots-devtools-shared-lib/tests/unit/test_deepagents_available.py` (create)
- Possibly modify: `autobots-agents-jarvis/pyproject.toml`, `autobots-agents-mer/pyproject.toml`, `autobots-agents-pay/pyproject.toml` (only if they cap langchain below 1.3.11)

**Interfaces:**
- Produces: an importable `deepagents` package (`from deepagents import create_deep_agent, DeepAgentState, SubAgent`) usable by all later tasks.

- [ ] **Step 1: Write the failing smoke test**

Create `autobots-devtools-shared-lib/tests/unit/test_deepagents_available.py`:

```python
# ABOUTME: Smoke test that the deepagents dependency is installed and importable.
# ABOUTME: Guards the Phase 0 langchain-stack upgrade that unblocks the deep engine.


def test_deepagents_imports():
    from deepagents import DeepAgentState, SubAgent, create_deep_agent

    assert create_deep_agent is not None
    assert DeepAgentState is not None
    assert SubAgent is not None


def test_langgraph_stream_module_present():
    import importlib

    # deepagents imports langgraph.stream.run_stream; this is the module that
    # is absent when the langchain stack is too old.
    assert importlib.import_module("langgraph.stream") is not None
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd autobots-devtools-shared-lib && python -m pytest tests/unit/test_deepagents_available.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'langgraph.stream'`.

- [ ] **Step 3: Bump the dependency pins in shared-lib**

In `autobots-devtools-shared-lib/pyproject.toml`, edit the `dependencies` list. Change these three lines:

```toml
    "langchain>=1.0.0",
    "langchain-anthropic>=1.4.0",
    "langchain-google-genai>=4.2.0",
```

to:

```toml
    "langchain>=1.3.11,<2.0.0",
    "langchain-core>=1.4.8,<2.0.0",
    "langchain-anthropic>=1.4.7,<2.0.0",
    "langchain-google-genai>=4.2.5,<5.0.0",
    "deepagents==0.6.12",
```

- [ ] **Step 4: Check the other repos for conflicting langchain caps**

Run: `cd /Users/pralhad/work/src/ws-autobots && grep -rnE "langchain[^-]*[<=]|langgraph" autobots-agents-jarvis/pyproject.toml autobots-agents-mer/pyproject.toml autobots-agents-pay/pyproject.toml`
Expected: note any `langchain<1.3...` upper bounds. If any repo caps langchain below `1.3.11`, raise its floor/cap to `>=1.3.11,<2.0.0` to match the shared venv. If none conflict, make no change here.

- [ ] **Step 5: Reinstall the workspace**

Run: `cd /Users/pralhad/work/src/ws-autobots && make install-dev`
Expected: resolves and installs; `deepagents 0.6.12` and `langchain>=1.3.11` present. Confirm with:
`python -c "import importlib.metadata as m; print(m.version('deepagents'), m.version('langchain'), m.version('langgraph'))"`

- [ ] **Step 6: Run the smoke test to verify it passes**

Run: `cd autobots-devtools-shared-lib && python -m pytest tests/unit/test_deepagents_available.py -v`
Expected: PASS (both tests).

- [ ] **Step 7: Regression — react engine + existing shared-lib suite**

Run: `cd autobots-devtools-shared-lib && make test`
Expected: PASS (no regressions from the langchain 1.2.x → 1.3.x bump).

- [ ] **Step 8: Regression — MER (Nurture) suite**

Run: `cd autobots-agents-mer && make test`
Expected: PASS. If failures trace to the langchain bump (not pre-existing), fix them before proceeding; otherwise stop and report.

- [ ] **Step 9: Commit (from inside shared-lib)**

```bash
cd autobots-devtools-shared-lib
git add pyproject.toml tests/unit/test_deepagents_available.py
git commit -m "build: upgrade langchain stack + add deepagents 0.6.12"
```

---

### Task 2: `DynaDeepAgent` state schema

**Files:**
- Create: `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/dynagent/models/deep_state.py`
- Test: `autobots-devtools-shared-lib/tests/unit/test_deep_state.py`

**Interfaces:**
- Consumes: `deepagents.DeepAgentState`.
- Produces: `DynaDeepAgent(DeepAgentState)` with `NotRequired` keys `agent_name: str`, `session_id: str`, `user_name: str`. Used as the default `state_schema` in Task 4 and Task 5.

- [ ] **Step 1: Write the failing test**

Create `autobots-devtools-shared-lib/tests/unit/test_deep_state.py`:

```python
# ABOUTME: Unit tests for the deep-agent engine state schema.
# ABOUTME: Verifies DynaDeepAgent extends DeepAgentState with identity keys.

from deepagents import DeepAgentState

from autobots_devtools_shared_lib.dynagent.models.deep_state import DynaDeepAgent


def test_dyna_deep_agent_subclasses_deep_agent_state():
    assert issubclass(DynaDeepAgent, DeepAgentState)


def test_dyna_deep_agent_declares_identity_keys():
    annotations = DynaDeepAgent.__annotations__
    assert "agent_name" in annotations
    assert "session_id" in annotations
    assert "user_name" in annotations
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd autobots-devtools-shared-lib && python -m pytest tests/unit/test_deep_state.py -v`
Expected: FAIL — `ModuleNotFoundError: ...dynagent.models.deep_state`.

- [ ] **Step 3: Write the implementation**

Create `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/dynagent/models/deep_state.py`:

```python
# ABOUTME: State schema for the dynagent deep-agent engine.
# ABOUTME: Extends deepagents' DeepAgentState with routing/identity keys.

from typing import NotRequired

from deepagents import DeepAgentState


class DynaDeepAgent(DeepAgentState):
    """Deep-agent state carrying routing keys and optional user identity.

    Mirrors Dynagent's identity keys, but on the deepagents base so it keeps
    deepagents' messages delta reducer and todo/file state channels.
    """

    agent_name: NotRequired[str]
    session_id: NotRequired[str]
    user_name: NotRequired[str]
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd autobots-devtools-shared-lib && python -m pytest tests/unit/test_deep_state.py -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd autobots-devtools-shared-lib
git add src/autobots_devtools_shared_lib/dynagent/models/deep_state.py tests/unit/test_deep_state.py
git commit -m "feat: add DynaDeepAgent deep-engine state schema"
```

---

### Task 3: `agents_config_filename` setting + configurable loader

**Files:**
- Modify: `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/dynagent/config/dynagent_settings.py` (after `dynagent_config_root_dir`, ~line 49)
- Modify: `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/dynagent/agents/agent_config_utils.py:131`
- Test: `autobots-devtools-shared-lib/tests/unit/test_config_filename.py` (create)

**Interfaces:**
- Consumes: `get_dynagent_settings()` (already imported in `agent_config_utils`).
- Produces: `DynagentSettings.agents_config_filename: str = "agents.yaml"`; `load_agents_config()` reads `Path(config_dir) / get_dynagent_settings().agents_config_filename`.

- [ ] **Step 1: Write the failing test**

Create `autobots-devtools-shared-lib/tests/unit/test_config_filename.py`:

```python
# ABOUTME: Unit tests for the configurable agents-config filename.
# ABOUTME: Verifies the default is agents.yaml and load_agents_config honors overrides.

from pathlib import Path

import pytest

import autobots_devtools_shared_lib.dynagent.agents.agent_config_utils as cfg
from autobots_devtools_shared_lib.dynagent.agents.agent_config_utils import (
    _reset_agent_config,
    load_agents_config,
)
from autobots_devtools_shared_lib.dynagent.config.dynagent_settings import DynagentSettings


def test_default_filename_is_agents_yaml():
    assert DynagentSettings().agents_config_filename == "agents.yaml"


@pytest.fixture(autouse=True)
def _reset():
    _reset_agent_config()
    yield
    _reset_agent_config()


def test_load_reads_custom_filename(tmp_path, monkeypatch):
    (tmp_path / "deep-agents.yaml").write_text(
        "agents:\n  assistant:\n    prompt: assistant\n    is_default: true\n    tools: []\n"
    )
    monkeypatch.setattr(cfg, "get_config_dir", lambda: tmp_path)

    settings = DynagentSettings(agents_config_filename="deep-agents.yaml")
    monkeypatch.setattr(cfg, "get_dynagent_settings", lambda: settings)

    agents = load_agents_config()
    assert set(agents.keys()) == {"assistant"}
    assert agents["assistant"].is_default is True
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd autobots-devtools-shared-lib && python -m pytest tests/unit/test_config_filename.py -v`
Expected: FAIL — `AttributeError`/`ValidationError` on `agents_config_filename`.

- [ ] **Step 3: Add the settings field**

In `dynagent_settings.py`, immediately after the `dynagent_config_root_dir` field (~line 49), add:

```python
    # Filename of the agent roster config within the config dir (env: AGENTS_CONFIG_FILENAME).
    # Deep-agent domains set this to "deep-agents.yaml".
    agents_config_filename: str = Field(
        default="agents.yaml",
        description="Agent roster config filename within the config dir",
    )
```

- [ ] **Step 4: Make the loader honor the setting**

In `agent_config_utils.py`, in `load_agents_config()`, change line 131 from:

```python
    config_path = Path(config_dir) / "agents.yaml"
```

to:

```python
    config_path = Path(config_dir) / get_dynagent_settings().agents_config_filename
```

(`get_dynagent_settings` is already imported at the top of the module.)

- [ ] **Step 5: Run test to verify it passes**

Run: `cd autobots-devtools-shared-lib && python -m pytest tests/unit/test_config_filename.py -v`
Expected: PASS (both tests).

- [ ] **Step 6: Regression — config + settings tests**

Run: `cd autobots-devtools-shared-lib && python -m pytest tests/unit/test_agent_config_utils.py tests/unit/test_dynagent_settings.py -v`
Expected: PASS (default filename keeps existing domains working).

- [ ] **Step 7: Commit**

```bash
cd autobots-devtools-shared-lib
git add src/autobots_devtools_shared_lib/dynagent/config/dynagent_settings.py \
        src/autobots_devtools_shared_lib/dynagent/agents/agent_config_utils.py \
        tests/unit/test_config_filename.py
git commit -m "feat: make agents-config filename configurable (deep-agents.yaml)"
```

---

### Task 4: `create_base_deepagent` factory

**Files:**
- Create: `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/dynagent/agents/base_deepagent.py`
- Test: `autobots-devtools-shared-lib/tests/unit/test_base_deepagent.py`

**Interfaces:**
- Consumes: `DynaDeepAgent` (Task 2); `AgentMeta.instance()` (`prompt_map`, `tool_map`, `input_schema_map`, `output_schema_map`); `get_default_agent()`; `lm()`; `deepagents.create_deep_agent`.
- Produces:
  `create_base_deepagent(checkpointer=None, initial_agent_name=None, state_schema=DynaDeepAgent, prompt_values=None, subagents=None) -> CompiledStateGraph`.
  Called by Task 5 and Task 7.

- [ ] **Step 1: Write the failing test**

Create `autobots-devtools-shared-lib/tests/unit/test_base_deepagent.py`:

```python
# ABOUTME: Unit tests for the deep-agent engine factory.
# ABOUTME: Verifies create_base_deepagent wires model/tools/prompt/state into create_deep_agent.

from unittest.mock import MagicMock, patch

import pytest

import autobots_devtools_shared_lib.dynagent.agents.base_deepagent as bd
from autobots_devtools_shared_lib.dynagent.models.deep_state import DynaDeepAgent


@pytest.fixture
def fake_meta():
    meta = MagicMock()
    meta.prompt_map = {"assistant": "You are an assistant writing {language}."}
    meta.tool_map = {"assistant": ["tool_a", "tool_b"]}
    meta.input_schema_map = {"assistant": {}}
    meta.output_schema_map = {"assistant": None}
    return meta


@pytest.fixture
def patched(fake_meta):
    with (
        patch.object(bd.AgentMeta, "instance", return_value=fake_meta),
        patch.object(bd, "get_default_agent", return_value="assistant"),
        patch.object(bd, "lm", return_value="MODEL"),
        patch.object(bd, "create_deep_agent", return_value="GRAPH") as mock_cda,
    ):
        yield mock_cda


def test_returns_compiled_graph_from_create_deep_agent(patched):
    result = bd.create_base_deepagent()
    assert result == "GRAPH"
    patched.assert_called_once()


def test_wires_model_tools_state_and_name(patched):
    bd.create_base_deepagent(initial_agent_name="assistant")
    kwargs = patched.call_args.kwargs
    assert kwargs["model"] == "MODEL"
    assert kwargs["tools"] == ["tool_a", "tool_b"]
    assert kwargs["state_schema"] is DynaDeepAgent
    assert kwargs["name"] == "assistant"
    assert kwargs["checkpointer"] is not None


def test_prompt_values_substituted_into_system_prompt(patched):
    bd.create_base_deepagent(prompt_values={"language": "java"})
    kwargs = patched.call_args.kwargs
    assert kwargs["system_prompt"] == "You are an assistant writing java."


def test_unknown_placeholder_resolves_to_empty(patched, fake_meta):
    fake_meta.prompt_map = {"assistant": "lang={language} extra={unknown}"}
    bd.create_base_deepagent(prompt_values={"language": "java"})
    kwargs = patched.call_args.kwargs
    assert kwargs["system_prompt"] == "lang=java extra="
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd autobots-devtools-shared-lib && python -m pytest tests/unit/test_base_deepagent.py -v`
Expected: FAIL — `ModuleNotFoundError: ...agents.base_deepagent`.

- [ ] **Step 3: Write the implementation**

Create `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/dynagent/agents/base_deepagent.py`:

```python
# ABOUTME: Factory for the dynagent deep-agent engine.
# ABOUTME: Wraps deepagents' create_deep_agent, mirroring create_base_agent's role.

import json
from collections import defaultdict
from collections.abc import Sequence
from typing import Any

from deepagents import DeepAgentState, SubAgent, create_deep_agent
from langgraph.checkpoint.memory import InMemorySaver
from langgraph.graph.state import CompiledStateGraph

from autobots_devtools_shared_lib.common.observability import get_agent_logger
from autobots_devtools_shared_lib.dynagent.agents.agent_config_utils import get_default_agent
from autobots_devtools_shared_lib.dynagent.agents.agent_meta import AgentMeta
from autobots_devtools_shared_lib.dynagent.llm.llm import lm
from autobots_devtools_shared_lib.dynagent.models.deep_state import DynaDeepAgent

logger = get_agent_logger(__name__)


def _resolve_system_prompt(
    meta: AgentMeta, agent_name: str, prompt_values: dict[str, Any] | None
) -> str:
    """Build the static system prompt: raw prompt + one-time format_map substitution.

    Retains dynagent's placeholder templating (e.g. {language} -> java) but resolves
    it once at build time, since the deep engine uses a static system_prompt.
    """
    raw_prompt = meta.prompt_map.get(agent_name, "")
    input_schemas = meta.input_schema_map.get(agent_name, {})
    input_directives = {
        schema_key: json.dumps(schema, indent=2, sort_keys=True)
        for schema_key, schema in input_schemas.items()
    }
    values = {
        "input_schemas": input_directives,
        "output_schema": meta.output_schema_map.get(agent_name, {}) or {},
        **(prompt_values or {}),
    }
    return raw_prompt.format_map(defaultdict(str, values))


def create_base_deepagent(
    checkpointer: Any = None,
    initial_agent_name: str | None = None,
    state_schema: type[DeepAgentState] = DynaDeepAgent,
    prompt_values: dict[str, Any] | None = None,
    subagents: Sequence[SubAgent] | None = None,
) -> CompiledStateGraph:
    """Create the dynagent deep-agent (deepagents-backed) engine.

    Mirrors create_base_agent but delegates the agent loop to deepagents'
    create_deep_agent, which supplies planning, virtual filesystem, sub-agents,
    summarization, and prompt caching. The deep engine deliberately does NOT
    attach inject_agent or our SummarizationMiddleware.

    Args:
        checkpointer: LangGraph checkpointer. Defaults to InMemorySaver.
        initial_agent_name: Roster agent to run as the main agent. Defaults to
            the config's default agent.
        state_schema: Deep-agent state schema. Defaults to DynaDeepAgent.
        prompt_values: Placeholder substitution values for the system prompt.
        subagents: Optional deepagents subagents (phase-2 roster mapping hook).

    Returns:
        A compiled deep-agent graph.
    """
    if checkpointer is None:
        checkpointer = InMemorySaver()

    meta = AgentMeta.instance()

    if initial_agent_name is None:
        initial_agent_name = get_default_agent()
    agent_name = initial_agent_name or "assistant"
    logger.info(f"create_base_deepagent: main agent = {agent_name}")

    system_prompt = _resolve_system_prompt(meta, agent_name, prompt_values)
    tools = meta.tool_map.get(agent_name, [])
    model = lm()

    return create_deep_agent(
        model=model,
        tools=tools,
        system_prompt=system_prompt,
        state_schema=state_schema,
        checkpointer=checkpointer,
        name=agent_name,
        subagents=list(subagents) if subagents else None,
    )
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd autobots-devtools-shared-lib && python -m pytest tests/unit/test_base_deepagent.py -v`
Expected: PASS (all four tests).

- [ ] **Step 5: Commit**

```bash
cd autobots-devtools-shared-lib
git add src/autobots_devtools_shared_lib/dynagent/agents/base_deepagent.py tests/unit/test_base_deepagent.py
git commit -m "feat: add create_base_deepagent deep-engine factory"
```

---

### Task 5: `invoke_deepagent` / `ainvoke_deepagent`

**Files:**
- Modify: `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/dynagent/agents/invocation_utils.py` (append two functions)
- Test: `autobots-devtools-shared-lib/tests/unit/test_invocation_utils.py` (append a test class)

**Interfaces:**
- Consumes: `create_base_deepagent` (Task 4); existing helpers in `invocation_utils` (`inject_langfuse_handler_into_config`, `_linked_langfuse_handler`, `otel_span`, `flush_tracing`, `TraceMetadata`); `DynaDeepAgent` (Task 2).
- Produces:
  `invoke_deepagent(agent_name, input_state=None, checkpointer=None, config=None, enable_tracing=True, trace_metadata=None, state_schema=DynaDeepAgent) -> dict`
  and its async twin `ainvoke_deepagent(...)`.

- [ ] **Step 1: Write the failing test**

Append to `autobots-devtools-shared-lib/tests/unit/test_invocation_utils.py`:

```python
class TestInvokeDeepagent:
    def test_invokes_deepagent_with_correct_state(
        self, mock_get_agent_list, mock_agent, input_state, config
    ):
        from unittest.mock import patch

        from autobots_devtools_shared_lib.dynagent.agents.invocation_utils import (
            invoke_deepagent,
        )

        with patch(
            "autobots_devtools_shared_lib.dynagent.agents.base_deepagent.create_base_deepagent",
            return_value=mock_agent,
        ) as mock_factory:
            _ = invoke_deepagent(
                "coordinator", input_state, config=config, enable_tracing=False
            )

        mock_factory.assert_called_once()
        mock_agent.invoke.assert_called_once()
        call_args = mock_agent.invoke.call_args
        assert "messages" in call_args[0][0]
        assert call_args[1]["config"] == config

    async def test_ainvoke_deepagent_with_correct_state(
        self, mock_get_agent_list, mock_agent, input_state, config
    ):
        from unittest.mock import patch

        from autobots_devtools_shared_lib.dynagent.agents.invocation_utils import (
            ainvoke_deepagent,
        )

        with patch(
            "autobots_devtools_shared_lib.dynagent.agents.base_deepagent.create_base_deepagent",
            return_value=mock_agent,
        ) as mock_factory:
            _ = await ainvoke_deepagent(
                "coordinator", input_state, config=config, enable_tracing=False
            )

        mock_factory.assert_called_once()
        mock_agent.ainvoke.assert_called_once()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd autobots-devtools-shared-lib && python -m pytest tests/unit/test_invocation_utils.py::TestInvokeDeepagent -v`
Expected: FAIL — `ImportError: cannot import name 'invoke_deepagent'`.

- [ ] **Step 3: Write the implementation**

Append these two functions to the end of `invocation_utils.py` (imports `Dynagent` already present; add `DynaDeepAgent` import at the top of the module: `from autobots_devtools_shared_lib.dynagent.models.deep_state import DynaDeepAgent`):

```python
def invoke_deepagent(
    agent_name: str,
    input_state: dict[str, Any] | None = None,
    checkpointer: Any | None = None,
    config: RunnableConfig | None = None,
    enable_tracing: bool = True,
    trace_metadata: TraceMetadata | None = None,
    state_schema: type[AgentState[ResponseT]] = DynaDeepAgent,
) -> dict[str, Any]:
    """Synchronously invoke a deep-agent (deepagents-backed) with observability.

    Mirrors invoke_agent but builds the graph via create_base_deepagent.
    """
    from autobots_devtools_shared_lib.dynagent.agents.agent_config_utils import get_agent_list

    valid_agents = get_agent_list()
    if agent_name not in valid_agents:
        raise ValueError(f"Unknown agent: {agent_name}. Valid agents: {', '.join(valid_agents)}")

    if input_state is None:
        input_state = {}
    if trace_metadata is None:
        trace_metadata = TraceMetadata.create(app_name=f"{agent_name}-invoke-deep")
        if "session_id" in input_state:
            trace_metadata.session_id = input_state["session_id"]

    if "session_id" not in input_state:
        input_state["session_id"] = trace_metadata.session_id
    if "agent_name" not in input_state:
        input_state["agent_name"] = agent_name

    try:
        with (
            propagate_attributes(
                user_id=trace_metadata.user_id,
                session_id=trace_metadata.session_id,
                tags=trace_metadata.tags,
            ),
            otel_span(f"{trace_metadata.app_name}-{agent_name}") as span,
        ):
            if enable_tracing:
                config = inject_langfuse_handler_into_config(config, _linked_langfuse_handler(span))
            if span is not None:
                span.set_attribute("langfuse.session.id", str(trace_metadata.session_id))

            from langgraph.checkpoint.memory import InMemorySaver

            from autobots_devtools_shared_lib.dynagent.agents.base_deepagent import (
                create_base_deepagent,
            )

            if checkpointer is None:
                checkpointer = InMemorySaver()

            agent = create_base_deepagent(
                checkpointer=checkpointer,
                state_schema=state_schema,
                initial_agent_name=agent_name,
            )

            logger.info(
                f"Invoking deepagent '{agent_name}' (sync) session_id={trace_metadata.session_id}"
            )
            result = agent.invoke(input_state, config=config)
            return result
    finally:
        if enable_tracing:
            flush_tracing()


async def ainvoke_deepagent(
    agent_name: str,
    input_state: dict[str, Any] | None = None,
    checkpointer: Any | None = None,
    config: RunnableConfig | None = None,
    enable_tracing: bool = True,
    trace_metadata: TraceMetadata | None = None,
    state_schema: type[AgentState[ResponseT]] = DynaDeepAgent,
) -> dict[str, Any]:
    """Asynchronously invoke a deep-agent (deepagents-backed) with observability.

    Mirrors ainvoke_agent but builds the graph via create_base_deepagent.
    """
    from autobots_devtools_shared_lib.dynagent.agents.agent_config_utils import get_agent_list

    valid_agents = get_agent_list()
    if agent_name not in valid_agents:
        raise ValueError(f"Unknown agent: {agent_name}. Valid agents: {', '.join(valid_agents)}")

    if input_state is None:
        input_state = {}
    if trace_metadata is None:
        trace_metadata = TraceMetadata.create(app_name=f"{agent_name}-ainvoke-deep")
        if "session_id" in input_state:
            trace_metadata.session_id = input_state["session_id"]

    if "session_id" not in input_state:
        input_state["session_id"] = trace_metadata.session_id
    if "agent_name" not in input_state:
        input_state["agent_name"] = agent_name

    try:
        with (
            propagate_attributes(
                user_id=trace_metadata.user_id,
                session_id=trace_metadata.session_id,
                tags=trace_metadata.tags,
            ),
            otel_span(f"{trace_metadata.app_name}-{agent_name}") as span,
        ):
            if enable_tracing:
                config = inject_langfuse_handler_into_config(config, _linked_langfuse_handler(span))
            if span is not None:
                span.set_attribute("langfuse.session.id", str(trace_metadata.session_id))

            from langgraph.checkpoint.memory import InMemorySaver

            from autobots_devtools_shared_lib.dynagent.agents.base_deepagent import (
                create_base_deepagent,
            )

            if checkpointer is None:
                checkpointer = InMemorySaver()

            agent = create_base_deepagent(
                checkpointer=checkpointer,
                state_schema=state_schema,
                initial_agent_name=agent_name,
            )

            logger.info(
                f"Invoking deepagent '{agent_name}' (async) session_id={trace_metadata.session_id}"
            )
            result = await agent.ainvoke(input_state, config=config)
            return result
    finally:
        if enable_tracing:
            flush_tracing()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd autobots-devtools-shared-lib && python -m pytest tests/unit/test_invocation_utils.py -v`
Expected: PASS (new `TestInvokeDeepagent` class + existing tests still green).

- [ ] **Step 5: Commit**

```bash
cd autobots-devtools-shared-lib
git add src/autobots_devtools_shared_lib/dynagent/agents/invocation_utils.py tests/unit/test_invocation_utils.py
git commit -m "feat: add invoke_deepagent/ainvoke_deepagent invocation helpers"
```

---

### Task 6: Public API exports

**Files:**
- Modify: `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/dynagent/__init__.py`
- Test: `autobots-devtools-shared-lib/tests/unit/test_public_api.py` (create)

**Interfaces:**
- Produces: `create_base_deepagent`, `DynaDeepAgent`, `invoke_deepagent`, `ainvoke_deepagent` importable from `autobots_devtools_shared_lib.dynagent`.

- [ ] **Step 1: Write the failing test**

Create `autobots-devtools-shared-lib/tests/unit/test_public_api.py`:

```python
# ABOUTME: Unit tests for the dynagent public API surface.
# ABOUTME: Verifies the deep-agent engine symbols are exported.


def test_deep_engine_symbols_exported():
    import autobots_devtools_shared_lib.dynagent as pkg

    for name in ("create_base_deepagent", "DynaDeepAgent", "invoke_deepagent", "ainvoke_deepagent"):
        assert name in pkg.__all__
        assert getattr(pkg, name) is not None
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd autobots-devtools-shared-lib && python -m pytest tests/unit/test_public_api.py -v`
Expected: FAIL — `AttributeError`/assertion on missing exports.

- [ ] **Step 3: Add the imports and `__all__` entries**

In `dynagent/__init__.py`, add these imports alongside the existing ones:

```python
from autobots_devtools_shared_lib.dynagent.agents.base_deepagent import create_base_deepagent
from autobots_devtools_shared_lib.dynagent.agents.invocation_utils import (
    ainvoke_agent,
    ainvoke_deepagent,
    invoke_agent,
    invoke_deepagent,
)
from autobots_devtools_shared_lib.dynagent.models.deep_state import DynaDeepAgent
```

(Replace the existing `invocation_utils` import block so `ainvoke_deepagent`/`invoke_deepagent` are included; remove the now-duplicate `ainvoke_agent`/`invoke_agent` import lines.)

Then add these four names to the `__all__` list (keep it alphabetically sorted, matching the existing style):

```python
    "DynaDeepAgent",
    "ainvoke_deepagent",
    "create_base_deepagent",
    "invoke_deepagent",
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd autobots-devtools-shared-lib && python -m pytest tests/unit/test_public_api.py -v`
Expected: PASS.

- [ ] **Step 5: Lint + type-check the shared-lib changes**

Run: `cd autobots-devtools-shared-lib && make check-format && make type-check`
Expected: PASS (Ruff clean, Pyright basic clean).

- [ ] **Step 6: Commit**

```bash
cd autobots-devtools-shared-lib
git add src/autobots_devtools_shared_lib/dynagent/__init__.py tests/unit/test_public_api.py
git commit -m "feat: export deep-agent engine from dynagent public API"
```

---

### Task 7: AMA domain in `autobots-agents-mer`

**Files:**
- Create: `autobots-agents-mer/agent_configs/ama/deep-agents.yaml`
- Create: `autobots-agents-mer/agent_configs/ama/prompts/assistant.md`
- Test: `autobots-agents-mer/tests/unit/domains/test_ama_deepagent.py`

**Interfaces:**
- Consumes: `create_base_deepagent` (Task 4); `agents_config_filename` setting (Task 3). `AppSettings(DynagentSettings)` inherits `agents_config_filename` automatically — no MER settings change needed.
- Produces: a runnable AMA deep-agent domain (default agent `assistant`).

- [ ] **Step 1: Create the AMA prompt**

Create `autobots-agents-mer/agent_configs/ama/prompts/assistant.md`:

```markdown
You are a helpful general-purpose assistant.

Answer the user's questions directly and accurately. When a request is complex,
break it into steps with the write_todos tool and work through them. Use the
filesystem tools to store and retrieve intermediate work, and delegate large,
self-contained subtasks to a subagent via the task tool so your main context
stays focused.

Be concise. Prefer doing the work over describing it.
```

- [ ] **Step 2: Create the AMA deep-agents.yaml**

Create `autobots-agents-mer/agent_configs/ama/deep-agents.yaml`:

```yaml
# ABOUTME: Deep-agent roster for the AMA (general assistant) domain.
# ABOUTME: Runs on the deepagents-backed engine (create_base_deepagent).

agents:

  assistant:
    prompt: "assistant"
    is_default: true
    tools: []
```

(An empty `tools` list is intentional for the first cut: deepagents supplies `write_todos`, filesystem tools, and `task` automatically. AMA-specific retrieval/action tools get registered and added here later.)

- [ ] **Step 3: Write the failing build test**

Create `autobots-agents-mer/tests/unit/domains/test_ama_deepagent.py`:

```python
# ABOUTME: Unit test that the AMA domain config builds a deep-agent graph.
# ABOUTME: Points config at agent_configs/ama with deep-agents.yaml and compiles the engine.

from pathlib import Path

import pytest

_AMA_CONFIG_CANDIDATES = [
    Path("agent_configs/ama"),
    Path("autobots-agents-mer/agent_configs/ama"),
    Path(__file__).parents[3] / "agent_configs" / "ama",
]
_AMA_CONFIG_DIR = next((c for c in _AMA_CONFIG_CANDIDATES if (c / "deep-agents.yaml").exists()), None)


@pytest.fixture
def ama_env(monkeypatch):
    from autobots_devtools_shared_lib.dynagent.agents.agent_config_utils import _reset_agent_config
    from autobots_devtools_shared_lib.dynagent.agents.agent_meta import AgentMeta
    import autobots_devtools_shared_lib.dynagent.config.dynagent_settings as settings_module

    assert _AMA_CONFIG_DIR is not None, "AMA config dir not found"
    _reset_agent_config()
    AgentMeta.reset()
    settings_module._settings = None
    monkeypatch.setenv("DYNAGENT_CONFIG_ROOT_DIR", str(_AMA_CONFIG_DIR))
    monkeypatch.setenv("AGENTS_CONFIG_FILENAME", "deep-agents.yaml")
    yield
    _reset_agent_config()
    AgentMeta.reset()
    settings_module._settings = None


def test_ama_config_default_agent_is_assistant(ama_env):
    from autobots_devtools_shared_lib.dynagent.agents.agent_config_utils import (
        get_agent_list,
        get_default_agent,
    )

    assert get_agent_list() == ["assistant"]
    assert get_default_agent() == "assistant"


def test_ama_deepagent_compiles(ama_env):
    from autobots_devtools_shared_lib.dynagent.agents.base_deepagent import create_base_deepagent

    agent = create_base_deepagent()
    assert agent is not None
    assert hasattr(agent, "invoke")
    assert hasattr(agent, "ainvoke")
```

- [ ] **Step 4: Run test to verify it fails, then passes**

Run: `cd autobots-agents-mer && python -m pytest tests/unit/domains/test_ama_deepagent.py -v`
Expected: initially FAIL if the config/prompt files are missing or mis-pathed; after Steps 1-2 exist and are correct, PASS (both tests). `create_base_deepagent()` compiles without a live API key because compilation does not call the model.

- [ ] **Step 5: Commit (from inside MER)**

```bash
cd autobots-agents-mer
git add agent_configs/ama/ tests/unit/domains/test_ama_deepagent.py
git commit -m "feat: add AMA deep-agent domain (deep-agents.yaml + assistant)"
```

---

## Self-Review

**Spec coverage:**
- §1 Module layout → Tasks 2, 4, 5, 7. ✓
- §2 `create_base_deepagent` signature/behavior (no `inject_agent`/`SummarizationMiddleware`, static prompt) → Task 4. ✓
- §3 `DynaDeepAgent` → Task 2. ✓
- §4 retained `format_map` (prompt_values, empty on unknown) → Task 4 (`_resolve_system_prompt` + tests). ✓
- §5 AMA domain + `deep-agents.yaml` + `agents_config_filename` setting → Task 3 (setting/loader) + Task 7 (domain). ✓
- §6 invocation (separate `invoke_deepagent`/`ainvoke_deepagent`) + streaming (unchanged) → Task 5. Streaming needs no code (existing `stream_agent_events` consumes any `CompiledStateGraph`). ✓
- §7 public API exports → Task 6. ✓
- Phase 0 dependency resolution (blocker) → Task 1. ✓
- Testing (unit + integration + regression) → unit tests per task; Nurture/react regression in Task 1 Steps 7-8. ✓

**Placeholder scan:** No TBD/TODO; every code step contains complete code; commands have expected output. ✓

**Type consistency:** `create_base_deepagent(checkpointer, initial_agent_name, state_schema, prompt_values, subagents)` used identically in Tasks 4, 5, 7. `DynaDeepAgent` default state in Tasks 2/4/5. Imports `create_deep_agent, DeepAgentState, SubAgent` match deepagents' verified exports. `agents_config_filename` name identical in Tasks 3 and 7. ✓

**Deferred to phase-2 (not gaps):** roster→`subagents=` mapping (hook present in Task 4 signature), AMA-specific retrieval tools, `prompt_values` sourcing from `.env` (currently caller-supplied per approved spec).
