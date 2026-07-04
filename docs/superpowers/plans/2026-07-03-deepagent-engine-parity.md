# Deep Agent Engine Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every `create_deep_agent` (deepagents 0.6.12) capability reachable from `deep-agents.yaml` config through `create_base_deepagent` — skills, memory, backends (incl. a file-server-sidecar backend), per-agent models, config-driven subagents, structured output, HITL, permissions, MCP servers, and rubric grading.

**Architecture:** Config-first: new optional keys in `deep-agents.yaml` are parsed by `AgentConfig`/`load_agents_config`, surfaced as maps on the `AgentMeta` singleton, and wired into `create_deep_agent` by the factory. Three new resolution layers: a model-profile resolver (`lm()` gains override args), a backend registry (`state`/`filesystem`/`fserver`/`store`/`composite`), and a `FileServerBackend` implementing deepagents' `BackendProtocol` on the MER file-server sidecar. Python kwargs on `create_base_deepagent` remain only as escape hatches for live objects.

**Tech Stack:** Python 3.12+, `deepagents==0.6.12`, LangChain 1.3.x / LangGraph, httpx, Pydantic settings, pytest (`asyncio_mode = "auto"`), Ruff (line-length 100, double quotes), Pyright basic. P6 adds `langchain-mcp-adapters`.

**Spec:** `docs/superpowers/specs/2026-07-03-deepagent-engine-parity-design.md`

## Global Constraints

- Pinned semantics: `deepagents==0.6.12` (`permissions`, `state_schema`, `BackendFactory = Callable[[ToolRuntime], BackendProtocol]`). Re-verify signatures on any bump.
- Do **not** change the react engine (`create_base_agent`, `inject_agent`) or Nurture. New YAML keys must be ignored (harmless) on the react path; `lm()` with no args must behave exactly as today.
- No per-agent API keys in YAML — secrets stay in `DynagentSettings`/env.
- No sandbox/`execute` backend, no nested/async subagents, no summarization tuning, no configurable `recursion_limit`, no file-server API changes (edit/glob/grep are emulated client-side).
- Existing MER file-server **tool** functions (`list_files`, `read_file`, `write_file`, `create_download_link`) must keep byte-identical return strings after the raw-function refactor.
- `FILE_SERVER_HOST`/`FILE_SERVER_PORT` env vars (default `localhost:9002`) remain the sidecar address source.
- Code style: Ruff line-length 100, double quotes; every new module starts with two `# ABOUTME:` comment lines. Pyright basic must pass.
- Shared venv at `ws-autobots/.venv` (Python 3.13 on this machine); run tests via each repo's Makefile. Commit from **inside** `autobots-devtools-shared-lib/` (or `autobots-agents-mer/` for MER tests) — pre-commit hooks run there.
- Test-run command used throughout: `cd autobots-devtools-shared-lib && make test-one TEST=<path>::<test>`.

## File Structure

All paths relative to the workspace root `ws-autobots/`. Source prefix `SRC = autobots-devtools-shared-lib/src/autobots_devtools_shared_lib`.

| File | Responsibility |
|---|---|
| `SRC/dynagent/agents/agent_config_utils.py` (modify) | Env interpolation, new `AgentConfig` fields, top-level `models`/`default_backend`/`mcp_servers` blocks, load-time validation |
| `SRC/dynagent/agents/agent_meta.py` (modify) | New maps: `model_map`, `skills_map`, `memory_map`, `interrupt_map`, `permissions_map`, `description_map`, `mcp_map`, `debug_map`, `rubric_map`, `backend_config`, `model_profiles`, `mcp_servers_config` |
| `SRC/dynagent/llm/llm.py` (modify) | `lm(model=None, provider=None, temperature=None)` |
| `SRC/dynagent/llm/model_resolution.py` (create) | Profile/inline model-ref validation + resolution (`resolve_agent_model`) |
| `SRC/dynagent/agents/deep_backend.py` (create) | Backend registry + `resolve_backend` (`state`/`filesystem`/`store`/`composite`/`fserver`) |
| `SRC/dynagent/agents/fserver_backend.py` (create) | `FileServerBackend` (BackendProtocol on the sidecar), `workspace_context_from_state` |
| `SRC/dynagent/middleware/__init__.py` (create) | New middleware package |
| `SRC/dynagent/middleware/tool_resilience.py` (create) | `ToolResilienceMiddleware` (tool exception → error `ToolMessage`) |
| `SRC/dynagent/agents/deep_mcp.py` (create, P6) | MCP tool loading via `MultiServerMCPClient`, name prefixing, event-loop-aware sync bridge |
| `SRC/dynagent/agents/deep_rubric.py` (create, P7) | `build_rubric_middleware` from `rubric:` config |
| `SRC/dynagent/agents/base_deepagent.py` (modify) | Factory wiring: all new `create_deep_agent` params, roster→`SubAgent` mapping, kwarg merge |
| `SRC/common/utils/fserver_client_utils.py` (modify) | Raw-function extraction (`raw_list_files`, `raw_read_file`, `raw_write_file`, `raw_create_download_link`); existing tools become wrappers |
| `autobots-devtools-shared-lib/tests/unit/…` | Per-task unit tests (see tasks) |
| `autobots-agents-mer/tests/integration/test_fserver_backend_live.py` (create) | Live-sidecar integration test |

Note on domains: the AMA domain rollout (real skills content, `AGENTS.md`, workspace roots) is product work outside this plan; Task 20's sanity test proves the skills+memory+filesystem path with a self-contained temp domain, matching the spec's testing intent.

---

## Phase P1 — config plumbing, models, backend registry, resilience (blog-reference parity)

### Task 1: Env interpolation in config loading

`${VAR}` in any string value of the roster YAML is expanded from `os.environ` at load time; an undefined variable fails fast.

**Files:**
- Modify: `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/dynagent/agents/agent_config_utils.py`
- Test: `autobots-devtools-shared-lib/tests/unit/test_env_interpolation.py` (create)

**Interfaces:**
- Produces: `interpolate_env(value: Any) -> Any` (module-level, exported in `__all__`), applied inside `load_agents_config` to the parsed YAML dict before `AgentConfig` construction. Raises `ValueError` naming the missing variable.

- [ ] **Step 1: Write the failing tests**

Create `autobots-devtools-shared-lib/tests/unit/test_env_interpolation.py`:

```python
# ABOUTME: Unit tests for ${VAR} environment interpolation in roster config values.
# ABOUTME: Verifies expansion, recursion into dicts/lists, and fail-fast on undefined vars.

import pytest

import autobots_devtools_shared_lib.dynagent.agents.agent_config_utils as cfg
from autobots_devtools_shared_lib.dynagent.agents.agent_config_utils import (
    _reset_agent_config,
    interpolate_env,
    load_agents_config,
)
from autobots_devtools_shared_lib.dynagent.config.dynagent_settings import DynagentSettings


@pytest.fixture(autouse=True)
def _reset():
    _reset_agent_config()
    yield
    _reset_agent_config()


def test_plain_values_pass_through():
    assert interpolate_env("no vars here") == "no vars here"
    assert interpolate_env(42) == 42
    assert interpolate_env(None) is None
    assert interpolate_env(True) is True


def test_expands_env_var_in_string(monkeypatch):
    monkeypatch.setenv("WORKSPACE_ROOT", "/tmp/ws")
    assert interpolate_env("${WORKSPACE_ROOT}/files") == "/tmp/ws/files"


def test_recurses_into_dicts_and_lists(monkeypatch):
    monkeypatch.setenv("TOKEN", "abc123")
    value = {"headers": {"Authorization": "Bearer ${TOKEN}"}, "paths": ["${TOKEN}/x"]}
    assert interpolate_env(value) == {
        "headers": {"Authorization": "Bearer abc123"},
        "paths": ["abc123/x"],
    }


def test_undefined_var_fails_fast(monkeypatch):
    monkeypatch.delenv("NOPE_NOT_SET", raising=False)
    with pytest.raises(ValueError, match="NOPE_NOT_SET"):
        interpolate_env("${NOPE_NOT_SET}")


def test_load_agents_config_interpolates(tmp_path, monkeypatch):
    monkeypatch.setenv("MY_PROMPT", "assistant")
    (tmp_path / "deep-agents.yaml").write_text(
        "agents:\n  assistant:\n    prompt: ${MY_PROMPT}\n    is_default: true\n    tools: []\n"
    )
    monkeypatch.setattr(cfg, "get_config_dir", lambda: tmp_path)
    settings = DynagentSettings(agents_config_filename="deep-agents.yaml")
    monkeypatch.setattr(cfg, "get_dynagent_settings", lambda: settings)

    agents = load_agents_config()
    assert agents["assistant"].prompt == "assistant"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd autobots-devtools-shared-lib && make test-one TEST=tests/unit/test_env_interpolation.py`
Expected: FAIL — `ImportError: cannot import name 'interpolate_env'`

- [ ] **Step 3: Implement `interpolate_env`**

In `agent_config_utils.py`, add near the top (after the imports; add `import os` and `import re` to the import block, keeping isort order):

```python
_ENV_VAR_PATTERN = re.compile(r"\$\{(\w+)\}")


def interpolate_env(value: Any) -> Any:
    """Recursively expand ${VAR} from os.environ in config values.

    Fails fast on undefined variables so misconfigured domains surface at
    startup instead of at first tool call.
    """
    if isinstance(value, str):

        def _sub(match: re.Match[str]) -> str:
            var = match.group(1)
            if var not in os.environ:
                msg = f"Config references undefined environment variable '${{{var}}}'"
                raise ValueError(msg)
            return os.environ[var]

        return _ENV_VAR_PATTERN.sub(_sub, value)
    if isinstance(value, dict):
        return {key: interpolate_env(item) for key, item in value.items()}
    if isinstance(value, list):
        return [interpolate_env(item) for item in value]
    return value
```

In `load_agents_config`, interpolate right after parsing:

```python
    with open(config_path) as f:  # noqa: PTH123
        data = yaml.safe_load(f)
    data = interpolate_env(data or {})
```

Add `"interpolate_env"` to `__all__` (keep it alphabetically sorted).

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd autobots-devtools-shared-lib && make test-one TEST=tests/unit/test_env_interpolation.py`
Expected: PASS (all 5)

- [ ] **Step 5: Regression + commit**

Run: `cd autobots-devtools-shared-lib && make test-fast`
Expected: PASS (react-engine config tests unaffected — their YAML has no `${…}`)

```bash
cd autobots-devtools-shared-lib
git add src/autobots_devtools_shared_lib/dynagent/agents/agent_config_utils.py tests/unit/test_env_interpolation.py
git commit -m "feat(dynagent): expand \${VAR} env interpolation in roster config"
```

---

### Task 2: `AgentConfig` deep-engine fields + top-level `models` / `default_backend` / `mcp_servers` blocks

Parse (no validation yet — that lands in Tasks 4/13/16/18): per-agent `model`, `skills`, `memory`, `interrupt_on`, `permissions`, `description`, `mcp_servers`, `rubric`, `debug`; top-level `models`, `default_backend`, `mcp_servers`.

**Files:**
- Modify: `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/dynagent/agents/agent_config_utils.py`
- Test: `autobots-devtools-shared-lib/tests/unit/test_deep_config_keys.py` (create)

**Interfaces:**
- Produces (all in `agent_config_utils`, added to `__all__`):
  - `AgentConfig` new fields: `model: str | None`, `skills: list[str]`, `memory: list[str]`, `interrupt_on: dict[str, Any]`, `permissions: list[Any]`, `description: str | None`, `mcp_servers: list[str]`, `rubric: dict[str, Any] | None`, `debug: bool`
  - `get_model_profiles() -> dict[str, dict[str, Any]]` — top-level `models:` block (`{}` when absent)
  - `get_default_backend_config() -> dict[str, Any] | None` — top-level `default_backend:` block
  - `get_mcp_servers_config() -> dict[str, dict[str, Any]]` — top-level `mcp_servers:` block (`{}` when absent)
- Consumes: `interpolate_env` (Task 1) — already applied to the whole document, so these blocks arrive interpolated.

- [ ] **Step 1: Write the failing tests**

Create `autobots-devtools-shared-lib/tests/unit/test_deep_config_keys.py`:

```python
# ABOUTME: Unit tests for deep-engine keys in deep-agents.yaml.
# ABOUTME: Covers per-agent model/skills/memory/etc. and top-level models/default_backend/mcp_servers.

import pytest

import autobots_devtools_shared_lib.dynagent.agents.agent_config_utils as cfg
from autobots_devtools_shared_lib.dynagent.agents.agent_config_utils import (
    _reset_agent_config,
    get_default_backend_config,
    get_mcp_servers_config,
    get_model_profiles,
    load_agents_config,
)
from autobots_devtools_shared_lib.dynagent.config.dynagent_settings import DynagentSettings

DEEP_YAML = """
models:
  main:
    provider: anthropic
    name: claude-sonnet-4-6
  cheap-docs:
    provider: anthropic
    name: claude-haiku-4-5
    temperature: 0.3

default_backend:
  type: filesystem
  root_dir: /tmp/ws

mcp_servers:
  atlassian:
    transport: streamable_http
    url: http://mcp.local

agents:
  assistant:
    prompt: assistant
    is_default: true
    model: main
    tools: []
    skills: ["skills/"]
    memory: ["AGENTS.md"]
    interrupt_on:
      write_file: true
    permissions: []
    mcp_servers: ["atlassian"]
    debug: true
    rubric:
      model: cheap-docs
      max_iterations: 3
  researcher:
    prompt: researcher
    description: Deep research on a topic
    model: cheap-docs
    tools: []
"""


@pytest.fixture(autouse=True)
def deep_config(tmp_path, monkeypatch):
    _reset_agent_config()
    (tmp_path / "deep-agents.yaml").write_text(DEEP_YAML)
    monkeypatch.setattr(cfg, "get_config_dir", lambda: tmp_path)
    settings = DynagentSettings(agents_config_filename="deep-agents.yaml")
    monkeypatch.setattr(cfg, "get_dynagent_settings", lambda: settings)
    yield
    _reset_agent_config()


def test_per_agent_deep_fields_parsed():
    agents = load_agents_config()
    a = agents["assistant"]
    assert a.model == "main"
    assert a.skills == ["skills/"]
    assert a.memory == ["AGENTS.md"]
    assert a.interrupt_on == {"write_file": True}
    assert a.permissions == []
    assert a.mcp_servers == ["atlassian"]
    assert a.debug is True
    assert a.rubric == {"model": "cheap-docs", "max_iterations": 3}
    assert a.description is None


def test_subagent_entry_fields_parsed():
    agents = load_agents_config()
    r = agents["researcher"]
    assert r.description == "Deep research on a topic"
    assert r.model == "cheap-docs"
    assert r.is_default is False


def test_top_level_model_profiles():
    profiles = get_model_profiles()
    assert profiles["main"] == {"provider": "anthropic", "name": "claude-sonnet-4-6"}
    assert profiles["cheap-docs"]["temperature"] == 0.3


def test_top_level_default_backend():
    assert get_default_backend_config() == {"type": "filesystem", "root_dir": "/tmp/ws"}


def test_top_level_mcp_servers():
    servers = get_mcp_servers_config()
    assert servers["atlassian"]["transport"] == "streamable_http"


def test_blocks_default_to_empty(tmp_path, monkeypatch):
    _reset_agent_config()
    (tmp_path / "plain.yaml").write_text(
        "agents:\n  a:\n    prompt: a\n    is_default: true\n    tools: []\n"
    )
    monkeypatch.setattr(cfg, "get_config_dir", lambda: tmp_path)
    settings = DynagentSettings(agents_config_filename="plain.yaml")
    monkeypatch.setattr(cfg, "get_dynagent_settings", lambda: settings)

    agents = load_agents_config()
    assert get_model_profiles() == {}
    assert get_default_backend_config() is None
    assert get_mcp_servers_config() == {}
    assert agents["a"].model is None
    assert agents["a"].skills == []
    assert agents["a"].debug is False
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd autobots-devtools-shared-lib && make test-one TEST=tests/unit/test_deep_config_keys.py`
Expected: FAIL — `ImportError: cannot import name 'get_default_backend_config'`

- [ ] **Step 3: Implement fields, caches, accessors**

In `agent_config_utils.py`:

(a) Extend the `AgentConfig` dataclass (append after `max_concurrency`):

```python
    # --- deep-engine-only fields (ignored by the react engine) ---
    model: str | None = None
    skills: list[str] = field(default_factory=list)
    memory: list[str] = field(default_factory=list)
    interrupt_on: dict[str, Any] = field(default_factory=dict)
    permissions: list[Any] = field(default_factory=list)
    description: str | None = None
    mcp_servers: list[str] = field(default_factory=list)
    rubric: dict[str, Any] | None = None
    debug: bool = False
```

(b) In `AgentConfig.from_dict`, add to the returned constructor call:

```python
            model=data.get("model"),
            skills=list(data.get("skills") or []),
            memory=list(data.get("memory") or []),
            interrupt_on=dict(data.get("interrupt_on") or {}),
            permissions=list(data.get("permissions") or []),
            description=data.get("description"),
            mcp_servers=list(data.get("mcp_servers") or []),
            rubric=data.get("rubric"),
            debug=bool(data.get("debug", False)),
```

(c) Add module caches next to `_GLOBAL_AGENT_CONFIG` and clear them in `_reset_agent_config`:

```python
_GLOBAL_MODEL_PROFILES: dict[str, dict[str, Any]] = {}
_GLOBAL_BACKEND_CONFIG: dict[str, Any] | None = None
_GLOBAL_MCP_SERVERS: dict[str, dict[str, Any]] = {}


def _reset_agent_config() -> None:
    """Clear the cached agent config — for test isolation."""
    global _GLOBAL_AGENT_CONFIG, _GLOBAL_MODEL_PROFILES, _GLOBAL_BACKEND_CONFIG, _GLOBAL_MCP_SERVERS
    _GLOBAL_AGENT_CONFIG = {}
    _GLOBAL_MODEL_PROFILES = {}
    _GLOBAL_BACKEND_CONFIG = None
    _GLOBAL_MCP_SERVERS = {}
```

(d) In `load_agents_config`, after `data = interpolate_env(data or {})` and before the agents loop:

```python
    global _GLOBAL_MODEL_PROFILES, _GLOBAL_BACKEND_CONFIG, _GLOBAL_MCP_SERVERS
    _GLOBAL_MODEL_PROFILES = data.get("models") or {}
    _GLOBAL_BACKEND_CONFIG = data.get("default_backend")
    _GLOBAL_MCP_SERVERS = data.get("mcp_servers") or {}
```

(e) Accessors (after `get_default_agent`); add all three to `__all__`:

```python
def get_model_profiles() -> dict[str, dict[str, Any]]:
    """Return the top-level models: block ({profile_name: {provider, name, temperature}})."""
    load_agents_config()
    return _GLOBAL_MODEL_PROFILES


def get_default_backend_config() -> dict[str, Any] | None:
    """Return the top-level default_backend: block, or None if not configured."""
    load_agents_config()
    return _GLOBAL_BACKEND_CONFIG


def get_mcp_servers_config() -> dict[str, dict[str, Any]]:
    """Return the top-level mcp_servers: block ({server_name: connection config})."""
    load_agents_config()
    return _GLOBAL_MCP_SERVERS
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd autobots-devtools-shared-lib && make test-one TEST=tests/unit/test_deep_config_keys.py`
Expected: PASS (all 6)

- [ ] **Step 5: Regression + commit**

Run: `cd autobots-devtools-shared-lib && make test-fast`
Expected: PASS

```bash
cd autobots-devtools-shared-lib
git add src/autobots_devtools_shared_lib/dynagent/agents/agent_config_utils.py tests/unit/test_deep_config_keys.py
git commit -m "feat(dynagent): parse deep-engine roster keys and models/default_backend/mcp_servers blocks"
```

---

### Task 3: `lm()` override arguments

`lm(model=None, provider=None, temperature=None)` — every argument defaults to the current settings value; existing zero-arg callers are untouched.

**Files:**
- Modify: `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/dynagent/llm/llm.py`
- Test: `autobots-devtools-shared-lib/tests/unit/test_llm_overrides.py` (create)

**Interfaces:**
- Produces: `lm(model: str | None = None, provider: str | None = None, temperature: float | None = None) -> BaseChatModel`. Unknown provider string raises `ValueError("Unsupported LLM provider: …")` (same path as today).

- [ ] **Step 1: Write the failing tests**

Create `autobots-devtools-shared-lib/tests/unit/test_llm_overrides.py`:

```python
# ABOUTME: Unit tests for lm() override arguments (model, provider, temperature).
# ABOUTME: Verifies settings-backed defaults, per-call overrides, and unknown-provider failure.

from unittest.mock import patch

import pytest

import autobots_devtools_shared_lib.dynagent.llm.llm as llm_mod
from autobots_devtools_shared_lib.dynagent.config.dynagent_settings import DynagentSettings
from autobots_devtools_shared_lib.dynagent.llm.llm import lm


@pytest.fixture
def anthropic_settings(monkeypatch):
    settings = DynagentSettings(
        llm_provider="anthropic",
        llm_model="claude-sonnet-4-6",
        llm_temperature=0.0,
        anthropic_api_key="test-key",
    )
    monkeypatch.setattr(llm_mod, "get_dynagent_settings", lambda: settings)
    return settings


def test_no_args_uses_settings(anthropic_settings):
    with patch.object(llm_mod, "_build_anthropic", return_value="LLM") as build:
        assert lm() == "LLM"
    build.assert_called_once_with("claude-sonnet-4-6", 0.0, "test-key")


def test_model_and_temperature_overrides(anthropic_settings):
    with patch.object(llm_mod, "_build_anthropic", return_value="LLM") as build:
        lm(model="claude-haiku-4-5", temperature=0.3)
    build.assert_called_once_with("claude-haiku-4-5", 0.3, "test-key")


def test_provider_override_routes_to_gemini(anthropic_settings, monkeypatch):
    with patch.object(llm_mod, "_build_gemini", return_value="GEM") as build:
        assert lm(model="gemini-2.0-flash", provider="gemini") == "GEM"
    build.assert_called_once_with("gemini-2.0-flash", 0.0, "")


def test_unknown_provider_raises(anthropic_settings):
    with pytest.raises(ValueError, match="Unsupported LLM provider"):
        lm(provider="openai")


def test_temperature_zero_is_respected(anthropic_settings):
    """0.0 must not be treated as falsy-missing."""
    with patch.object(llm_mod, "_build_anthropic", return_value="LLM") as build:
        lm(temperature=0.0)
    build.assert_called_once_with("claude-sonnet-4-6", 0.0, "test-key")
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd autobots-devtools-shared-lib && make test-one TEST=tests/unit/test_llm_overrides.py`
Expected: FAIL — `TypeError: lm() got an unexpected keyword argument 'model'`

- [ ] **Step 3: Implement the extension**

Replace `lm()` in `llm.py` (keep `_build_gemini`/`_build_anthropic` unchanged):

```python
def lm(
    model: str | None = None,
    provider: str | None = None,
    temperature: float | None = None,
) -> BaseChatModel:
    """Return an LLM instance; each argument defaults to the configured settings value."""
    settings = get_dynagent_settings()
    if provider is None:
        resolved_provider = settings.llm_provider
    else:
        try:
            resolved_provider = LLMProvider(provider)
        except ValueError:
            msg = f"Unsupported LLM provider: {provider}"
            raise ValueError(msg) from None
    resolved_model = model if model is not None else settings.llm_model
    resolved_temperature = temperature if temperature is not None else settings.llm_temperature

    if resolved_provider == LLMProvider.GEMINI:
        return _build_gemini(resolved_model, resolved_temperature, settings.google_api_key)
    if resolved_provider == LLMProvider.ANTHROPIC:
        return _build_anthropic(resolved_model, resolved_temperature, settings.anthropic_api_key)
    msg = f"Unsupported LLM provider: {resolved_provider}"
    raise ValueError(msg)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd autobots-devtools-shared-lib && make test-one TEST=tests/unit/test_llm_overrides.py`
Expected: PASS (all 5)

- [ ] **Step 5: Regression + commit**

Run: `cd autobots-devtools-shared-lib && make test-fast`
Expected: PASS (`lm()` zero-arg behavior unchanged)

```bash
cd autobots-devtools-shared-lib
git add src/autobots_devtools_shared_lib/dynagent/llm/llm.py tests/unit/test_llm_overrides.py
git commit -m "feat(dynagent): lm() accepts model/provider/temperature overrides"
```

---

### Task 4: Model-profile resolution + load-time validation

`resolve_agent_model(meta, agent_name)` resolves a `model:` value — profile name first, then inline `"provider:name"`, then bare model name — through `lm(...)`. `load_agents_config` fails fast on an invalid profile or model ref.

**Files:**
- Create: `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/dynagent/llm/model_resolution.py`
- Modify: `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/dynagent/agents/agent_config_utils.py` (validation hook in `load_agents_config`)
- Test: `autobots-devtools-shared-lib/tests/unit/test_model_resolution.py` (create)

**Interfaces:**
- Produces (`model_resolution.py`):
  - `validate_model_profiles(profiles: dict[str, dict]) -> None` — unknown `provider:` in a profile raises `ValueError`
  - `validate_model_ref(ref: str, profiles: dict[str, dict]) -> None` — ref must be a profile name, a parseable inline `"provider:name"` with a known provider, or a bare model name; otherwise `ValueError`
  - `resolve_model_ref(ref: str | None, profiles: dict[str, dict]) -> BaseChatModel` — `None` → plain `lm()`
  - `resolve_agent_model(meta: Any, agent_name: str) -> BaseChatModel` — reads `meta.model_map` / `meta.model_profiles` (Task 5 supplies those; typed `Any` to avoid an import cycle)
- Consumes: `lm(model=, provider=, temperature=)` (Task 3), `get_model_profiles()` (Task 2), `LLMProvider`.

- [ ] **Step 1: Write the failing tests**

Create `autobots-devtools-shared-lib/tests/unit/test_model_resolution.py`:

```python
# ABOUTME: Unit tests for model-profile / inline model-ref resolution and validation.
# ABOUTME: Covers profile lookup, provider:name parsing, bare names, and load-time failures.

from types import SimpleNamespace
from unittest.mock import patch

import pytest

import autobots_devtools_shared_lib.dynagent.agents.agent_config_utils as cfg
import autobots_devtools_shared_lib.dynagent.llm.model_resolution as mr
from autobots_devtools_shared_lib.dynagent.agents.agent_config_utils import (
    _reset_agent_config,
    load_agents_config,
)
from autobots_devtools_shared_lib.dynagent.config.dynagent_settings import DynagentSettings

PROFILES = {
    "main": {"provider": "anthropic", "name": "claude-sonnet-4-6"},
    "cheap-docs": {"provider": "anthropic", "name": "claude-haiku-4-5", "temperature": 0.3},
    "settings-model": {"temperature": 0.7},
}


def test_profile_name_resolves_through_lm():
    with patch.object(mr, "lm", return_value="LLM") as lm_mock:
        assert mr.resolve_model_ref("cheap-docs", PROFILES) == "LLM"
    lm_mock.assert_called_once_with(
        model="claude-haiku-4-5", provider="anthropic", temperature=0.3
    )


def test_profile_with_omitted_fields_falls_back_to_settings():
    with patch.object(mr, "lm", return_value="LLM") as lm_mock:
        mr.resolve_model_ref("settings-model", PROFILES)
    lm_mock.assert_called_once_with(model=None, provider=None, temperature=0.7)


def test_inline_provider_model_string():
    with patch.object(mr, "lm", return_value="LLM") as lm_mock:
        mr.resolve_model_ref("anthropic:claude-opus-4-8", PROFILES)
    lm_mock.assert_called_once_with(
        model="claude-opus-4-8", provider="anthropic", temperature=None
    )


def test_bare_model_name_uses_settings_provider():
    with patch.object(mr, "lm", return_value="LLM") as lm_mock:
        mr.resolve_model_ref("claude-haiku-4-5", PROFILES)
    lm_mock.assert_called_once_with(model="claude-haiku-4-5", provider=None, temperature=None)


def test_none_ref_returns_plain_lm():
    with patch.object(mr, "lm", return_value="DEFAULT") as lm_mock:
        assert mr.resolve_model_ref(None, PROFILES) == "DEFAULT"
    lm_mock.assert_called_once_with()


def test_resolve_agent_model_reads_meta_maps():
    meta = SimpleNamespace(model_map={"researcher": "main"}, model_profiles=PROFILES)
    with patch.object(mr, "lm", return_value="LLM") as lm_mock:
        assert mr.resolve_agent_model(meta, "researcher") == "LLM"
    lm_mock.assert_called_once_with(
        model="claude-sonnet-4-6", provider="anthropic", temperature=None
    )


def test_validate_model_ref_rejects_unknown_inline_provider():
    with pytest.raises(ValueError, match="openai"):
        mr.validate_model_ref("openai:gpt-5.5", PROFILES)


def test_validate_model_profiles_rejects_unknown_provider():
    with pytest.raises(ValueError, match="bogus"):
        mr.validate_model_profiles({"bad": {"provider": "bogus", "name": "x"}})


def test_load_agents_config_fails_fast_on_bad_model_ref(tmp_path, monkeypatch):
    _reset_agent_config()
    (tmp_path / "deep-agents.yaml").write_text(
        "agents:\n"
        "  assistant:\n"
        "    prompt: assistant\n"
        "    is_default: true\n"
        "    model: openai:gpt-5.5\n"
        "    tools: []\n"
    )
    monkeypatch.setattr(cfg, "get_config_dir", lambda: tmp_path)
    settings = DynagentSettings(agents_config_filename="deep-agents.yaml")
    monkeypatch.setattr(cfg, "get_dynagent_settings", lambda: settings)

    with pytest.raises(ValueError, match="openai"):
        load_agents_config()
    _reset_agent_config()
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd autobots-devtools-shared-lib && make test-one TEST=tests/unit/test_model_resolution.py`
Expected: FAIL — `ModuleNotFoundError: No module named '…model_resolution'`

- [ ] **Step 3: Implement `model_resolution.py`**

```python
# ABOUTME: Resolves per-agent model config (profile name / inline provider:name / bare name).
# ABOUTME: Validation runs at config load; resolution builds BaseChatModel instances via lm().

from typing import Any

from langchain.chat_models import BaseChatModel

from autobots_devtools_shared_lib.dynagent.config.dynagent_settings import LLMProvider
from autobots_devtools_shared_lib.dynagent.llm.llm import lm

_KNOWN_PROVIDERS = {provider.value for provider in LLMProvider}


def validate_model_profiles(profiles: dict[str, dict[str, Any]]) -> None:
    """Fail fast on a models: profile naming an unsupported provider."""
    for profile_name, profile in profiles.items():
        provider = profile.get("provider")
        if provider is not None and provider not in _KNOWN_PROVIDERS:
            msg = (
                f"Model profile '{profile_name}' has unsupported provider '{provider}'. "
                f"Supported providers: {sorted(_KNOWN_PROVIDERS)}"
            )
            raise ValueError(msg)


def validate_model_ref(ref: str, profiles: dict[str, dict[str, Any]]) -> None:
    """Fail fast on a model: value that is neither a known profile nor parseable inline.

    Lookup order matches resolution: profile name first, then inline
    "provider:name" (provider must be supported), then bare model name
    (always valid — resolved against the settings provider).
    """
    if ref in profiles:
        return
    provider, _, model = ref.partition(":")
    if model and provider not in _KNOWN_PROVIDERS:
        msg = (
            f"model: '{ref}' is neither a known profile ({sorted(profiles)}) nor an inline "
            f"ref with a supported provider ({sorted(_KNOWN_PROVIDERS)})"
        )
        raise ValueError(msg)


def resolve_model_ref(
    ref: str | None, profiles: dict[str, dict[str, Any]]
) -> BaseChatModel:
    """Resolve a model ref through lm(); None means the settings-configured default."""
    if ref is None:
        return lm()
    if ref in profiles:
        profile = profiles[ref]
        return lm(
            model=profile.get("name"),
            provider=profile.get("provider"),
            temperature=profile.get("temperature"),
        )
    provider, _, model = ref.partition(":")
    if model:
        return lm(model=model, provider=provider, temperature=None)
    return lm(model=ref, provider=None, temperature=None)


def resolve_agent_model(meta: Any, agent_name: str) -> BaseChatModel:
    """Resolve an agent's configured model, falling back to the settings default."""
    return resolve_model_ref(meta.model_map.get(agent_name), meta.model_profiles)
```

- [ ] **Step 4: Wire validation into `load_agents_config`**

In `agent_config_utils.py`, inside `load_agents_config`, after the agents loop and before assigning `_GLOBAL_AGENT_CONFIG = agents`:

```python
    from autobots_devtools_shared_lib.dynagent.llm.model_resolution import (
        validate_model_profiles,
        validate_model_ref,
    )

    validate_model_profiles(_GLOBAL_MODEL_PROFILES)
    for agent_id, agent_cfg in agents.items():
        if agent_cfg.model is not None:
            try:
                validate_model_ref(agent_cfg.model, _GLOBAL_MODEL_PROFILES)
            except ValueError as e:
                msg = f"Agent '{agent_id}': {e}"
                raise ValueError(msg) from e
```

(Local import avoids an import cycle: `model_resolution` → `llm` → `dynagent_settings` only.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd autobots-devtools-shared-lib && make test-one TEST=tests/unit/test_model_resolution.py`
Expected: PASS (all 9)

- [ ] **Step 6: Regression + commit**

Run: `cd autobots-devtools-shared-lib && make test-fast`
Expected: PASS (react rosters carry no `model:` keys, so validation is a no-op there)

```bash
cd autobots-devtools-shared-lib
git add src/autobots_devtools_shared_lib/dynagent/llm/model_resolution.py \
        src/autobots_devtools_shared_lib/dynagent/agents/agent_config_utils.py \
        tests/unit/test_model_resolution.py
git commit -m "feat(dynagent): named model profiles + per-agent model resolution"
```

---

### Task 5: `AgentMeta` deep-engine maps

**Files:**
- Modify: `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/dynagent/agents/agent_config_utils.py` (map accessors)
- Modify: `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/dynagent/agents/agent_meta.py`
- Test: `autobots-devtools-shared-lib/tests/unit/test_agent_meta_deep_maps.py` (create)

**Interfaces:**
- Produces (accessors in `agent_config_utils`, added to `__all__`): `get_model_map()`, `get_skills_map()`, `get_memory_map()`, `get_interrupt_map()`, `get_permissions_map()`, `get_description_map()`, `get_mcp_map()`, `get_debug_map()`, `get_rubric_map()` — each `{agent_name: field_value}`.
- Produces (attributes on `AgentMeta`): `model_map: dict[str, str | None]`, `skills_map: dict[str, list[str]]`, `memory_map: dict[str, list[str]]`, `interrupt_map: dict[str, dict]`, `permissions_map: dict[str, list]`, `description_map: dict[str, str | None]`, `mcp_map: dict[str, list[str]]`, `debug_map: dict[str, bool]`, `rubric_map: dict[str, dict | None]`, `backend_config: dict | None`, `model_profiles: dict[str, dict]`, `mcp_servers_config: dict[str, dict]`.
- Consumes: Task 2 fields/accessors.

- [ ] **Step 1: Write the failing tests**

Create `autobots-devtools-shared-lib/tests/unit/test_agent_meta_deep_maps.py`:

```python
# ABOUTME: Unit tests for AgentMeta's deep-engine maps.
# ABOUTME: Verifies model/skills/memory/interrupt/permissions/description/mcp/debug/rubric maps.

import pytest

import autobots_devtools_shared_lib.dynagent.agents.agent_config_utils as cfg
from autobots_devtools_shared_lib.dynagent.agents.agent_config_utils import _reset_agent_config
from autobots_devtools_shared_lib.dynagent.agents.agent_meta import AgentMeta
from autobots_devtools_shared_lib.dynagent.config.dynagent_settings import DynagentSettings

DEEP_YAML = """
models:
  main:
    provider: anthropic
    name: claude-sonnet-4-6

default_backend:
  type: state

agents:
  assistant:
    prompt: assistant
    is_default: true
    model: main
    tools: []
    skills: ["skills/"]
    memory: ["AGENTS.md"]
    interrupt_on:
      write_file: true
    debug: true
  researcher:
    prompt: researcher
    description: Deep research on a topic
    tools: []
    rubric:
      max_iterations: 2
"""


@pytest.fixture(autouse=True)
def deep_config(tmp_path, monkeypatch):
    _reset_agent_config()
    AgentMeta.reset()
    (tmp_path / "deep-agents.yaml").write_text(DEEP_YAML)
    (tmp_path / "prompts").mkdir()
    (tmp_path / "prompts" / "assistant.md").write_text("You are an assistant.")
    (tmp_path / "prompts" / "researcher.md").write_text("You are a researcher.")
    monkeypatch.setattr(cfg, "get_config_dir", lambda: tmp_path)
    settings = DynagentSettings(agents_config_filename="deep-agents.yaml")
    monkeypatch.setattr(cfg, "get_dynagent_settings", lambda: settings)
    yield
    _reset_agent_config()
    AgentMeta.reset()


def test_meta_exposes_deep_maps():
    meta = AgentMeta.instance()
    assert meta.model_map == {"assistant": "main", "researcher": None}
    assert meta.skills_map == {"assistant": ["skills/"], "researcher": []}
    assert meta.memory_map == {"assistant": ["AGENTS.md"], "researcher": []}
    assert meta.interrupt_map == {"assistant": {"write_file": True}, "researcher": {}}
    assert meta.permissions_map == {"assistant": [], "researcher": []}
    assert meta.description_map == {"assistant": None, "researcher": "Deep research on a topic"}
    assert meta.mcp_map == {"assistant": [], "researcher": []}
    assert meta.debug_map == {"assistant": True, "researcher": False}
    assert meta.rubric_map == {"assistant": None, "researcher": {"max_iterations": 2}}


def test_meta_exposes_domain_level_blocks():
    meta = AgentMeta.instance()
    assert meta.backend_config == {"type": "state"}
    assert meta.model_profiles == {"main": {"provider": "anthropic", "name": "claude-sonnet-4-6"}}
    assert meta.mcp_servers_config == {}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd autobots-devtools-shared-lib && make test-one TEST=tests/unit/test_agent_meta_deep_maps.py`
Expected: FAIL — `AttributeError: … object has no attribute 'model_map'`

- [ ] **Step 3: Implement accessors + `AgentMeta` attributes**

In `agent_config_utils.py` (after `get_default_agent`; add all nine to `__all__`):

```python
def get_model_map() -> dict[str, str | None]:
    """Return {agent_name: model ref (profile / inline / bare) or None}."""
    return {name: c.model for name, c in load_agents_config().items()}


def get_skills_map() -> dict[str, list[str]]:
    """Return {agent_name: skill source paths}."""
    return {name: c.skills for name, c in load_agents_config().items()}


def get_memory_map() -> dict[str, list[str]]:
    """Return {agent_name: memory (AGENTS.md) paths}."""
    return {name: c.memory for name, c in load_agents_config().items()}


def get_interrupt_map() -> dict[str, dict[str, Any]]:
    """Return {agent_name: interrupt_on config}."""
    return {name: c.interrupt_on for name, c in load_agents_config().items()}


def get_permissions_map() -> dict[str, list[Any]]:
    """Return {agent_name: filesystem permission rules}."""
    return {name: c.permissions for name, c in load_agents_config().items()}


def get_description_map() -> dict[str, str | None]:
    """Return {agent_name: subagent description or None}."""
    return {name: c.description for name, c in load_agents_config().items()}


def get_mcp_map() -> dict[str, list[str]]:
    """Return {agent_name: referenced MCP server names}."""
    return {name: c.mcp_servers for name, c in load_agents_config().items()}


def get_debug_map() -> dict[str, bool]:
    """Return {agent_name: debug flag}."""
    return {name: c.debug for name, c in load_agents_config().items()}


def get_rubric_map() -> dict[str, dict[str, Any] | None]:
    """Return {agent_name: raw rubric config or None}."""
    return {name: c.rubric for name, c in load_agents_config().items()}
```

In `agent_meta.py`, extend the class annotations and `__init__` (keep the existing lines; append):

```python
    model_map: dict[str, str | None]
    skills_map: dict[str, list[str]]
    memory_map: dict[str, list[str]]
    interrupt_map: dict[str, dict[str, Any]]
    permissions_map: dict[str, list[Any]]
    description_map: dict[str, str | None]
    mcp_map: dict[str, list[str]]
    debug_map: dict[str, bool]
    rubric_map: dict[str, dict[str, Any] | None]
    backend_config: dict[str, Any] | None
    model_profiles: dict[str, dict[str, Any]]
    mcp_servers_config: dict[str, dict[str, Any]]
```

and in `__init__` (after `self.default_agent = …`):

```python
        self.model_map = _agent_config.get_model_map()
        self.skills_map = _agent_config.get_skills_map()
        self.memory_map = _agent_config.get_memory_map()
        self.interrupt_map = _agent_config.get_interrupt_map()
        self.permissions_map = _agent_config.get_permissions_map()
        self.description_map = _agent_config.get_description_map()
        self.mcp_map = _agent_config.get_mcp_map()
        self.debug_map = _agent_config.get_debug_map()
        self.rubric_map = _agent_config.get_rubric_map()
        self.backend_config = _agent_config.get_default_backend_config()
        self.model_profiles = _agent_config.get_model_profiles()
        self.mcp_servers_config = _agent_config.get_mcp_servers_config()
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd autobots-devtools-shared-lib && make test-one TEST=tests/unit/test_agent_meta_deep_maps.py`
Expected: PASS (both)

- [ ] **Step 5: Regression + commit**

Run: `cd autobots-devtools-shared-lib && make test-fast`
Expected: PASS (existing `test_agent_meta.py` still green — new maps are additive)

```bash
cd autobots-devtools-shared-lib
git add src/autobots_devtools_shared_lib/dynagent/agents/agent_config_utils.py \
        src/autobots_devtools_shared_lib/dynagent/agents/agent_meta.py \
        tests/unit/test_agent_meta_deep_maps.py
git commit -m "feat(dynagent): AgentMeta deep-engine maps (model/skills/memory/backend/…)"
```

---

### Task 6: Backend registry — `state`/`filesystem` + `resolve_backend`

**Files:**
- Create: `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/dynagent/agents/deep_backend.py`
- Test: `autobots-devtools-shared-lib/tests/unit/test_deep_backend.py` (create)

**Interfaces:**
- Produces: `resolve_backend(backend_config: dict | None, override: Any = None, store: Any = None) -> BackendProtocol | BackendFactory | None`.
  - `override` (a live backend instance/factory from the `backend=` kwarg) wins over YAML.
  - `None`/missing config → `None` (deepagents defaults to `StateBackend`).
  - `type: state` → `None`; `type: filesystem` → `FilesystemBackend(root_dir=…)`, creating `root_dir` if missing.
  - Unknown `type:` → `ValueError` listing valid choices.
- Internal: `_BACKEND_REGISTRY: dict[str, Callable]`, `_build_backend(cfg, *, store=None)` — Task 12 extends the registry with `fserver`/`store`/`composite`.

- [ ] **Step 1: Write the failing tests**

Create `autobots-devtools-shared-lib/tests/unit/test_deep_backend.py`:

```python
# ABOUTME: Unit tests for the deep-engine backend registry.
# ABOUTME: Covers state/filesystem resolution, override precedence, and unknown-type failure.

import pytest
from deepagents.backends import FilesystemBackend

from autobots_devtools_shared_lib.dynagent.agents.deep_backend import resolve_backend


def test_no_config_returns_none():
    assert resolve_backend(None) is None
    assert resolve_backend({}) is None


def test_state_type_returns_none():
    assert resolve_backend({"type": "state"}) is None


def test_filesystem_type_builds_backend_and_creates_root(tmp_path):
    root = tmp_path / "ws" / "nested"
    backend = resolve_backend({"type": "filesystem", "root_dir": str(root)})
    assert isinstance(backend, FilesystemBackend)
    assert root.is_dir()


def test_override_instance_wins(tmp_path):
    sentinel = FilesystemBackend(root_dir=str(tmp_path))
    resolved = resolve_backend({"type": "state"}, override=sentinel)
    assert resolved is sentinel


def test_unknown_type_fails_fast_listing_choices():
    with pytest.raises(ValueError, match="filesystem"):
        resolve_backend({"type": "s3"})
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd autobots-devtools-shared-lib && make test-one TEST=tests/unit/test_deep_backend.py`
Expected: FAIL — `ModuleNotFoundError: No module named '…deep_backend'`

- [ ] **Step 3: Implement `deep_backend.py`**

```python
# ABOUTME: Backend registry for the deep engine's virtual filesystem.
# ABOUTME: Resolves deep-agents.yaml default_backend config into deepagents backends.

from collections.abc import Callable
from pathlib import Path
from typing import Any

from deepagents.backends import FilesystemBackend

from autobots_devtools_shared_lib.common.observability import get_logger

logger = get_logger(__name__)


def _build_state(cfg: dict[str, Any], **_kw: Any) -> None:
    """deepagents defaults to StateBackend when backend is None."""
    return None


def _build_filesystem(cfg: dict[str, Any], **_kw: Any) -> FilesystemBackend:
    root_dir = cfg.get("root_dir")
    if root_dir:
        Path(root_dir).mkdir(parents=True, exist_ok=True)
    return FilesystemBackend(root_dir=root_dir)


_BACKEND_REGISTRY: dict[str, Callable[..., Any]] = {
    "state": _build_state,
    "filesystem": _build_filesystem,
}


def _build_backend(cfg: dict[str, Any], *, store: Any = None) -> Any:
    backend_type = cfg.get("type", "state")
    builder = _BACKEND_REGISTRY.get(backend_type)
    if builder is None:
        msg = (
            f"Unknown backend type '{backend_type}'. "
            f"Valid types: {sorted(_BACKEND_REGISTRY)}"
        )
        raise ValueError(msg)
    return builder(cfg, store=store)


def resolve_backend(
    backend_config: dict[str, Any] | None,
    override: Any = None,
    store: Any = None,
) -> Any:
    """Resolve the domain backend; an explicit backend= kwarg wins over YAML."""
    if override is not None:
        return override
    if not backend_config:
        return None
    backend = _build_backend(backend_config, store=store)
    logger.info(f"resolve_backend: type={backend_config.get('type', 'state')}")
    return backend
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd autobots-devtools-shared-lib && make test-one TEST=tests/unit/test_deep_backend.py`
Expected: PASS (all 5)

- [ ] **Step 5: Commit**

```bash
cd autobots-devtools-shared-lib
git add src/autobots_devtools_shared_lib/dynagent/agents/deep_backend.py tests/unit/test_deep_backend.py
git commit -m "feat(dynagent): backend registry (state/filesystem) for the deep engine"
```

---

### Task 7: `ToolResilienceMiddleware`

A tool exception becomes a `ToolMessage(status="error")` with a truncated summary; `asyncio.CancelledError` is re-raised. Always-on for the deep engine (wired in Task 8).

**Files:**
- Create: `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/dynagent/middleware/__init__.py`
- Create: `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/dynagent/middleware/tool_resilience.py`
- Test: `autobots-devtools-shared-lib/tests/unit/test_tool_resilience.py` (create)

**Interfaces:**
- Produces: `ToolResilienceMiddleware(AgentMiddleware)` implementing `wrap_tool_call` / `awrap_tool_call`. Exported from `dynagent.middleware`.
- Consumes: `langchain.agents.middleware.types.AgentMiddleware`, `ToolCallRequest` (re-exported there from `langgraph.prebuilt.tool_node`); `request.tool_call` is a dict with `"name"` and `"id"`.

- [ ] **Step 1: Write the failing tests**

Create `autobots-devtools-shared-lib/tests/unit/test_tool_resilience.py`:

```python
# ABOUTME: Unit tests for ToolResilienceMiddleware.
# ABOUTME: Tool exceptions become error ToolMessages; CancelledError propagates.

import asyncio
from types import SimpleNamespace

import pytest
from langchain_core.messages import ToolMessage

from autobots_devtools_shared_lib.dynagent.middleware.tool_resilience import (
    ToolResilienceMiddleware,
)


def _request():
    return SimpleNamespace(tool_call={"name": "my_tool", "id": "call-1", "args": {}})


def test_success_passes_through():
    mw = ToolResilienceMiddleware()
    ok = ToolMessage(content="fine", tool_call_id="call-1")
    assert mw.wrap_tool_call(_request(), lambda _req: ok) is ok


def test_exception_becomes_error_tool_message():
    mw = ToolResilienceMiddleware()

    def boom(_req):
        raise RuntimeError("sidecar unreachable")

    msg = mw.wrap_tool_call(_request(), boom)
    assert isinstance(msg, ToolMessage)
    assert msg.status == "error"
    assert msg.tool_call_id == "call-1"
    assert "my_tool" in msg.content
    assert "sidecar unreachable" in msg.content


def test_error_summary_is_truncated():
    mw = ToolResilienceMiddleware()

    def boom(_req):
        raise RuntimeError("x" * 5000)

    msg = mw.wrap_tool_call(_request(), boom)
    assert len(msg.content) < 1000


def test_cancelled_error_is_reraised():
    mw = ToolResilienceMiddleware()

    def cancel(_req):
        raise asyncio.CancelledError

    with pytest.raises(asyncio.CancelledError):
        mw.wrap_tool_call(_request(), cancel)


async def test_async_exception_becomes_error_tool_message():
    mw = ToolResilienceMiddleware()

    async def boom(_req):
        raise ValueError("bad input")

    msg = await mw.awrap_tool_call(_request(), boom)
    assert msg.status == "error"
    assert "bad input" in msg.content


async def test_async_cancelled_error_is_reraised():
    mw = ToolResilienceMiddleware()

    async def cancel(_req):
        raise asyncio.CancelledError

    with pytest.raises(asyncio.CancelledError):
        await mw.awrap_tool_call(_request(), cancel)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd autobots-devtools-shared-lib && make test-one TEST=tests/unit/test_tool_resilience.py`
Expected: FAIL — `ModuleNotFoundError: No module named '…dynagent.middleware'`

- [ ] **Step 3: Implement the package and middleware**

`dynagent/middleware/__init__.py`:

```python
# ABOUTME: Shared AgentMiddleware implementations for dynagent engines.
# ABOUTME: Currently: tool-execution resilience for the deep engine.

from autobots_devtools_shared_lib.dynagent.middleware.tool_resilience import (
    ToolResilienceMiddleware,
)

__all__ = ["ToolResilienceMiddleware"]
```

`dynagent/middleware/tool_resilience.py`:

```python
# ABOUTME: Middleware that converts tool exceptions into error ToolMessages.
# ABOUTME: Keeps the deep-agent run alive so the model can adjust inputs and retry.

import asyncio
from collections.abc import Awaitable, Callable
from typing import Any

from langchain.agents.middleware.types import AgentMiddleware, ToolCallRequest
from langchain_core.messages import ToolMessage

from autobots_devtools_shared_lib.common.observability import get_logger

logger = get_logger(__name__)

_MAX_ERROR_CHARS = 500


def _error_tool_message(request: ToolCallRequest, exc: Exception) -> ToolMessage:
    tool_name = request.tool_call.get("name", "unknown")
    summary = f"{type(exc).__name__}: {exc}"[:_MAX_ERROR_CHARS]
    logger.warning(f"Tool '{tool_name}' raised; returning error ToolMessage: {summary}")
    return ToolMessage(
        content=(
            f"Tool '{tool_name}' failed: {summary}. "
            "Adjust the inputs or take a different approach."
        ),
        tool_call_id=request.tool_call.get("id", ""),
        name=tool_name,
        status="error",
    )


class ToolResilienceMiddleware(AgentMiddleware):
    """Convert tool exceptions to error ToolMessages instead of aborting the run."""

    def wrap_tool_call(
        self,
        request: ToolCallRequest,
        handler: Callable[[ToolCallRequest], Any],
    ) -> Any:
        try:
            return handler(request)
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # noqa: BLE001 — resilience boundary by design
            return _error_tool_message(request, exc)

    async def awrap_tool_call(
        self,
        request: ToolCallRequest,
        handler: Callable[[ToolCallRequest], Awaitable[Any]],
    ) -> Any:
        try:
            return await handler(request)
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # noqa: BLE001 — resilience boundary by design
            return _error_tool_message(request, exc)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd autobots-devtools-shared-lib && make test-one TEST=tests/unit/test_tool_resilience.py`
Expected: PASS (all 6)

- [ ] **Step 5: Commit**

```bash
cd autobots-devtools-shared-lib
git add src/autobots_devtools_shared_lib/dynagent/middleware tests/unit/test_tool_resilience.py
git commit -m "feat(dynagent): ToolResilienceMiddleware for the deep engine"
```

---

### Task 8: Factory P1 wiring — skills, memory, model, backend, resilience

End state of P1: `create_base_deepagent` reaches parity with the blog reference `agent.py` (skills + memory + filesystem backend + explicit model), entirely from YAML.

**Files:**
- Modify: `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/dynagent/agents/base_deepagent.py`
- Modify: `autobots-devtools-shared-lib/tests/unit/test_base_deepagent.py` (fixture + new assertions)

**Interfaces:**
- Consumes: `resolve_agent_model` (Task 4), `resolve_backend` (Task 6), `ToolResilienceMiddleware` (Task 7), `AgentMeta` maps (Task 5).
- Produces: `create_base_deepagent(checkpointer=None, initial_agent_name=None, state_schema=DynaDeepAgent, prompt_values=None, subagents=None, backend=None)` forwarding `skills=`, `memory=`, `backend=`, per-agent `model=`, `middleware=[ToolResilienceMiddleware()]` to `create_deep_agent`. Later tasks extend this same signature (Task 12: `store`; Task 15: `middleware`, `cache`, `context_schema`, `debug`).

- [ ] **Step 1: Update the fake-meta fixture and add failing tests**

In `tests/unit/test_base_deepagent.py`, replace the two fixtures with:

```python
@pytest.fixture
def fake_meta():
    meta = MagicMock()
    meta.prompt_map = {"assistant": "You are an assistant writing {language}."}
    meta.tool_map = {"assistant": ["tool_a", "tool_b"]}
    meta.input_schema_map = {"assistant": {}}
    meta.output_schema_map = {"assistant": None}
    meta.model_map = {"assistant": None}
    meta.skills_map = {"assistant": []}
    meta.memory_map = {"assistant": []}
    meta.interrupt_map = {"assistant": {}}
    meta.permissions_map = {"assistant": []}
    meta.description_map = {"assistant": None}
    meta.mcp_map = {"assistant": []}
    meta.debug_map = {"assistant": False}
    meta.rubric_map = {"assistant": None}
    meta.backend_config = None
    meta.model_profiles = {}
    meta.mcp_servers_config = {}
    return meta


@pytest.fixture
def patched(fake_meta):
    with (
        patch.object(bd.AgentMeta, "instance", return_value=fake_meta),
        patch.object(bd, "get_default_agent", return_value="assistant"),
        patch.object(bd, "resolve_agent_model", return_value="MODEL"),
        patch.object(bd, "create_deep_agent", return_value="GRAPH") as mock_cda,
    ):
        yield mock_cda
```

Append these tests (imports at top: `from autobots_devtools_shared_lib.dynagent.middleware.tool_resilience import ToolResilienceMiddleware`):

```python
def test_skills_and_memory_forwarded(patched, fake_meta):
    fake_meta.skills_map = {"assistant": ["skills/"]}
    fake_meta.memory_map = {"assistant": ["AGENTS.md"]}
    bd.create_base_deepagent()
    kwargs = patched.call_args.kwargs
    assert kwargs["skills"] == ["skills/"]
    assert kwargs["memory"] == ["AGENTS.md"]


def test_empty_skills_and_memory_forward_none(patched):
    bd.create_base_deepagent()
    kwargs = patched.call_args.kwargs
    assert kwargs["skills"] is None
    assert kwargs["memory"] is None


def test_backend_resolved_from_meta_config(patched, fake_meta, tmp_path):
    fake_meta.backend_config = {"type": "filesystem", "root_dir": str(tmp_path / "ws")}
    bd.create_base_deepagent()
    kwargs = patched.call_args.kwargs
    from deepagents.backends import FilesystemBackend

    assert isinstance(kwargs["backend"], FilesystemBackend)


def test_backend_kwarg_overrides_yaml(patched, fake_meta):
    sentinel = object()
    fake_meta.backend_config = {"type": "state"}
    bd.create_base_deepagent(backend=sentinel)
    assert patched.call_args.kwargs["backend"] is sentinel


def test_resilience_middleware_always_on(patched):
    bd.create_base_deepagent()
    middleware = patched.call_args.kwargs["middleware"]
    assert len(middleware) == 1
    assert isinstance(middleware[0], ToolResilienceMiddleware)


def test_model_resolved_per_agent(patched):
    bd.create_base_deepagent()
    assert patched.call_args.kwargs["model"] == "MODEL"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd autobots-devtools-shared-lib && make test-one TEST=tests/unit/test_base_deepagent.py`
Expected: new tests FAIL (`KeyError: 'skills'` / `AttributeError: … 'resolve_agent_model'`); the four pre-existing tests must still pass once the `patched` fixture change lands (they only assert model/tools/prompt/name).

- [ ] **Step 3: Implement the factory wiring**

In `base_deepagent.py`, update imports:

```python
from autobots_devtools_shared_lib.dynagent.agents.deep_backend import resolve_backend
from autobots_devtools_shared_lib.dynagent.llm.model_resolution import resolve_agent_model
from autobots_devtools_shared_lib.dynagent.middleware.tool_resilience import (
    ToolResilienceMiddleware,
)
```

(drop the now-unused `from …llm.llm import lm` import), extend the signature:

```python
def create_base_deepagent(
    checkpointer: Any = None,
    initial_agent_name: str | None = None,
    state_schema: type[DeepAgentState] = DynaDeepAgent,
    prompt_values: dict[str, Any] | None = None,
    subagents: Sequence[SubAgent] | None = None,
    backend: Any = None,
) -> CompiledStateGraph:
```

and replace the body from `system_prompt = …` down:

```python
    system_prompt = _resolve_system_prompt(meta, agent_name, prompt_values)
    tools = meta.tool_map.get(agent_name, [])

    return create_deep_agent(
        model=resolve_agent_model(meta, agent_name),
        tools=tools,
        system_prompt=system_prompt,
        state_schema=state_schema,
        checkpointer=checkpointer,
        name=agent_name,
        skills=meta.skills_map.get(agent_name) or None,
        memory=meta.memory_map.get(agent_name) or None,
        backend=resolve_backend(meta.backend_config, override=backend),
        subagents=list(subagents) if subagents else None,
        middleware=[ToolResilienceMiddleware()],
    )
```

Update the docstring's Args section to document `backend` ("Live backend instance/factory override; wins over the YAML `default_backend`.").

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd autobots-devtools-shared-lib && make test-one TEST=tests/unit/test_base_deepagent.py`
Expected: PASS (10 tests)

- [ ] **Step 5: Full check + commit (P1 complete)**

Run: `cd autobots-devtools-shared-lib && make check-format && make type-check && make test-fast`
Expected: all PASS

```bash
cd autobots-devtools-shared-lib
git add src/autobots_devtools_shared_lib/dynagent/agents/base_deepagent.py tests/unit/test_base_deepagent.py
git commit -m "feat(dynagent): P1 deep-engine parity — skills/memory/model/backend from YAML"
```

---

## Phase P2 — `FileServerBackend` + composite/store routes

### Task 9: Raw-function extraction in `fserver_client_utils`

Thin raw functions (return bytes/dicts, raise `httpx` errors); existing tool functions become wrappers with **byte-identical** return strings. Existing MER tools are untouched.

**Files:**
- Modify: `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/common/utils/fserver_client_utils.py`
- Test: `autobots-devtools-shared-lib/tests/unit/common/test_fserver_raw.py` (create)

**Interfaces:**
- Produces (same module; `workspace_context` is now a parsed `dict`, not a JSON string):
  - `raw_list_files(base_path: str = "", workspace_context: dict | None = None, session_id: str | None = None) -> list` — `POST /listFiles`, returns the `files` list
  - `raw_read_file(file_name: str, workspace_context: dict | None = None, session_id: str | None = None) -> bytes` — `POST /readFile`, returns raw body
  - `raw_write_file(file_name: str, content: bytes, workspace_context: dict | None = None, session_id: str | None = None) -> dict` — `POST /writeFile` (base64 payload), returns the result JSON (`{"path": …, "size_bytes": …}`)
  - `raw_create_download_link(file_name: str, workspace_context: dict | None = None, session_id: str | None = None) -> bytes` — `POST /createDownloadLink`, returns raw body
  - All raise `httpx.HTTPStatusError` / `httpx.HTTPError` on failure.
- Unchanged public behavior: `list_files`, `read_file`, `write_file`, `create_download_link` keep their exact signatures, log lines, and return strings (success and error forms). `move_file` and `get_disk_usage` are not refactored.

- [ ] **Step 1: Write the failing tests**

Create `autobots-devtools-shared-lib/tests/unit/common/test_fserver_raw.py`:

```python
# ABOUTME: Unit tests for the raw file-server client layer (bytes/dicts + raised errors).
# ABOUTME: Also locks the tool wrappers' byte-identical success/error strings.

import base64
import json

import httpx
import pytest

import autobots_devtools_shared_lib.common.utils.fserver_client_utils as fs


@pytest.fixture
def mock_server(monkeypatch):
    """Route sidecar POSTs through an httpx.MockTransport; handlers keyed by URL path."""
    handlers: dict = {}

    def _dispatch(request: httpx.Request) -> httpx.Response:
        handler = handlers.get(request.url.path)
        if handler is None:
            return httpx.Response(404, text="no handler")
        return handler(request)

    transport = httpx.MockTransport(_dispatch)
    real_client = httpx.Client
    monkeypatch.setattr(
        fs.httpx, "Client", lambda **kwargs: real_client(transport=transport)
    )
    return handlers


def test_raw_list_files_returns_list(mock_server):
    mock_server["/listFiles"] = lambda req: httpx.Response(
        200, json={"files": ["a.txt", "dir/b.txt"]}
    )
    assert fs.raw_list_files() == ["a.txt", "dir/b.txt"]


def test_raw_list_files_sends_workspace_context(mock_server):
    seen = {}

    def handler(req):
        seen.update(json.loads(req.content))
        return httpx.Response(200, json={"files": []})

    mock_server["/listFiles"] = handler
    fs.raw_list_files("sub", {"jira_number": "J-1"}, session_id="s1")
    assert seen["path"] == "sub"
    assert seen["workspace_context"] == {"jira_number": "J-1"}
    assert seen["session_id"] == "s1"


def test_raw_read_file_returns_bytes(mock_server):
    mock_server["/readFile"] = lambda req: httpx.Response(200, content=b"hello")
    assert fs.raw_read_file("a.txt") == b"hello"


def test_raw_read_file_raises_on_404(mock_server):
    mock_server["/readFile"] = lambda req: httpx.Response(404, text="not found")
    with pytest.raises(httpx.HTTPStatusError):
        fs.raw_read_file("missing.txt")


def test_raw_write_file_posts_base64_and_returns_result(mock_server):
    seen = {}

    def handler(req):
        seen.update(json.loads(req.content))
        return httpx.Response(200, json={"path": "a.txt", "size_bytes": 5})

    mock_server["/writeFile"] = handler
    result = fs.raw_write_file("a.txt", b"hello")
    assert result == {"path": "a.txt", "size_bytes": 5}
    assert base64.b64decode(seen["file_content"]) == b"hello"


def test_raw_create_download_link_returns_bytes(mock_server):
    mock_server["/createDownloadLink"] = lambda req: httpx.Response(200, content=b"http://dl")
    assert fs.raw_create_download_link("a.txt") == b"http://dl"


# --- wrapper strings stay byte-identical ---


def test_list_files_wrapper_success_string(mock_server):
    mock_server["/listFiles"] = lambda req: httpx.Response(200, json={"files": ["a.txt"]})
    assert fs.list_files() == "['a.txt']"


def test_read_file_wrapper_error_string(mock_server):
    mock_server["/readFile"] = lambda req: httpx.Response(404, text="gone")
    assert fs.read_file("x.txt") == "Error reading file: HTTP 404 - gone"


def test_write_file_wrapper_success_string(mock_server):
    mock_server["/writeFile"] = lambda req: httpx.Response(
        200, json={"path": "a.txt", "size_bytes": 5}
    )
    assert fs.write_file("a.txt", "hello") == (
        "File written successfully: a.txt, size: 5 bytes"
    )


def test_read_file_wrapper_binary_returns_base64(mock_server):
    mock_server["/readFile"] = lambda req: httpx.Response(200, content=b"\x89PNG\x0d\x0a")
    assert fs.read_file("img.png") == base64.b64encode(b"\x89PNG\x0d\x0a").decode("utf-8")
```

If `tests/unit/common/` lacks an `__init__.py` and pytest reports a collection error, add an empty `__init__.py` matching the sibling test-package convention.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd autobots-devtools-shared-lib && make test-one TEST=tests/unit/common/test_fserver_raw.py`
Expected: FAIL — `AttributeError: module … has no attribute 'raw_list_files'`

- [ ] **Step 3: Implement the raw layer and rewrite the wrappers**

In `fserver_client_utils.py`, add the raw functions after `_parse_workspace_context`:

```python
def raw_list_files(
    base_path: str = "",
    workspace_context: dict | None = None,
    session_id: str | None = None,
) -> list:
    """List files via the sidecar. Raises httpx errors on failure."""
    payload: dict = {
        "path": base_path if base_path else None,
        "workspace_context": workspace_context or {},
    }
    if session_id:
        payload.setdefault("session_id", session_id)
    with (
        traced_http_call("listFiles", session_id=session_id) as trace_headers,
        httpx.Client() as client,
    ):
        response = client.post(
            f"{FILE_SERVER_BASE_URL}/listFiles",
            json=payload,
            headers=trace_headers,
            timeout=30.0,
        )
        response.raise_for_status()
        result = response.json()
    return result.get("files", [])


def raw_read_file(
    file_name: str,
    workspace_context: dict | None = None,
    session_id: str | None = None,
) -> bytes:
    """Read a file via the sidecar; returns the raw body. Raises httpx errors on failure."""
    payload: dict = {
        "fileName": file_name,
        "workspace_context": workspace_context or {},
    }
    if session_id:
        payload.setdefault("session_id", session_id)
    with (
        traced_http_call("readFile", session_id=session_id) as trace_headers,
        httpx.Client() as client,
    ):
        response = client.post(
            f"{FILE_SERVER_BASE_URL}/readFile",
            json=payload,
            headers=trace_headers,
            timeout=30.0,
        )
        response.raise_for_status()
        return response.content


def raw_write_file(
    file_name: str,
    content: bytes,
    workspace_context: dict | None = None,
    session_id: str | None = None,
) -> dict:
    """Write a file via the sidecar; returns the result JSON. Raises httpx errors on failure."""
    payload: dict = {
        "file_name": file_name,
        "file_content": base64.b64encode(content).decode("utf-8"),
        "workspace_context": workspace_context or {},
    }
    if session_id:
        payload.setdefault("session_id", session_id)
    with (
        traced_http_call("writeFile", session_id=session_id) as trace_headers,
        httpx.Client() as client,
    ):
        response = client.post(
            f"{FILE_SERVER_BASE_URL}/writeFile",
            json=payload,
            headers=trace_headers,
            timeout=30.0,
        )
        response.raise_for_status()
        return response.json()


def raw_create_download_link(
    file_name: str,
    workspace_context: dict | None = None,
    session_id: str | None = None,
) -> bytes:
    """Create a download link via the sidecar; returns the raw body. Raises httpx errors."""
    payload: dict = {
        "fileName": file_name,
        "workspace_context": workspace_context or {},
    }
    if session_id:
        payload.setdefault("session_id", session_id)
    with (
        traced_http_call("createDownloadLink", session_id=session_id) as trace_headers,
        httpx.Client() as client,
    ):
        response = client.post(
            f"{FILE_SERVER_BASE_URL}/createDownloadLink",
            json=payload,
            headers=trace_headers,
            timeout=30.0,
        )
        response.raise_for_status()
        return response.content
```

Then rewrite the four tool wrappers to delegate. Keep each wrapper's docstring, opening `logger.info` line, success log lines, and every return string **exactly as they are today**:

```python
def list_files(
    base_path: str = "", workspace_context: str = "{}", session_id: str | None = None
) -> str:
    """
    List all files in the specified directory or workspace.

    Args:
        base_path: Optional subdirectory to list from.
        workspace_context: Optional JSON object for workspace/scoping (e.g. {"agent_name": "...", "user_name": "...", "repo_name": "...", "jira_number": "..."}). Merged into the API request as-is.
        session_id: Optional session ID for trace correlation

    Returns:
        JSON string of file paths
    """
    logger.info(
        "Listing files with base_path='%s', workspace_context=%s", base_path, workspace_context
    )
    try:
        files = raw_list_files(
            base_path, _parse_workspace_context(workspace_context), session_id
        )
        logger.info(f"Successfully listed {len(files)} files")
        return str(files)
    except httpx.HTTPStatusError as e:
        logger.exception(f"HTTP error listing files: {e.response.status_code} - {e.response.text}")
        return f"Error listing files: HTTP {e.response.status_code} - {e.response.text}"
    except Exception as e:
        logger.exception("Error listing files")
        return f"Error listing files: {e!s}"


def read_file(file_name: str, workspace_context: str = "{}", session_id: str | None = None) -> str:
    """
    Read the content of a file.

    Args:
        file_name: Relative file path.
        workspace_context: Optional JSON object for workspace/scoping (e.g. {"agent_name": "...", "user_name": "...", "repo_name": "...", "jira_number": "..."}). Merged into the API request as-is.
        session_id: Optional session ID for trace correlation

    Returns:
        File content as string (UTF-8 for text files, base64 for binary files)
    """
    logger.info("Reading file '%s' with workspace_context=%s", file_name, workspace_context)
    try:
        content = raw_read_file(
            file_name, _parse_workspace_context(workspace_context), session_id
        )
        logger.info(f"Successfully read file '{file_name}' ({len(content)} bytes)")
        try:
            return content.decode("utf-8")
        except UnicodeDecodeError:
            logger.info(f"File '{file_name}' is binary, returning as base64")
            return base64.b64encode(content).decode("utf-8")
    except httpx.HTTPStatusError as e:
        logger.exception(
            f"HTTP error reading file '{file_name}': {e.response.status_code} - {e.response.text}"
        )
        return f"Error reading file: HTTP {e.response.status_code} - {e.response.text}"
    except Exception as e:
        logger.exception("Error reading file '%s'", file_name)
        return f"Error reading file: {e!s}"


def write_file(
    file_name: str, content: str, workspace_context: str = "{}", session_id: str | None = None
) -> str:
    """
    Write content to a file.

    Args:
        file_name: Relative file path.
        content: File content as string.
        workspace_context: Optional JSON object for workspace/scoping (e.g. {"agent_name": "...", "user_name": "...", "repo_name": "...", "jira_number": "..."}). Merged into the API request as-is.
        session_id: Optional session ID for trace correlation

    Returns:
        Success message with file path and size
    """
    logger.info("Writing to file '%s' with workspace_context=%s", file_name, workspace_context)
    try:
        result = raw_write_file(
            file_name,
            content.encode("utf-8"),
            _parse_workspace_context(workspace_context),
            session_id,
        )
        logger.info(
            f"Successfully wrote file '{result['path']}' with size {result['size_bytes']} bytes"
        )
        return f"File written successfully: {result['path']}, size: {result['size_bytes']} bytes"
    except httpx.HTTPStatusError as e:
        logger.exception(
            f"HTTP error writing file '{file_name}': {e.response.status_code} - {e.response.text}"
        )
        return f"Error writing file: HTTP {e.response.status_code} - {e.response.text}"
    except Exception as e:
        logger.exception("Error writing file '%s'", file_name)
        return f"Error writing file: {e!s}"


def create_download_link(
    file_name: str, workspace_context: str = "{}", session_id: str | None = None
) -> str:
    """
    Create a download link for the file.

    Args:
        file_name: Relative file path.
        workspace_context: Optional JSON object for workspace/scoping (e.g. {"agent_name": "...", "user_name": "...", "repo_name": "...", "jira_number": "..."}). Merged into the API request as-is.
        session_id: Optional session ID for trace correlation

    Returns:
        Creates a download link for the file
    """
    logger.info(
        "Creating download link for '%s' with workspace_context=%s", file_name, workspace_context
    )
    try:
        content = raw_create_download_link(
            file_name, _parse_workspace_context(workspace_context), session_id
        )
        logger.info(f"Successfully read file '{file_name}' ({len(content)} bytes)")
        try:
            return content.decode("utf-8")
        except UnicodeDecodeError:
            logger.info(f"File '{file_name}' is binary, returning as base64")
            return base64.b64encode(content).decode("utf-8")
    except httpx.HTTPStatusError as e:
        logger.exception(
            f"HTTP error reading file '{file_name}': {e.response.status_code} - {e.response.text}"
        )
        return f"Error reading file: HTTP {e.response.status_code} - {e.response.text}"
    except Exception as e:
        logger.exception("Error reading file '%s'", file_name)
        return f"Error reading file: {e!s}"
```

(Note: `create_download_link`'s "Successfully read file" log text and "Error reading file" strings are today's behavior — preserved verbatim on purpose. One accepted delta: the inner `logger.info("Payload: …")` debug line in today's `read_file` moves out of the wrapper.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd autobots-devtools-shared-lib && make test-one TEST=tests/unit/common/test_fserver_raw.py`
Expected: PASS (all 10)

- [ ] **Step 5: Regression + commit**

Run: `cd autobots-devtools-shared-lib && make test-fast`
Expected: PASS. Also run MER's suite since it consumes these tools: `cd ../autobots-agents-mer && make test-fast` — expected PASS.

```bash
cd autobots-devtools-shared-lib
git add src/autobots_devtools_shared_lib/common/utils/fserver_client_utils.py tests/unit/common/test_fserver_raw.py
git commit -m "refactor(common): extract raw file-server client layer under existing tools"
```

---

### Task 10: `FileServerBackend` — direct methods (`ls`, `read`, `write`, `upload_files`, `download_files`)

**Files:**
- Create: `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/dynagent/agents/fserver_backend.py`
- Test: `autobots-devtools-shared-lib/tests/unit/test_fserver_backend.py` (create)

**Interfaces:**
- Produces:
  - `FileServerBackend(session_id: str | None = None, workspace_context: dict | None = None)` implementing `deepagents.backends.protocol.BackendProtocol`. Virtual paths are absolute (`/dir/f.txt`); the leading `/` is stripped for sidecar calls. Async variants come free from `BackendProtocol`'s `asyncio.to_thread` defaults.
  - `workspace_context_from_state(state) -> dict` — picks `agent_name`, `user_name`, `repo_name`, `jira_number` from runtime state when present.
- Consumes: raw functions (Task 9); `LsResult`/`ReadResult`/`WriteResult`/`FileData`/`FileInfo`/`FileUploadResponse`/`FileDownloadResponse`/`FILE_NOT_FOUND` from `deepagents.backends.protocol`.
- Semantics locked to deepagents 0.6.12: `write` **errors if the file already exists** (same message shape as `StateBackend`/`FilesystemBackend`); `read` returns a raw `FileData` window (line-number formatting is the middleware's job); binary reads return base64 `FileData`.

- [ ] **Step 1: Write the failing tests**

Create `autobots-devtools-shared-lib/tests/unit/test_fserver_backend.py`:

```python
# ABOUTME: Unit tests for FileServerBackend direct methods against faked raw functions.
# ABOUTME: Covers ls windowing, read slicing/binary, write-exists semantics, batch up/download.

import base64

import httpx
import pytest

import autobots_devtools_shared_lib.dynagent.agents.fserver_backend as fb
from autobots_devtools_shared_lib.dynagent.agents.fserver_backend import (
    FileServerBackend,
    workspace_context_from_state,
)


def _http_error(status: int) -> httpx.HTTPStatusError:
    request = httpx.Request("POST", "http://fs/x")
    response = httpx.Response(status, request=request, text="err")
    return httpx.HTTPStatusError("boom", request=request, response=response)


@pytest.fixture
def fake_store(monkeypatch):
    """In-memory dict standing in for the sidecar, wired through the raw functions."""
    store: dict[str, bytes] = {}

    def fake_list(base_path="", workspace_context=None, session_id=None):
        return sorted(store)

    def fake_read(file_name, workspace_context=None, session_id=None):
        if file_name not in store:
            raise _http_error(404)
        return store[file_name]

    def fake_write(file_name, content, workspace_context=None, session_id=None):
        store[file_name] = content
        return {"path": file_name, "size_bytes": len(content)}

    monkeypatch.setattr(fb, "raw_list_files", fake_list)
    monkeypatch.setattr(fb, "raw_read_file", fake_read)
    monkeypatch.setattr(fb, "raw_write_file", fake_write)
    return store


def test_workspace_context_from_state_picks_known_keys():
    state = {"session_id": "s", "jira_number": "J-1", "repo_name": "r", "other": "x"}
    assert workspace_context_from_state(state) == {"jira_number": "J-1", "repo_name": "r"}


def test_ls_lists_direct_children_and_subdirs(fake_store):
    fake_store["a.txt"] = b"x"
    fake_store["docs/b.txt"] = b"y"
    fake_store["docs/deep/c.txt"] = b"z"
    result = FileServerBackend().ls("/")
    assert result.error is None
    paths = {e["path"] for e in result.entries}
    assert paths == {"/a.txt", "/docs/"}
    result = FileServerBackend().ls("/docs/")
    paths = {e["path"] for e in result.entries}
    assert paths == {"/docs/b.txt", "/docs/deep/"}


def test_read_returns_utf8_file_data(fake_store):
    fake_store["a.txt"] = b"line1\nline2\nline3"
    result = FileServerBackend().read("/a.txt")
    assert result.error is None
    assert result.file_data["encoding"] == "utf-8"
    assert result.file_data["content"] == "line1\nline2\nline3"


def test_read_applies_offset_and_limit(fake_store):
    fake_store["a.txt"] = b"l1\nl2\nl3\nl4"
    result = FileServerBackend().read("/a.txt", offset=1, limit=2)
    assert result.file_data["content"] == "l2\nl3"


def test_read_binary_returns_base64(fake_store):
    payload = b"\x89PNG\x0d\x0a"
    fake_store["img.png"] = payload
    result = FileServerBackend().read("/img.png")
    assert result.file_data["encoding"] == "base64"
    assert base64.b64decode(result.file_data["content"]) == payload


def test_read_missing_file_returns_error(fake_store):
    result = FileServerBackend().read("/nope.txt")
    assert result.error == "File '/nope.txt' not found"


def test_write_new_file_succeeds(fake_store):
    result = FileServerBackend().write("/new.txt", "hello")
    assert result.error is None
    assert result.path == "/new.txt"
    assert fake_store["new.txt"] == b"hello"


def test_write_existing_file_errors(fake_store):
    fake_store["a.txt"] = b"old"
    result = FileServerBackend().write("/a.txt", "new")
    assert result.error is not None
    assert "already exists" in result.error
    assert fake_store["a.txt"] == b"old"


def test_upload_and_download_files(fake_store):
    backend = FileServerBackend()
    uploads = backend.upload_files([("/u1.txt", b"one"), ("/u2.txt", b"two")])
    assert [u.error for u in uploads] == [None, None]
    downloads = backend.download_files(["/u1.txt", "/missing.txt"])
    assert downloads[0].content == b"one"
    assert downloads[1].error == "file_not_found"


def test_session_and_context_forwarded(monkeypatch):
    seen = {}

    def fake_list(base_path="", workspace_context=None, session_id=None):
        seen["workspace_context"] = workspace_context
        seen["session_id"] = session_id
        return []

    monkeypatch.setattr(fb, "raw_list_files", fake_list)
    FileServerBackend(session_id="s1", workspace_context={"jira_number": "J-1"}).ls("/")
    assert seen == {"workspace_context": {"jira_number": "J-1"}, "session_id": "s1"}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd autobots-devtools-shared-lib && make test-one TEST=tests/unit/test_fserver_backend.py`
Expected: FAIL — `ModuleNotFoundError: No module named '…fserver_backend'`

- [ ] **Step 3: Implement the backend (direct methods)**

Create `fserver_backend.py`:

```python
# ABOUTME: deepagents BackendProtocol implementation on the MER file-server sidecar.
# ABOUTME: Direct ls/read/write/upload/download; edit/glob/grep are emulated client-side.

import base64
from collections.abc import Mapping
from typing import Any

import httpx
from deepagents.backends.protocol import (
    FILE_NOT_FOUND,
    BackendProtocol,
    FileData,
    FileDownloadResponse,
    FileInfo,
    FileUploadResponse,
    LsResult,
    ReadResult,
    WriteResult,
)

from autobots_devtools_shared_lib.common.observability import get_logger
from autobots_devtools_shared_lib.common.utils.fserver_client_utils import (
    raw_list_files,
    raw_read_file,
    raw_write_file,
)

logger = get_logger(__name__)

_WORKSPACE_CONTEXT_KEYS = ("agent_name", "user_name", "repo_name", "jira_number")


def workspace_context_from_state(state: Mapping[str, Any]) -> dict[str, Any]:
    """Build the sidecar workspace_context dict from runtime state keys."""
    return {key: state[key] for key in _WORKSPACE_CONTEXT_KEYS if state.get(key)}


def _to_server_path(path: str) -> str:
    """Virtual paths are absolute; the sidecar wants workspace-relative paths."""
    return path.lstrip("/")


def _to_virtual_path(path: str) -> str:
    return "/" + path.lstrip("/")


class FileServerBackend(BackendProtocol):
    """Virtual filesystem backed by the file-server sidecar (per-session workspace)."""

    def __init__(
        self,
        session_id: str | None = None,
        workspace_context: dict[str, Any] | None = None,
    ) -> None:
        self._session_id = session_id
        self._workspace_context = dict(workspace_context or {})

    # -- helpers -----------------------------------------------------------

    def _list_all(self) -> list[str]:
        files = raw_list_files("", self._workspace_context, self._session_id)
        return [str(f) for f in files]

    def _read_bytes(self, file_path: str) -> bytes:
        return raw_read_file(
            _to_server_path(file_path), self._workspace_context, self._session_id
        )

    def _write_bytes(self, file_path: str, content: bytes) -> None:
        raw_write_file(
            _to_server_path(file_path), content, self._workspace_context, self._session_id
        )

    # -- direct methods ----------------------------------------------------

    def ls(self, path: str) -> LsResult:
        try:
            files = self._list_all()
        except httpx.HTTPError as e:
            return LsResult(error=f"Error listing files: {e}")
        normalized = path if path.endswith("/") else path + "/"
        entries: list[FileInfo] = []
        subdirs: set[str] = set()
        for name in files:
            virtual = _to_virtual_path(name)
            if not virtual.startswith(normalized):
                continue
            relative = virtual[len(normalized) :]
            if "/" in relative:
                subdirs.add(normalized + relative.split("/", 1)[0] + "/")
            else:
                entries.append(FileInfo(path=virtual))
        entries.extend(FileInfo(path=subdir, is_dir=True) for subdir in sorted(subdirs))
        return LsResult(entries=entries)

    def read(self, file_path: str, offset: int = 0, limit: int = 2000) -> ReadResult:
        try:
            content = self._read_bytes(file_path)
        except httpx.HTTPStatusError as e:
            if e.response.status_code == 404:
                return ReadResult(error=f"File '{file_path}' not found")
            return ReadResult(
                error=f"Error reading file '{file_path}': HTTP {e.response.status_code}"
            )
        except httpx.HTTPError as e:
            return ReadResult(error=f"Error reading file '{file_path}': {e}")
        try:
            text = content.decode("utf-8")
        except UnicodeDecodeError:
            encoded = base64.b64encode(content).decode("utf-8")
            return ReadResult(file_data=FileData(content=encoded, encoding="base64"))
        window = "\n".join(text.split("\n")[offset : offset + limit])
        return ReadResult(file_data=FileData(content=window, encoding="utf-8"))

    def write(self, file_path: str, content: str) -> WriteResult:
        try:
            self._read_bytes(file_path)
        except httpx.HTTPStatusError as e:
            if e.response.status_code != 404:
                return WriteResult(
                    error=f"Error writing file '{file_path}': HTTP {e.response.status_code}"
                )
        except httpx.HTTPError as e:
            return WriteResult(error=f"Error writing file '{file_path}': {e}")
        else:
            return WriteResult(
                error=(
                    f"Cannot write to {file_path} because it already exists. "
                    "Read and then make an edit, or write to a new path."
                )
            )
        try:
            self._write_bytes(file_path, content.encode("utf-8"))
        except httpx.HTTPError as e:
            return WriteResult(error=f"Error writing file '{file_path}': {e}")
        return WriteResult(path=file_path)

    def upload_files(self, files: list[tuple[str, bytes]]) -> list[FileUploadResponse]:
        responses: list[FileUploadResponse] = []
        for path, content in files:
            try:
                self._write_bytes(path, content)
                responses.append(FileUploadResponse(path=path))
            except httpx.HTTPError as e:
                responses.append(FileUploadResponse(path=path, error=str(e)))
        return responses

    def download_files(self, paths: list[str]) -> list[FileDownloadResponse]:
        responses: list[FileDownloadResponse] = []
        for path in paths:
            try:
                responses.append(
                    FileDownloadResponse(path=path, content=self._read_bytes(path))
                )
            except httpx.HTTPStatusError as e:
                error = FILE_NOT_FOUND if e.response.status_code == 404 else str(e)
                responses.append(FileDownloadResponse(path=path, error=error))
            except httpx.HTTPError as e:
                responses.append(FileDownloadResponse(path=path, error=str(e)))
        return responses
```

(Do **not** import `EditResult`/`GlobResult`/`GrepMatch`/`GrepResult` yet — they are unused until Task 11 and ruff F401 would fail this task's commit.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd autobots-devtools-shared-lib && make test-one TEST=tests/unit/test_fserver_backend.py`
Expected: PASS (all 11)

- [ ] **Step 5: Commit**

```bash
cd autobots-devtools-shared-lib
git add src/autobots_devtools_shared_lib/dynagent/agents/fserver_backend.py tests/unit/test_fserver_backend.py
git commit -m "feat(dynagent): FileServerBackend direct methods on the sidecar raw layer"
```

---

### Task 11: `FileServerBackend` — emulated `edit`, `glob`, `grep`

Client-side emulation per the spec: `edit` = read → occurrence-checked replace → write; `glob` = listFiles + `fnmatch`; `grep` = listFiles + readFile + literal substring search (accepted: chatty on large workspaces).

**Files:**
- Modify: `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/dynagent/agents/fserver_backend.py`
- Test: `autobots-devtools-shared-lib/tests/unit/test_fserver_backend.py` (extend)

**Interfaces:**
- Produces: `edit(file_path, old_string, new_string, replace_all=False) -> EditResult`, `glob(pattern, path=None) -> GlobResult`, `grep(pattern, path=None, glob=None) -> GrepResult` on `FileServerBackend`. `grep`'s `pattern` is a **literal substring** (protocol contract, not regex).

- [ ] **Step 1: Write the failing tests**

Append to `tests/unit/test_fserver_backend.py`:

```python
def test_edit_replaces_unique_occurrence(fake_store):
    fake_store["a.txt"] = b"hello world"
    result = FileServerBackend().edit("/a.txt", "world", "sidecar")
    assert result.error is None
    assert result.occurrences == 1
    assert fake_store["a.txt"] == b"hello sidecar"


def test_edit_missing_string_errors(fake_store):
    fake_store["a.txt"] = b"hello"
    result = FileServerBackend().edit("/a.txt", "absent", "x")
    assert result.error is not None
    assert "not found" in result.error


def test_edit_multiple_occurrences_requires_replace_all(fake_store):
    fake_store["a.txt"] = b"x y x"
    result = FileServerBackend().edit("/a.txt", "x", "z")
    assert result.error is not None
    assert "2 times" in result.error
    assert fake_store["a.txt"] == b"x y x"


def test_edit_replace_all(fake_store):
    fake_store["a.txt"] = b"x y x"
    result = FileServerBackend().edit("/a.txt", "x", "z", replace_all=True)
    assert result.error is None
    assert result.occurrences == 2
    assert fake_store["a.txt"] == b"z y z"


def test_edit_missing_file_errors(fake_store):
    result = FileServerBackend().edit("/nope.txt", "a", "b")
    assert result.error == "File '/nope.txt' not found"


def test_glob_matches_pattern(fake_store):
    fake_store["a.py"] = b""
    fake_store["b.txt"] = b""
    fake_store["src/c.py"] = b""
    result = FileServerBackend().glob("*.py")
    paths = {m["path"] for m in result.matches}
    assert paths == {"/a.py"}
    result = FileServerBackend().glob("**/*.py")
    paths = {m["path"] for m in result.matches}
    assert "/src/c.py" in paths


def test_glob_with_base_path(fake_store):
    fake_store["src/c.py"] = b""
    fake_store["a.py"] = b""
    result = FileServerBackend().glob("*.py", path="/src")
    assert {m["path"] for m in result.matches} == {"/src/c.py"}


def test_grep_finds_literal_matches(fake_store):
    fake_store["a.txt"] = b"one TODO here\nclean line\nanother TODO"
    fake_store["b.bin"] = b"\xff\xfe"
    result = FileServerBackend().grep("TODO")
    assert result.error is None
    assert [(m["path"], m["line"]) for m in result.matches] == [("/a.txt", 1), ("/a.txt", 3)]


def test_grep_glob_filter(fake_store):
    fake_store["a.py"] = b"TODO"
    fake_store["a.txt"] = b"TODO"
    result = FileServerBackend().grep("TODO", glob="*.py")
    assert {m["path"] for m in result.matches} == {"/a.py"}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd autobots-devtools-shared-lib && make test-one TEST=tests/unit/test_fserver_backend.py`
Expected: new tests FAIL — `NotImplementedError` (protocol defaults)

- [ ] **Step 3: Implement the emulated methods**

Add `import fnmatch` to the imports, extend the `deepagents.backends.protocol` import with `EditResult`, `GlobResult`, `GrepMatch`, `GrepResult` (keeping the list alphabetized), and append to `FileServerBackend`:

```python
    # -- emulated methods (no sidecar endpoints; see spec §4) ----------------

    def edit(
        self,
        file_path: str,
        old_string: str,
        new_string: str,
        replace_all: bool = False,  # noqa: FBT001, FBT002
    ) -> EditResult:
        try:
            content_bytes = self._read_bytes(file_path)
        except httpx.HTTPStatusError as e:
            if e.response.status_code == 404:
                return EditResult(error=f"File '{file_path}' not found")
            return EditResult(
                error=f"Error editing file '{file_path}': HTTP {e.response.status_code}"
            )
        except httpx.HTTPError as e:
            return EditResult(error=f"Error editing file '{file_path}': {e}")
        try:
            content = content_bytes.decode("utf-8")
        except UnicodeDecodeError:
            return EditResult(error=f"Cannot edit binary file '{file_path}'")

        occurrences = content.count(old_string)
        if occurrences == 0:
            return EditResult(error=f"String not found in file '{file_path}': '{old_string}'")
        if occurrences > 1 and not replace_all:
            return EditResult(
                error=(
                    f"String '{old_string}' appears {occurrences} times in '{file_path}'. "
                    "Use replace_all=True, or provide a more specific string."
                )
            )
        replaced = (
            content.replace(old_string, new_string)
            if replace_all
            else content.replace(old_string, new_string, 1)
        )
        try:
            self._write_bytes(file_path, replaced.encode("utf-8"))
        except httpx.HTTPError as e:
            return EditResult(error=f"Error editing file '{file_path}': {e}")
        return EditResult(path=file_path, occurrences=occurrences if replace_all else 1)

    def _files_under(self, base: str) -> list[str]:
        normalized = base if base.endswith("/") else base + "/"
        return [
            _to_virtual_path(name)
            for name in self._list_all()
            if _to_virtual_path(name).startswith(normalized)
        ]

    @staticmethod
    def _matches_glob(virtual: str, base: str, pattern: str) -> bool:
        normalized = base if base.endswith("/") else base + "/"
        relative = virtual[len(normalized) :]
        return fnmatch.fnmatch(relative, pattern) or fnmatch.fnmatch(virtual, pattern)

    def glob(self, pattern: str, path: str | None = None) -> GlobResult:
        base = path or "/"
        try:
            candidates = self._files_under(base)
        except httpx.HTTPError as e:
            return GlobResult(error=f"Error listing files: {e}")
        matches = [
            FileInfo(path=virtual)
            for virtual in candidates
            if self._matches_glob(virtual, base, pattern)
        ]
        return GlobResult(matches=matches)

    def grep(
        self,
        pattern: str,
        path: str | None = None,
        glob: str | None = None,
    ) -> GrepResult:
        base = path or "/"
        try:
            candidates = self._files_under(base)
        except httpx.HTTPError as e:
            return GrepResult(error=f"Error listing files: {e}")
        matches: list[GrepMatch] = []
        for virtual in candidates:
            if glob and not self._matches_glob(virtual, base, glob):
                continue
            try:
                text = self._read_bytes(virtual).decode("utf-8")
            except (httpx.HTTPError, UnicodeDecodeError):
                continue  # unreadable or binary: skip, matching ripgrep behavior
            for line_number, line in enumerate(text.split("\n"), start=1):
                if pattern in line:
                    matches.append(GrepMatch(path=virtual, line=line_number, text=line))
        return GrepResult(matches=matches)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd autobots-devtools-shared-lib && make test-one TEST=tests/unit/test_fserver_backend.py`
Expected: PASS (all 20)

- [ ] **Step 5: Commit**

```bash
cd autobots-devtools-shared-lib
git add src/autobots_devtools_shared_lib/dynagent/agents/fserver_backend.py tests/unit/test_fserver_backend.py
git commit -m "feat(dynagent): FileServerBackend client-side edit/glob/grep emulation"
```

---

### Task 12: Registry types `fserver`, `store`, `composite` + `store=` factory kwarg

**Files:**
- Modify: `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/dynagent/agents/deep_backend.py`
- Modify: `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/dynagent/agents/base_deepagent.py` (add `store` kwarg)
- Test: `autobots-devtools-shared-lib/tests/unit/test_deep_backend.py` (extend), `tests/unit/test_base_deepagent.py` (one wiring test)

**Interfaces:**
- Produces (registry semantics):
  - `type: fserver` → a `BackendFactory`; calling it with a `ToolRuntime` builds `FileServerBackend(session_id=state["session_id"], workspace_context=workspace_context_from_state(state))`.
  - `type: store` → `StoreBackend(store=…)`; **fails fast** (`ValueError` mentioning `store=`) when the kwarg is absent.
  - `type: composite` → a `BackendFactory` producing `CompositeBackend(default=StateBackend(), routes=…)`; each route config resolves recursively through the registry (a `state` route materializes as `StateBackend()`, factory routes are called with the runtime).
- Produces (factory): `create_base_deepagent(…, store: Any = None)` — forwarded to both `resolve_backend(…, store=store)` and `create_deep_agent(store=…)` (the latter lands with the other escape hatches in Task 15; here only `resolve_backend` consumes it).
- Consumes: `FileServerBackend`, `workspace_context_from_state` (Tasks 10–11).

- [ ] **Step 1: Write the failing tests**

Append to `tests/unit/test_deep_backend.py`:

```python
from types import SimpleNamespace

from deepagents.backends import CompositeBackend, StateBackend, StoreBackend

from autobots_devtools_shared_lib.dynagent.agents.fserver_backend import FileServerBackend


def _runtime(state=None):
    return SimpleNamespace(state=state or {})


def test_fserver_type_returns_runtime_factory():
    factory = resolve_backend({"type": "fserver"})
    assert callable(factory)
    backend = factory(_runtime({"session_id": "s1", "jira_number": "J-1", "other": "x"}))
    assert isinstance(backend, FileServerBackend)
    assert backend._session_id == "s1"
    assert backend._workspace_context == {"jira_number": "J-1"}


def test_store_type_without_store_kwarg_fails_fast():
    with pytest.raises(ValueError, match="store="):
        resolve_backend({"type": "store"})


def test_store_type_with_store_kwarg(monkeypatch):
    sentinel_store = object()
    built = {}

    def fake_store_backend(*, store):
        built["store"] = store
        return StateBackend()  # any BackendProtocol instance

    monkeypatch.setattr(
        "autobots_devtools_shared_lib.dynagent.agents.deep_backend.StoreBackend",
        fake_store_backend,
    )
    resolve_backend({"type": "store"}, store=sentinel_store)
    assert built["store"] is sentinel_store


def test_composite_builds_routed_backend():
    factory = resolve_backend(
        {
            "type": "composite",
            "routes": {
                "/workspace/": {"type": "fserver"},
                "/scratch/": {"type": "state"},
            },
        }
    )
    assert callable(factory)
    composite = factory(_runtime({"session_id": "s1"}))
    assert isinstance(composite, CompositeBackend)
    assert isinstance(composite.default, StateBackend)
    assert isinstance(composite.routes["/workspace/"], FileServerBackend)
    assert isinstance(composite.routes["/scratch/"], StateBackend)


def test_composite_store_route_without_store_kwarg_fails_fast():
    config = {"type": "composite", "routes": {"/memories/": {"type": "store"}}}
    with pytest.raises(ValueError, match="store="):
        resolve_backend(config)


def test_unknown_type_error_lists_all_types():
    with pytest.raises(ValueError) as excinfo:
        resolve_backend({"type": "bogus"})
    for name in ("state", "filesystem", "fserver", "store", "composite"):
        assert name in str(excinfo.value)
```

Append to `tests/unit/test_base_deepagent.py`:

```python
def test_store_kwarg_reaches_resolve_backend(patched, fake_meta, monkeypatch):
    seen = {}

    def fake_resolve(config, override=None, store=None):
        seen["store"] = store
        return None

    monkeypatch.setattr(bd, "resolve_backend", fake_resolve)
    sentinel = object()
    bd.create_base_deepagent(store=sentinel)
    assert seen["store"] is sentinel
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd autobots-devtools-shared-lib && make test-one TEST=tests/unit/test_deep_backend.py`
Expected: FAIL — `ValueError: Unknown backend type 'fserver'…` and `TypeError: create_base_deepagent() got an unexpected keyword argument 'store'`

- [ ] **Step 3: Implement the registry additions**

In `deep_backend.py`, extend the imports:

```python
from deepagents.backends import CompositeBackend, FilesystemBackend, StateBackend, StoreBackend
from deepagents.backends.protocol import BackendProtocol

from autobots_devtools_shared_lib.dynagent.agents.fserver_backend import (
    FileServerBackend,
    workspace_context_from_state,
)
```

and add the builders + registry entries:

```python
def _build_store(cfg: dict[str, Any], *, store: Any = None, **_kw: Any) -> Any:
    if store is None:
        msg = (
            "Backend type 'store' requires the store= kwarg on create_base_deepagent "
            "(a live BaseStore instance cannot be expressed in YAML)."
        )
        raise ValueError(msg)
    return StoreBackend(store=store)


def _build_fserver(cfg: dict[str, Any], **_kw: Any) -> Any:
    def factory(runtime: Any) -> FileServerBackend:
        state = getattr(runtime, "state", None) or {}
        return FileServerBackend(
            session_id=state.get("session_id"),
            workspace_context=workspace_context_from_state(state),
        )

    return factory


def _build_composite(cfg: dict[str, Any], *, store: Any = None, **_kw: Any) -> Any:
    route_configs = cfg.get("routes") or {}
    built_routes = {
        prefix: _build_backend(route_cfg, store=store)
        for prefix, route_cfg in route_configs.items()
    }

    def factory(runtime: Any) -> CompositeBackend:
        routes: dict[str, BackendProtocol] = {}
        for prefix, backend in built_routes.items():
            if backend is None:
                routes[prefix] = StateBackend()
            elif isinstance(backend, BackendProtocol):
                routes[prefix] = backend
            else:  # BackendFactory route (e.g. fserver): materialize per runtime
                routes[prefix] = backend(runtime)
        return CompositeBackend(default=StateBackend(), routes=routes)

    return factory


_BACKEND_REGISTRY: dict[str, Callable[..., Any]] = {
    "state": _build_state,
    "filesystem": _build_filesystem,
    "fserver": _build_fserver,
    "store": _build_store,
    "composite": _build_composite,
}
```

Update `_build_state`/`_build_filesystem` signatures to accept `**_kw: Any` uniformly (they already do from Task 6).

In `base_deepagent.py`, add `store: Any = None` to the signature (documented as "BaseStore for store-type backend routes; forwarded to create_deep_agent in Task 15") and change the backend line:

```python
        backend=resolve_backend(meta.backend_config, override=backend, store=store),
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd autobots-devtools-shared-lib && make test-one TEST=tests/unit/test_deep_backend.py && make test-one TEST=tests/unit/test_base_deepagent.py`
Expected: PASS (P2 complete)

- [ ] **Step 5: Full check + commit**

Run: `cd autobots-devtools-shared-lib && make check-format && make type-check && make test-fast`
Expected: all PASS

```bash
cd autobots-devtools-shared-lib
git add src/autobots_devtools_shared_lib/dynagent/agents/deep_backend.py \
        src/autobots_devtools_shared_lib/dynagent/agents/base_deepagent.py \
        tests/unit/test_deep_backend.py tests/unit/test_base_deepagent.py
git commit -m "feat(dynagent): fserver/store/composite backend types with runtime factories"
```

---

## Phase P3 — config-driven subagents

### Task 13: Roster → `SubAgent` mapping, description validation, kwarg merge

Every non-default roster entry becomes a deepagents `SubAgent`; the `subagents:` kwarg stays as an additive escape hatch (kwarg wins on name collision). A non-default entry without `description:` fails at config load — **gated to `deep-agents.yaml`** so react rosters (whose agents have no descriptions) stay untouched.

**Files:**
- Modify: `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/dynagent/agents/base_deepagent.py`
- Modify: `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/dynagent/agents/agent_config_utils.py` (description validation)
- Test: `autobots-devtools-shared-lib/tests/unit/test_deep_subagents.py` (create)

**Interfaces:**
- Produces (`base_deepagent.py`): `_build_roster_subagents(meta: AgentMeta, main_agent_name: str, prompt_values: dict | None) -> list[SubAgent]` — `SubAgent(name=…, description=…, system_prompt=_resolve_system_prompt(…), tools=…)`; sets `"skills"` only when non-empty and `"model"` (via `resolve_agent_model`) only when the entry has `model:` configured — omitting `"model"` makes deepagents inherit the main agent's model, which implements the spec's inheritance rule. Task 19 later extends this helper with rubric middleware.
- Produces (factory): merged roster + kwarg subagents forwarded as `subagents=`.
- Fixture note: earlier tasks' deep-YAML fixtures already give `researcher` a description, so the new validation does not break them.

- [ ] **Step 1: Write the failing tests**

Create `autobots-devtools-shared-lib/tests/unit/test_deep_subagents.py`:

```python
# ABOUTME: Unit tests for config-driven subagent mapping in the deep engine.
# ABOUTME: Covers roster->SubAgent fields, model inheritance, kwarg merge, description validation.

from unittest.mock import MagicMock, patch

import pytest

import autobots_devtools_shared_lib.dynagent.agents.agent_config_utils as cfg
import autobots_devtools_shared_lib.dynagent.agents.base_deepagent as bd
from autobots_devtools_shared_lib.dynagent.agents.agent_config_utils import (
    _reset_agent_config,
    load_agents_config,
)
from autobots_devtools_shared_lib.dynagent.config.dynagent_settings import DynagentSettings


@pytest.fixture
def fake_meta():
    meta = MagicMock()
    meta.prompt_map = {
        "assistant": "You are an assistant.",
        "researcher": "You research {language}.",
    }
    meta.tool_map = {"assistant": ["tool_a"], "researcher": ["tool_r"]}
    meta.input_schema_map = {"assistant": {}, "researcher": {}}
    meta.output_schema_map = {"assistant": None, "researcher": None}
    meta.model_map = {"assistant": None, "researcher": None}
    meta.skills_map = {"assistant": [], "researcher": []}
    meta.memory_map = {"assistant": [], "researcher": []}
    meta.interrupt_map = {"assistant": {}, "researcher": {}}
    meta.permissions_map = {"assistant": [], "researcher": []}
    meta.description_map = {"assistant": None, "researcher": "Does research"}
    meta.mcp_map = {"assistant": [], "researcher": []}
    meta.debug_map = {"assistant": False, "researcher": False}
    meta.rubric_map = {"assistant": None, "researcher": None}
    meta.backend_config = None
    meta.model_profiles = {}
    meta.mcp_servers_config = {}
    return meta


@pytest.fixture
def patched(fake_meta):
    with (
        patch.object(bd.AgentMeta, "instance", return_value=fake_meta),
        patch.object(bd, "get_default_agent", return_value="assistant"),
        patch.object(bd, "resolve_agent_model", return_value="MODEL"),
        patch.object(bd, "create_deep_agent", return_value="GRAPH") as mock_cda,
    ):
        yield mock_cda


def _subagents(mock_cda):
    return mock_cda.call_args.kwargs["subagents"]


def test_non_default_roster_entry_becomes_subagent(patched):
    bd.create_base_deepagent(prompt_values={"language": "java"})
    subs = _subagents(patched)
    assert len(subs) == 1
    sub = subs[0]
    assert sub["name"] == "researcher"
    assert sub["description"] == "Does research"
    assert sub["system_prompt"] == "You research java."
    assert sub["tools"] == ["tool_r"]
    assert "model" not in sub  # inherits the main agent's model natively


def test_subagent_model_set_only_when_configured(patched, fake_meta):
    fake_meta.model_map = {"assistant": None, "researcher": "cheap-docs"}
    bd.create_base_deepagent()
    sub = _subagents(patched)[0]
    assert sub["model"] == "MODEL"


def test_subagent_skills_forwarded_when_present(patched, fake_meta):
    fake_meta.skills_map = {"assistant": [], "researcher": ["skills/research/"]}
    bd.create_base_deepagent()
    assert _subagents(patched)[0]["skills"] == ["skills/research/"]


def test_kwarg_subagents_are_additive(patched):
    extra = {"name": "extra", "description": "d", "system_prompt": "p"}
    bd.create_base_deepagent(subagents=[extra])
    names = {s["name"] for s in _subagents(patched)}
    assert names == {"researcher", "extra"}


def test_kwarg_wins_on_name_collision(patched):
    override = {"name": "researcher", "description": "override", "system_prompt": "p"}
    bd.create_base_deepagent(subagents=[override])
    subs = _subagents(patched)
    assert len(subs) == 1
    assert subs[0]["description"] == "override"


def test_no_subagents_forwards_none(patched, fake_meta):
    fake_meta.prompt_map = {"assistant": "You are an assistant."}
    fake_meta.tool_map = {"assistant": []}
    fake_meta.description_map = {"assistant": None}
    bd.create_base_deepagent()
    assert patched.call_args.kwargs["subagents"] is None


def test_missing_description_fails_at_config_load(tmp_path, monkeypatch):
    _reset_agent_config()
    (tmp_path / "deep-agents.yaml").write_text(
        "agents:\n"
        "  assistant:\n"
        "    prompt: assistant\n"
        "    is_default: true\n"
        "    tools: []\n"
        "  researcher:\n"
        "    prompt: researcher\n"
        "    tools: []\n"
    )
    monkeypatch.setattr(cfg, "get_config_dir", lambda: tmp_path)
    settings = DynagentSettings(agents_config_filename="deep-agents.yaml")
    monkeypatch.setattr(cfg, "get_dynagent_settings", lambda: settings)
    with pytest.raises(ValueError, match="researcher.*description"):
        load_agents_config()
    _reset_agent_config()


def test_react_roster_without_descriptions_still_loads(tmp_path, monkeypatch):
    _reset_agent_config()
    (tmp_path / "agents.yaml").write_text(
        "agents:\n"
        "  coordinator:\n"
        "    prompt: coordinator\n"
        "    is_default: true\n"
        "    tools: []\n"
        "  worker:\n"
        "    prompt: worker\n"
        "    tools: []\n"
    )
    monkeypatch.setattr(cfg, "get_config_dir", lambda: tmp_path)
    settings = DynagentSettings(agents_config_filename="agents.yaml")
    monkeypatch.setattr(cfg, "get_dynagent_settings", lambda: settings)
    agents = load_agents_config()
    assert set(agents) == {"coordinator", "worker"}
    _reset_agent_config()
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd autobots-devtools-shared-lib && make test-one TEST=tests/unit/test_deep_subagents.py`
Expected: FAIL — `subagents` kwarg is `None` (roster mapping missing) and no load-time description error.

- [ ] **Step 3: Implement mapping + merge + validation**

In `base_deepagent.py`, add the helper after `_resolve_system_prompt`:

```python
def _build_roster_subagents(
    meta: AgentMeta, main_agent_name: str, prompt_values: dict[str, Any] | None
) -> list[SubAgent]:
    """Map every non-default roster entry to a deepagents SubAgent.

    "model" is set only when the entry configures one; omitting it makes
    deepagents inherit the main agent's model (the spec's inheritance rule).
    """
    subagents: list[SubAgent] = []
    for agent_id in meta.prompt_map:
        if agent_id == main_agent_name:
            continue
        subagent = SubAgent(
            name=agent_id,
            description=meta.description_map.get(agent_id) or "",
            system_prompt=_resolve_system_prompt(meta, agent_id, prompt_values),
            tools=meta.tool_map.get(agent_id, []),
        )
        if meta.skills_map.get(agent_id):
            subagent["skills"] = meta.skills_map[agent_id]
        if meta.model_map.get(agent_id):
            subagent["model"] = resolve_agent_model(meta, agent_id)
        subagents.append(subagent)
    return subagents
```

In `create_base_deepagent`, before the `return create_deep_agent(…)`:

```python
    merged: dict[str, Any] = {s["name"]: s for s in _build_roster_subagents(meta, agent_name, prompt_values)}
    for kwarg_subagent in subagents or []:
        merged[kwarg_subagent["name"]] = kwarg_subagent  # kwarg wins on collision
    merged_subagents = list(merged.values()) or None
```

and change the forwarding line to `subagents=merged_subagents,`.

In `agent_config_utils.load_agents_config`, extend the validation block (after the model-ref loop, still before `_GLOBAL_AGENT_CONFIG = agents`):

```python
    if get_dynagent_settings().agents_config_filename == "deep-agents.yaml":
        default_name = next((n for n, c in agents.items() if c.is_default), None)
        for agent_id, agent_cfg in agents.items():
            if agent_id != default_name and not agent_cfg.description:
                msg = (
                    f"Agent '{agent_id}': non-default deep-agent roster entries require a "
                    "description: (deepagents' task tool uses it for delegation)"
                )
                raise ValueError(msg)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd autobots-devtools-shared-lib && make test-one TEST=tests/unit/test_deep_subagents.py && make test-one TEST=tests/unit/test_base_deepagent.py`
Expected: PASS (P3 complete; `test_base_deepagent.py` still green — its fixture has a single-agent roster, so `subagents` stays `None` unless passed)

- [ ] **Step 5: Regression + commit**

Run: `cd autobots-devtools-shared-lib && make test-fast`
Expected: PASS

```bash
cd autobots-devtools-shared-lib
git add src/autobots_devtools_shared_lib/dynagent/agents/base_deepagent.py \
        src/autobots_devtools_shared_lib/dynagent/agents/agent_config_utils.py \
        tests/unit/test_deep_subagents.py
git commit -m "feat(dynagent): config-driven subagents from the deep-agent roster"
```

---

## Phase P4 — structured output, HITL, permissions

### Task 14: Forward `response_format`, `interrupt_on`, `permissions`

Closes the gap where the deep engine silently ignores the roster's `output:` schema config. `interrupt_on` forwarding is plumbing only — interrupt-aware driver UX is a separate effort (spec §6).

**Files:**
- Modify: `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/dynagent/agents/base_deepagent.py`
- Test: `autobots-devtools-shared-lib/tests/unit/test_base_deepagent.py` (extend)

**Interfaces:**
- Produces: factory forwards `response_format=meta.output_schema_map.get(agent_name) or None` (the resolved JSON-schema dict), `interrupt_on=meta.interrupt_map.get(agent_name) or None`, `permissions=meta.permissions_map.get(agent_name) or None`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/unit/test_base_deepagent.py`:

```python
def test_output_schema_forwarded_as_response_format(patched, fake_meta):
    schema = {"type": "object", "properties": {"answer": {"type": "string"}}}
    fake_meta.output_schema_map = {"assistant": schema}
    bd.create_base_deepagent()
    assert patched.call_args.kwargs["response_format"] == schema


def test_no_output_schema_forwards_none(patched):
    bd.create_base_deepagent()
    assert patched.call_args.kwargs["response_format"] is None


def test_interrupt_on_forwarded(patched, fake_meta):
    fake_meta.interrupt_map = {"assistant": {"write_file": True}}
    bd.create_base_deepagent()
    assert patched.call_args.kwargs["interrupt_on"] == {"write_file": True}


def test_permissions_forwarded(patched, fake_meta):
    rules = [{"tool": "write_file", "path": "/workspace/**", "permission": "allow"}]
    fake_meta.permissions_map = {"assistant": rules}
    bd.create_base_deepagent()
    assert patched.call_args.kwargs["permissions"] == rules


def test_empty_interrupt_and_permissions_forward_none(patched):
    bd.create_base_deepagent()
    kwargs = patched.call_args.kwargs
    assert kwargs["interrupt_on"] is None
    assert kwargs["permissions"] is None
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd autobots-devtools-shared-lib && make test-one TEST=tests/unit/test_base_deepagent.py`
Expected: new tests FAIL — `KeyError: 'response_format'`

- [ ] **Step 3: Implement the forwarding**

Add to the `create_deep_agent(…)` call in `create_base_deepagent`:

```python
        response_format=meta.output_schema_map.get(agent_name) or None,
        interrupt_on=meta.interrupt_map.get(agent_name) or None,
        permissions=meta.permissions_map.get(agent_name) or None,
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd autobots-devtools-shared-lib && make test-one TEST=tests/unit/test_base_deepagent.py`
Expected: PASS (P4 complete)

- [ ] **Step 5: Commit**

```bash
cd autobots-devtools-shared-lib
git add src/autobots_devtools_shared_lib/dynagent/agents/base_deepagent.py tests/unit/test_base_deepagent.py
git commit -m "feat(dynagent): forward response_format/interrupt_on/permissions from roster config"
```

---

## Phase P5 — escape-hatch kwargs

### Task 15: `middleware`, `cache`, `context_schema`, `debug` (+ `store` forwarding, YAML `debug:`)

**Files:**
- Modify: `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/dynagent/agents/base_deepagent.py`
- Test: `autobots-devtools-shared-lib/tests/unit/test_base_deepagent.py` (extend)

**Interfaces:**
- Produces: final factory signature —

```python
def create_base_deepagent(
    checkpointer: Any = None,
    initial_agent_name: str | None = None,
    state_schema: type[DeepAgentState] = DynaDeepAgent,
    prompt_values: dict[str, Any] | None = None,
    subagents: Sequence[SubAgent] | None = None,
    backend: Any = None,
    store: Any = None,
    middleware: Sequence[Any] | None = None,
    cache: Any = None,
    context_schema: Any = None,
    debug: bool | None = None,
) -> CompiledStateGraph:
```

  Caller `middleware` is appended **after** the engine's own (`[ToolResilienceMiddleware(), *(middleware or ())]`). `debug=None` falls back to the main agent's YAML `debug:` (via `meta.debug_map`); an explicit bool wins. `store`/`cache`/`context_schema` are forwarded verbatim.

- [ ] **Step 1: Write the failing tests**

Append to `tests/unit/test_base_deepagent.py`:

```python
def test_caller_middleware_appended_after_resilience(patched):
    extra = object()
    bd.create_base_deepagent(middleware=[extra])
    middleware = patched.call_args.kwargs["middleware"]
    assert isinstance(middleware[0], ToolResilienceMiddleware)
    assert middleware[1] is extra


def test_store_cache_context_schema_forwarded(patched):
    store, cache, ctx = object(), object(), object()
    bd.create_base_deepagent(store=store, cache=cache, context_schema=ctx)
    kwargs = patched.call_args.kwargs
    assert kwargs["store"] is store
    assert kwargs["cache"] is cache
    assert kwargs["context_schema"] is ctx


def test_debug_defaults_to_yaml_flag(patched, fake_meta):
    fake_meta.debug_map = {"assistant": True}
    bd.create_base_deepagent()
    assert patched.call_args.kwargs["debug"] is True


def test_debug_kwarg_overrides_yaml(patched, fake_meta):
    fake_meta.debug_map = {"assistant": True}
    bd.create_base_deepagent(debug=False)
    assert patched.call_args.kwargs["debug"] is False
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd autobots-devtools-shared-lib && make test-one TEST=tests/unit/test_base_deepagent.py`
Expected: new tests FAIL — unexpected keyword arguments

- [ ] **Step 3: Implement the escape hatches**

Extend the signature as shown in Interfaces, and update the `create_deep_agent(…)` call:

```python
        middleware=[ToolResilienceMiddleware(), *(middleware or ())],
        store=store,
        cache=cache,
        context_schema=context_schema,
        debug=debug if debug is not None else meta.debug_map.get(agent_name, False),
```

Document each new kwarg in the docstring's Args section (one line each: live objects/dev flags that cannot be YAML; YAML remains the primary surface).

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd autobots-devtools-shared-lib && make test-one TEST=tests/unit/test_base_deepagent.py`
Expected: PASS (P5 complete)

- [ ] **Step 5: Full check + commit**

Run: `cd autobots-devtools-shared-lib && make check-format && make type-check && make test-fast`
Expected: all PASS

```bash
cd autobots-devtools-shared-lib
git add src/autobots_devtools_shared_lib/dynagent/agents/base_deepagent.py tests/unit/test_base_deepagent.py
git commit -m "feat(dynagent): escape-hatch kwargs (store/middleware/cache/context_schema/debug)"
```

---

## Phase P6 — config-driven MCP servers

### Task 16: `mcp_servers` reference validation at config load

Task 2 already parses the top-level `mcp_servers:` block and per-agent `mcp_servers:` lists; this task adds the fail-fast check for undeclared references.

**Files:**
- Modify: `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/dynagent/agents/agent_config_utils.py`
- Test: `autobots-devtools-shared-lib/tests/unit/test_deep_config_keys.py` (extend)

**Interfaces:**
- Produces: `load_agents_config` raises `ValueError` naming the agent and the undeclared server.

- [ ] **Step 1: Write the failing test**

Append to `tests/unit/test_deep_config_keys.py`:

```python
def test_undeclared_mcp_server_reference_fails_at_load(tmp_path, monkeypatch):
    _reset_agent_config()
    (tmp_path / "deep-agents.yaml").write_text(
        "agents:\n"
        "  assistant:\n"
        "    prompt: assistant\n"
        "    is_default: true\n"
        "    tools: []\n"
        "    mcp_servers: [\"github\"]\n"
    )
    monkeypatch.setattr(cfg, "get_config_dir", lambda: tmp_path)
    settings = DynagentSettings(agents_config_filename="deep-agents.yaml")
    monkeypatch.setattr(cfg, "get_dynagent_settings", lambda: settings)
    with pytest.raises(ValueError, match="github"):
        load_agents_config()
    _reset_agent_config()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd autobots-devtools-shared-lib && make test-one TEST=tests/unit/test_deep_config_keys.py::test_undeclared_mcp_server_reference_fails_at_load`
Expected: FAIL — no error raised (`DID NOT RAISE`)

- [ ] **Step 3: Implement the check**

In `load_agents_config`'s validation block (with the model-ref loop):

```python
    for agent_id, agent_cfg in agents.items():
        for server_name in agent_cfg.mcp_servers:
            if server_name not in _GLOBAL_MCP_SERVERS:
                msg = (
                    f"Agent '{agent_id}' references undeclared MCP server '{server_name}'. "
                    f"Declared servers: {sorted(_GLOBAL_MCP_SERVERS)}"
                )
                raise ValueError(msg)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd autobots-devtools-shared-lib && make test-one TEST=tests/unit/test_deep_config_keys.py`
Expected: PASS (all, including the pre-existing block tests)

- [ ] **Step 5: Commit**

```bash
cd autobots-devtools-shared-lib
git add src/autobots_devtools_shared_lib/dynagent/agents/agent_config_utils.py tests/unit/test_deep_config_keys.py
git commit -m "feat(dynagent): fail fast on undeclared MCP server references"
```

---

### Task 17: MCP tool loading + factory merge (+ `langchain-mcp-adapters` dependency)

Tools are loaded once at factory build via `MultiServerMCPClient`, name-prefixed `<server>__<tool>`, and merged into the agent's (and each subagent's) tool list. The async client runs through an event-loop-aware bridge because the factory is sync and may be called from inside a running loop (e.g. Chainlit startup — spec risk item).

**Files:**
- Create: `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/dynagent/agents/deep_mcp.py`
- Modify: `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/dynagent/agents/base_deepagent.py`
- Modify: `autobots-devtools-shared-lib/pyproject.toml` (dependency)
- Test: `autobots-devtools-shared-lib/tests/unit/test_deep_mcp.py` (create), `tests/unit/test_base_deepagent.py` (merge test)

**Interfaces:**
- Produces (`deep_mcp.py`):
  - `load_mcp_tools(server_names: list[str], servers_config: dict[str, dict]) -> list[Any]` — `[]` for an empty list without touching the client; otherwise per-server `client.get_tools(server_name=…)`, each tool renamed to `f"{server_name}__{tool.name}"`.
  - `_run_coro(coro)` — `asyncio.run` normally; a fresh thread running `asyncio.run` when a loop is already running.
  - `MultiServerMCPClient` is imported **lazily inside** `load_mcp_tools`, so the dependency is only needed when a domain actually declares MCP servers.
- Consumes (factory): `meta.mcp_map`, `meta.mcp_servers_config` (Task 5).

- [ ] **Step 1: Write the failing tests**

Create `autobots-devtools-shared-lib/tests/unit/test_deep_mcp.py`:

```python
# ABOUTME: Unit tests for config-driven MCP tool loading (stubbed MultiServerMCPClient).
# ABOUTME: Covers name prefixing, empty short-circuit, and the event-loop-aware bridge.

import sys
from types import SimpleNamespace

import autobots_devtools_shared_lib.dynagent.agents.deep_mcp as deep_mcp
from autobots_devtools_shared_lib.dynagent.agents.deep_mcp import _run_coro, load_mcp_tools


def _install_fake_adapters(monkeypatch, tools_by_server):
    class FakeClient:
        def __init__(self, connections):
            self.connections = connections

        async def get_tools(self, server_name=None):
            return tools_by_server[server_name]

    fake_client_module = SimpleNamespace(MultiServerMCPClient=FakeClient)
    monkeypatch.setitem(sys.modules, "langchain_mcp_adapters", SimpleNamespace(client=fake_client_module))
    monkeypatch.setitem(sys.modules, "langchain_mcp_adapters.client", fake_client_module)


def test_empty_server_list_returns_empty_without_client():
    assert load_mcp_tools([], {"atlassian": {"transport": "stdio"}}) == []


def test_tools_loaded_and_name_prefixed(monkeypatch):
    _install_fake_adapters(
        monkeypatch,
        {
            "atlassian": [SimpleNamespace(name="search"), SimpleNamespace(name="create_issue")],
            "github": [SimpleNamespace(name="search")],
        },
    )
    tools = load_mcp_tools(
        ["atlassian", "github"],
        {"atlassian": {"transport": "stdio"}, "github": {"transport": "stdio"}},
    )
    assert [t.name for t in tools] == [
        "atlassian__search",
        "atlassian__create_issue",
        "github__search",
    ]


def test_only_referenced_servers_are_connected(monkeypatch):
    seen = {}

    class FakeClient:
        def __init__(self, connections):
            seen["connections"] = connections

        async def get_tools(self, server_name=None):
            return []

    fake_client_module = SimpleNamespace(MultiServerMCPClient=FakeClient)
    monkeypatch.setitem(sys.modules, "langchain_mcp_adapters", SimpleNamespace(client=fake_client_module))
    monkeypatch.setitem(sys.modules, "langchain_mcp_adapters.client", fake_client_module)
    load_mcp_tools(["a"], {"a": {"transport": "stdio"}, "b": {"transport": "stdio"}})
    assert set(seen["connections"]) == {"a"}


def test_run_coro_without_running_loop():
    async def coro():
        return 42

    assert _run_coro(coro()) == 42


async def test_run_coro_inside_running_loop():
    async def coro():
        return 42

    assert _run_coro(coro()) == 42
```

Append to `tests/unit/test_base_deepagent.py`:

```python
def test_mcp_tools_merged_into_agent_tools(patched, fake_meta, monkeypatch):
    mcp_tool = object()
    fake_meta.mcp_map = {"assistant": ["atlassian"]}
    fake_meta.mcp_servers_config = {"atlassian": {"transport": "stdio"}}
    monkeypatch.setattr(bd, "load_mcp_tools", lambda names, config: [mcp_tool])
    bd.create_base_deepagent()
    tools = patched.call_args.kwargs["tools"]
    assert tools == ["tool_a", "tool_b", mcp_tool]
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd autobots-devtools-shared-lib && make test-one TEST=tests/unit/test_deep_mcp.py`
Expected: FAIL — `ModuleNotFoundError: No module named '…deep_mcp'`

- [ ] **Step 3: Implement `deep_mcp.py`**

```python
# ABOUTME: Loads MCP server tools declared in deep-agents.yaml via langchain-mcp-adapters.
# ABOUTME: Bridges the async client into the sync factory (event-loop-aware asyncio.run).

import asyncio
import concurrent.futures
from collections.abc import Coroutine
from typing import Any

from autobots_devtools_shared_lib.common.observability import get_logger

logger = get_logger(__name__)


def _run_coro(coro: Coroutine[Any, Any, Any]) -> Any:
    """asyncio.run, falling back to a fresh thread when a loop is already running."""
    try:
        asyncio.get_running_loop()
    except RuntimeError:
        return asyncio.run(coro)
    with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
        return executor.submit(asyncio.run, coro).result()


def load_mcp_tools(
    server_names: list[str],
    servers_config: dict[str, dict[str, Any]],
) -> list[Any]:
    """Fetch tools for the referenced MCP servers, prefixed '<server>__<tool>'.

    The prefix avoids collisions with registered dynagent tools. Import is lazy
    so domains without mcp_servers: never need langchain-mcp-adapters installed.
    """
    if not server_names:
        return []
    from langchain_mcp_adapters.client import MultiServerMCPClient

    connections = {name: servers_config[name] for name in server_names}
    client = MultiServerMCPClient(connections)

    async def _fetch() -> list[tuple[str, Any]]:
        pairs: list[tuple[str, Any]] = []
        for server_name in server_names:
            for tool in await client.get_tools(server_name=server_name):
                pairs.append((server_name, tool))
        return pairs

    tools: list[Any] = []
    for server_name, tool in _run_coro(_fetch()):
        tool.name = f"{server_name}__{tool.name}"
        tools.append(tool)
    logger.info(f"Loaded {len(tools)} MCP tools from servers {server_names}")
    return tools
```

- [ ] **Step 4: Wire the factory**

In `base_deepagent.py`, import `load_mcp_tools` from `deep_mcp` and change the tool lines:

```python
    tools = [
        *meta.tool_map.get(agent_name, []),
        *load_mcp_tools(meta.mcp_map.get(agent_name, []), meta.mcp_servers_config),
    ]
```

and in `_build_roster_subagents`, the `tools=` entry becomes:

```python
            tools=[
                *meta.tool_map.get(agent_id, []),
                *load_mcp_tools(meta.mcp_map.get(agent_id, []), meta.mcp_servers_config),
            ],
```

- [ ] **Step 5: Add the dependency**

```bash
cd autobots-devtools-shared-lib
poetry add "langchain-mcp-adapters@>=0.1.11,<2.0"
```

If the resolver rejects that range against the pinned langchain stack, pick the newest version it accepts (`poetry add langchain-mcp-adapters@latest` and note the pin). Unit tests stub the client, so they pass either way; the dependency is for real MCP-enabled domains.

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd autobots-devtools-shared-lib && make test-one TEST=tests/unit/test_deep_mcp.py && make test-one TEST=tests/unit/test_base_deepagent.py`
Expected: PASS (P6 complete)

- [ ] **Step 7: Full check + commit**

Run: `cd autobots-devtools-shared-lib && make check-format && make type-check && make test-fast`
Expected: all PASS

```bash
cd autobots-devtools-shared-lib
git add src/autobots_devtools_shared_lib/dynagent/agents/deep_mcp.py \
        src/autobots_devtools_shared_lib/dynagent/agents/base_deepagent.py \
        pyproject.toml poetry.lock \
        tests/unit/test_deep_mcp.py tests/unit/test_base_deepagent.py
git commit -m "feat(dynagent): config-driven MCP servers with prefixed tool merging"
```

---

## Phase P7 — config-driven rubric grading

### Task 18: `rubric:` config validation at load

Task 2 already parses the per-agent `rubric:` dict; this task validates its shape at config load: `max_iterations` an int in `[1, 20]` (deepagents' hard cap), `model` a valid profile/inline ref. Grader **tool** names are validated at middleware build (Task 19) against the tool registry — the registry is populated by `register_usecase_tools` at startup, after YAML load.

**Files:**
- Modify: `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/dynagent/agents/agent_config_utils.py`
- Test: `autobots-devtools-shared-lib/tests/unit/test_deep_config_keys.py` (extend)

**Interfaces:**
- Produces: `load_agents_config` raises `ValueError` naming the agent for a malformed `rubric:` block.

- [ ] **Step 1: Write the failing tests**

Append to `tests/unit/test_deep_config_keys.py`:

```python
def _write_rubric_yaml(tmp_path, monkeypatch, rubric_lines: str):
    _reset_agent_config()
    (tmp_path / "deep-agents.yaml").write_text(
        "agents:\n"
        "  assistant:\n"
        "    prompt: assistant\n"
        "    is_default: true\n"
        "    tools: []\n"
        "    rubric:\n" + rubric_lines
    )
    monkeypatch.setattr(cfg, "get_config_dir", lambda: tmp_path)
    settings = DynagentSettings(agents_config_filename="deep-agents.yaml")
    monkeypatch.setattr(cfg, "get_dynagent_settings", lambda: settings)


def test_rubric_max_iterations_out_of_range_fails(tmp_path, monkeypatch):
    _write_rubric_yaml(tmp_path, monkeypatch, "      max_iterations: 25\n")
    with pytest.raises(ValueError, match="max_iterations"):
        load_agents_config()
    _reset_agent_config()


def test_rubric_max_iterations_non_int_fails(tmp_path, monkeypatch):
    _write_rubric_yaml(tmp_path, monkeypatch, "      max_iterations: three\n")
    with pytest.raises(ValueError, match="max_iterations"):
        load_agents_config()
    _reset_agent_config()


def test_rubric_bad_model_ref_fails(tmp_path, monkeypatch):
    _write_rubric_yaml(tmp_path, monkeypatch, "      model: openai:gpt-5.5\n")
    with pytest.raises(ValueError, match="openai"):
        load_agents_config()
    _reset_agent_config()


def test_valid_rubric_loads(tmp_path, monkeypatch):
    _write_rubric_yaml(
        tmp_path, monkeypatch, "      max_iterations: 3\n      prompt: rubric-grader\n"
    )
    agents = load_agents_config()
    assert agents["assistant"].rubric == {"max_iterations": 3, "prompt": "rubric-grader"}
    _reset_agent_config()
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd autobots-devtools-shared-lib && make test-one TEST=tests/unit/test_deep_config_keys.py`
Expected: the three failure tests FAIL (`DID NOT RAISE`)

- [ ] **Step 3: Implement the validation**

In `load_agents_config`'s validation block (alongside the model-ref and MCP checks):

```python
    for agent_id, agent_cfg in agents.items():
        if agent_cfg.rubric is None:
            continue
        rubric = agent_cfg.rubric
        if not isinstance(rubric, dict):
            msg = f"Agent '{agent_id}': rubric: must be a mapping"
            raise ValueError(msg)
        max_iterations = rubric.get("max_iterations", 3)
        if (
            not isinstance(max_iterations, int)
            or isinstance(max_iterations, bool)
            or not 1 <= max_iterations <= 20
        ):
            msg = f"Agent '{agent_id}': rubric.max_iterations must be an int in [1, 20]"
            raise ValueError(msg)
        rubric_model = rubric.get("model")
        if rubric_model is not None:
            try:
                validate_model_ref(rubric_model, _GLOBAL_MODEL_PROFILES)
            except ValueError as e:
                msg = f"Agent '{agent_id}' rubric: {e}"
                raise ValueError(msg) from e
```

(`validate_model_ref` is already imported locally in this block from Task 4.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd autobots-devtools-shared-lib && make test-one TEST=tests/unit/test_deep_config_keys.py`
Expected: PASS (all)

- [ ] **Step 5: Commit**

```bash
cd autobots-devtools-shared-lib
git add src/autobots_devtools_shared_lib/dynagent/agents/agent_config_utils.py tests/unit/test_deep_config_keys.py
git commit -m "feat(dynagent): validate rubric: config at load"
```

---

### Task 19: `RubricMiddleware` construction, factory/subagent wiring, invocation passthrough

`rubric:` presence appends a configured `deepagents.RubricMiddleware` — after `ToolResilienceMiddleware`, before caller middleware. Criteria are **per-invocation state** (a `rubric` string in the input), which `invoke_deepagent`/`ainvoke_deepagent` already pass through verbatim; this task locks that with tests. Non-satisfied terminations are driver-side follow-up (spec §10), not scoped here.

**Files:**
- Create: `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/dynagent/agents/deep_rubric.py`
- Modify: `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/dynagent/agents/base_deepagent.py`
- Test: `autobots-devtools-shared-lib/tests/unit/test_deep_rubric.py` (create), `tests/unit/test_invocation_utils.py` (extend)

**Interfaces:**
- Produces (`deep_rubric.py`): `build_rubric_middleware(meta: Any, agent_name: str, agent_model: Any) -> RubricMiddleware | None` — `None` when the agent has no `rubric:`; grader model = `rubric.model` resolved via `resolve_model_ref`, else `agent_model` (the agent's own resolved model); grader prompt = `load_prompt(rubric["prompt"])` when set, else deepagents' built-in (pass `system_prompt=None`); grader tools resolved from the dynagent registry — unknown name raises `ValueError`.
- Modifies (Task 13's helper): `_build_roster_subagents(meta, main_agent_name, prompt_values, main_model)` — gains a `main_model` parameter so a model-less subagent's rubric grader defaults to the main agent's resolved model; a rubric-enabled subagent gets `subagent["middleware"] = [rubric_middleware]`.
- Consumes: `RubricMiddleware(model=…, system_prompt=…, tools=…, max_iterations=…)` (deepagents 0.6.12), `resolve_model_ref` (Task 4), `load_prompt`, `get_all_tools`.

- [ ] **Step 1: Write the failing tests**

Create `autobots-devtools-shared-lib/tests/unit/test_deep_rubric.py`:

```python
# ABOUTME: Unit tests for config-driven RubricMiddleware construction and factory wiring.
# ABOUTME: Covers grader model/prompt/tools resolution, ordering, and rubric state passthrough.

from types import SimpleNamespace
from unittest.mock import patch

import pytest
from deepagents import RubricMiddleware

import autobots_devtools_shared_lib.dynagent.agents.deep_rubric as dr
from autobots_devtools_shared_lib.dynagent.agents.deep_rubric import build_rubric_middleware


def _meta(rubric=None, profiles=None):
    return SimpleNamespace(
        rubric_map={"assistant": rubric},
        model_profiles=profiles or {},
    )


def test_no_rubric_returns_none():
    assert build_rubric_middleware(_meta(None), "assistant", "AGENT_MODEL") is None


def test_grader_defaults_to_agent_model():
    mw = build_rubric_middleware(_meta({}), "assistant", "AGENT_MODEL")
    assert isinstance(mw, RubricMiddleware)
    assert mw._model == "AGENT_MODEL"
    assert mw.max_iterations == 3


def test_grader_model_resolved_from_profile():
    profiles = {"cheap-docs": {"provider": "anthropic", "name": "claude-haiku-4-5"}}
    with patch.object(dr, "resolve_model_ref", return_value="GRADER") as resolve:
        mw = build_rubric_middleware(
            _meta({"model": "cheap-docs"}, profiles), "assistant", "AGENT_MODEL"
        )
    resolve.assert_called_once_with("cheap-docs", profiles)
    assert mw._model == "GRADER"


def test_grader_prompt_loaded_from_prompt_file():
    with patch.object(dr, "load_prompt", return_value="Grade strictly.") as load:
        mw = build_rubric_middleware(
            _meta({"prompt": "rubric-grader"}), "assistant", "AGENT_MODEL"
        )
    load.assert_called_once_with("rubric-grader")
    assert mw._system_prompt == "Grade strictly."


def test_grader_tools_resolved_from_registry():
    fake_tool = SimpleNamespace(name="run_test_suite")
    with patch.object(dr, "get_all_tools", return_value=[fake_tool]):
        mw = build_rubric_middleware(
            _meta({"tools": ["run_test_suite"]}), "assistant", "AGENT_MODEL"
        )
    assert mw._tools == [fake_tool]


def test_unknown_grader_tool_fails_fast():
    with patch.object(dr, "get_all_tools", return_value=[]):
        with pytest.raises(ValueError, match="run_test_suite"):
            build_rubric_middleware(
                _meta({"tools": ["run_test_suite"]}), "assistant", "AGENT_MODEL"
            )


def test_max_iterations_forwarded():
    mw = build_rubric_middleware(_meta({"max_iterations": 5}), "assistant", "AGENT_MODEL")
    assert mw.max_iterations == 5
```

Append to `tests/unit/test_base_deepagent.py`:

```python
def test_rubric_middleware_ordered_after_resilience(patched, fake_meta, monkeypatch):
    rubric_mw = object()
    monkeypatch.setattr(bd, "build_rubric_middleware", lambda meta, name, model: rubric_mw)
    extra = object()
    bd.create_base_deepagent(middleware=[extra])
    middleware = patched.call_args.kwargs["middleware"]
    assert isinstance(middleware[0], ToolResilienceMiddleware)
    assert middleware[1] is rubric_mw
    assert middleware[2] is extra


def test_no_rubric_no_extra_middleware(patched, monkeypatch):
    monkeypatch.setattr(bd, "build_rubric_middleware", lambda meta, name, model: None)
    bd.create_base_deepagent()
    middleware = patched.call_args.kwargs["middleware"]
    assert len(middleware) == 1
```

Append to `tests/unit/test_deep_subagents.py`:

```python
def test_rubric_enabled_subagent_gets_middleware(patched, fake_meta, monkeypatch):
    rubric_mw = object()
    fake_meta.rubric_map = {"assistant": None, "researcher": {"max_iterations": 2}}
    monkeypatch.setattr(
        bd,
        "build_rubric_middleware",
        lambda meta, name, model: rubric_mw if name == "researcher" else None,
    )
    bd.create_base_deepagent()
    sub = _subagents(patched)[0]
    assert sub["middleware"] == [rubric_mw]
```

Append to `tests/unit/test_invocation_utils.py`:

```python
def test_invoke_deepagent_passes_rubric_through(monkeypatch):
    import autobots_devtools_shared_lib.dynagent.agents.agent_config_utils as cfg
    import autobots_devtools_shared_lib.dynagent.agents.base_deepagent as bd
    from autobots_devtools_shared_lib.dynagent.agents.invocation_utils import invoke_deepagent

    monkeypatch.setattr(cfg, "get_agent_list", lambda: ["assistant"])
    captured: dict = {}

    class FakeAgent:
        def invoke(self, input_state, config=None):
            captured.update(input_state)
            return dict(input_state)

    monkeypatch.setattr(bd, "create_base_deepagent", lambda **kwargs: FakeAgent())
    result = invoke_deepagent(
        agent_name="assistant",
        input_state={"messages": [], "rubric": "- answer cites a source"},
        enable_tracing=False,
    )
    assert captured["rubric"] == "- answer cites a source"
    assert result["rubric"] == "- answer cites a source"


async def test_ainvoke_deepagent_passes_rubric_through(monkeypatch):
    import autobots_devtools_shared_lib.dynagent.agents.agent_config_utils as cfg
    import autobots_devtools_shared_lib.dynagent.agents.base_deepagent as bd
    from autobots_devtools_shared_lib.dynagent.agents.invocation_utils import ainvoke_deepagent

    monkeypatch.setattr(cfg, "get_agent_list", lambda: ["assistant"])
    captured: dict = {}

    class FakeAgent:
        async def ainvoke(self, input_state, config=None):
            captured.update(input_state)
            return dict(input_state)

    monkeypatch.setattr(bd, "create_base_deepagent", lambda **kwargs: FakeAgent())
    result = await ainvoke_deepagent(
        agent_name="assistant",
        input_state={"messages": [], "rubric": "- answer cites a source"},
        enable_tracing=False,
    )
    assert captured["rubric"] == "- answer cites a source"
    assert result["rubric"] == "- answer cites a source"
```

(These patch `cfg.get_agent_list` and `bd.create_base_deepagent` at their source modules because `invocation_utils` imports both lazily inside the function; match any additional mocking conventions already present in `test_invocation_utils.py`.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd autobots-devtools-shared-lib && make test-one TEST=tests/unit/test_deep_rubric.py`
Expected: FAIL — `ModuleNotFoundError: No module named '…deep_rubric'`

- [ ] **Step 3: Implement `deep_rubric.py`**

```python
# ABOUTME: Builds deepagents RubricMiddleware instances from rubric: roster config.
# ABOUTME: Grader model/prompt/tools reuse the profile, prompt-file, and registry plumbing.

from typing import Any

from deepagents import RubricMiddleware

from autobots_devtools_shared_lib.dynagent.agents.agent_config_utils import load_prompt
from autobots_devtools_shared_lib.dynagent.llm.model_resolution import resolve_model_ref
from autobots_devtools_shared_lib.dynagent.tools.tool_registry import get_all_tools


def _resolve_grader_tools(agent_name: str, tool_names: list[str]) -> list[Any]:
    tool_by_name = {t.name: t for t in get_all_tools()}
    resolved: list[Any] = []
    for tool_name in tool_names:
        if tool_name not in tool_by_name:
            msg = (
                f"Agent '{agent_name}': rubric grader tool '{tool_name}' is not registered. "
                f"Available tools: {sorted(tool_by_name)}"
            )
            raise ValueError(msg)
        resolved.append(tool_by_name[tool_name])
    return resolved


def build_rubric_middleware(
    meta: Any, agent_name: str, agent_model: Any
) -> RubricMiddleware | None:
    """Return a configured RubricMiddleware, or None when the agent has no rubric: block.

    The middleware is a no-op at runtime unless the caller passes a `rubric`
    string in invocation state, so appending it when configured is safe.
    """
    rubric = meta.rubric_map.get(agent_name)
    if rubric is None:
        return None

    model_ref = rubric.get("model")
    model = resolve_model_ref(model_ref, meta.model_profiles) if model_ref else agent_model

    prompt_name = rubric.get("prompt")
    system_prompt = load_prompt(prompt_name) if prompt_name else None

    tools = _resolve_grader_tools(agent_name, rubric.get("tools") or [])

    return RubricMiddleware(
        model=model,
        system_prompt=system_prompt,
        tools=tools or None,
        max_iterations=rubric.get("max_iterations", 3),
    )
```

Note: `test_grader_defaults_to_agent_model` uses `rubric={}` — an empty dict is a configured (if all-default) rubric, which is why the guard is `if rubric is None`, not `if not rubric`.

- [ ] **Step 4: Wire the factory and subagents**

In `base_deepagent.py`, import `build_rubric_middleware` from `deep_rubric`, then in `create_base_deepagent` replace the model/middleware lines:

```python
    agent_model = resolve_agent_model(meta, agent_name)
    engine_middleware: list[Any] = [ToolResilienceMiddleware()]
    rubric_middleware = build_rubric_middleware(meta, agent_name, agent_model)
    if rubric_middleware is not None:
        engine_middleware.append(rubric_middleware)
```

with the call using `model=agent_model,` and `middleware=[*engine_middleware, *(middleware or ())],`.

Extend `_build_roster_subagents` to accept and use the main model:

```python
def _build_roster_subagents(
    meta: AgentMeta,
    main_agent_name: str,
    prompt_values: dict[str, Any] | None,
    main_model: Any,
) -> list[SubAgent]:
```

and inside the loop, after the skills/model block:

```python
        if meta.model_map.get(agent_id):
            subagent_model = resolve_agent_model(meta, agent_id)
            subagent["model"] = subagent_model
        else:
            subagent_model = main_model  # deepagents inherits; grader needs it explicitly
        rubric_middleware = build_rubric_middleware(meta, agent_id, subagent_model)
        if rubric_middleware is not None:
            subagent["middleware"] = [rubric_middleware]
```

(replacing Task 13's `if meta.model_map.get(agent_id): subagent["model"] = …` line) and update the call site to `_build_roster_subagents(meta, agent_name, prompt_values, agent_model)`.

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd autobots-devtools-shared-lib && make test-one TEST=tests/unit/test_deep_rubric.py && make test-one TEST=tests/unit/test_base_deepagent.py && make test-one TEST=tests/unit/test_deep_subagents.py && make test-one TEST=tests/unit/test_invocation_utils.py`
Expected: PASS (P7 complete)

- [ ] **Step 6: Full check + commit**

Run: `cd autobots-devtools-shared-lib && make check-format && make type-check && make test-fast`
Expected: all PASS

```bash
cd autobots-devtools-shared-lib
git add src/autobots_devtools_shared_lib/dynagent/agents/deep_rubric.py \
        src/autobots_devtools_shared_lib/dynagent/agents/base_deepagent.py \
        tests/unit/test_deep_rubric.py tests/unit/test_base_deepagent.py \
        tests/unit/test_deep_subagents.py tests/unit/test_invocation_utils.py
git commit -m "feat(dynagent): config-driven rubric grading via RubricMiddleware"
```

---

## Verification

### Task 20: Integration/sanity tests + workspace regression

Two env-gated tests (skipped when their environment is absent) plus the full workspace check.

**Files:**
- Create: `autobots-devtools-shared-lib/tests/integration/test_deepagent_skills_sanity.py` (and `tests/integration/__init__.py` if the directory is new)
- Create: `autobots-agents-mer/tests/integration/test_fserver_backend_live.py`

**Interfaces:**
- Consumes: the complete factory (Tasks 1–19), `FileServerBackend` (Tasks 10–11).

- [ ] **Step 1: Write the skills+memory sanity test (shared-lib)**

Create `autobots-devtools-shared-lib/tests/integration/test_deepagent_skills_sanity.py`:

```python
# ABOUTME: Sanity test - deep engine with skills + memory on a FilesystemBackend domain.
# ABOUTME: Builds a temp AMA-style domain; requires ANTHROPIC_API_KEY (skipped otherwise).

import os

import pytest

import autobots_devtools_shared_lib.dynagent.agents.agent_config_utils as cfg
from autobots_devtools_shared_lib.dynagent.agents.agent_config_utils import _reset_agent_config
from autobots_devtools_shared_lib.dynagent.agents.agent_meta import AgentMeta
from autobots_devtools_shared_lib.dynagent.agents.base_deepagent import create_base_deepagent
from autobots_devtools_shared_lib.dynagent.config.dynagent_settings import DynagentSettings

pytestmark = [
    pytest.mark.integration,
    pytest.mark.slow,
    pytest.mark.skipif(not os.getenv("ANTHROPIC_API_KEY"), reason="needs ANTHROPIC_API_KEY"),
]

SKILL_MD = """---
name: favorite-color
description: Answers questions about the project's favorite color.
---
When asked about the favorite color, answer exactly: TEAL-042.
"""


@pytest.fixture
def ama_domain(tmp_path, monkeypatch):
    _reset_agent_config()
    AgentMeta.reset()
    skills_dir = tmp_path / "skills" / "favorite-color"
    skills_dir.mkdir(parents=True)
    (skills_dir / "SKILL.md").write_text(SKILL_MD)
    (tmp_path / "AGENTS.md").write_text("# Conventions\nThis project loves precise answers.\n")
    workspace = tmp_path / "workspace"

    (tmp_path / "prompts").mkdir()
    (tmp_path / "prompts" / "assistant.md").write_text(
        "You are a helpful assistant. Use your skills to answer exactly."
    )
    (tmp_path / "deep-agents.yaml").write_text(
        f"""
default_backend:
  type: filesystem
  root_dir: {workspace}

agents:
  assistant:
    prompt: assistant
    is_default: true
    tools: []
    skills: ["{tmp_path / 'skills'}/"]
    memory: ["{tmp_path / 'AGENTS.md'}"]
"""
    )
    settings = DynagentSettings(
        agents_config_filename="deep-agents.yaml",
        llm_provider="anthropic",
        llm_model="claude-sonnet-4-6",
        anthropic_api_key=os.environ["ANTHROPIC_API_KEY"],
    )
    monkeypatch.setattr(cfg, "get_config_dir", lambda: tmp_path)
    monkeypatch.setattr(cfg, "get_dynagent_settings", lambda: settings)
    monkeypatch.setattr(
        "autobots_devtools_shared_lib.dynagent.llm.llm.get_dynagent_settings", lambda: settings
    )
    yield
    _reset_agent_config()
    AgentMeta.reset()


def test_agent_reads_skill_and_answers(ama_domain):
    agent = create_base_deepagent()
    result = agent.invoke(
        {"messages": [{"role": "user", "content": "What is the project's favorite color?"}]},
        config={"configurable": {"thread_id": "sanity-1"}, "recursion_limit": 50},
    )
    final_text = str(result["messages"][-1].content)
    assert "TEAL-042" in final_text
```

- [ ] **Step 2: Write the live-sidecar test (MER)**

Create `autobots-agents-mer/tests/integration/test_fserver_backend_live.py`:

```python
# ABOUTME: Live integration test - FileServerBackend against the file-server sidecar.
# ABOUTME: Requires the sidecar at FILE_SERVER_HOST:FILE_SERVER_PORT (skipped otherwise).

import os
import uuid

import httpx
import pytest

from autobots_devtools_shared_lib.dynagent.agents.fserver_backend import FileServerBackend


def _sidecar_up() -> bool:
    host = os.getenv("FILE_SERVER_HOST", "localhost")
    port = os.getenv("FILE_SERVER_PORT", "9002")
    try:
        return httpx.get(f"http://{host}:{port}/health", timeout=2.0).status_code == 200
    except httpx.HTTPError:
        return False


pytestmark = [
    pytest.mark.integration,
    pytest.mark.skipif(not _sidecar_up(), reason="file-server sidecar not reachable"),
]


def test_write_read_ls_edit_grep_roundtrip():
    backend = FileServerBackend(session_id=f"it-{uuid.uuid4().hex[:8]}")
    directory = f"/it-{uuid.uuid4().hex[:8]}"
    path = f"{directory}/note.txt"

    write = backend.write(path, "hello world\nsecond line")
    assert write.error is None, write.error

    read = backend.read(path)
    assert read.error is None
    assert "hello world" in read.file_data["content"]

    listing = backend.ls(directory + "/")
    assert listing.error is None
    assert path in {entry["path"] for entry in listing.entries}

    edit = backend.edit(path, "world", "sidecar")
    assert edit.error is None
    assert "sidecar" in backend.read(path).file_data["content"]

    grep = backend.grep("sidecar", path=directory)
    assert grep.error is None
    assert any(match["path"] == path for match in grep.matches)

    second_write = backend.write(path, "overwrite attempt")
    assert second_write.error is not None
    assert "already exists" in second_write.error
```

- [ ] **Step 3: Run both (skips are a pass without env)**

Run: `cd autobots-devtools-shared-lib && make test-one TEST=tests/integration/test_deepagent_skills_sanity.py`
Expected: PASS, or SKIPPED without `ANTHROPIC_API_KEY`.

Run: `cd autobots-agents-mer && make test-one TEST=tests/integration/test_fserver_backend_live.py`
Expected: PASS with the sidecar running (`FILE_SERVER_HOST`/`PORT`), else SKIPPED. If MER's pyright pre-commit trips on the shared-lib import, confirm `venvPath`/`venv` are set per the workspace CLAUDE.md gotcha.

- [ ] **Step 4: Full workspace regression**

Run from `ws-autobots/`: `make all-checks`
Expected: format-check, lint, type-check, and all repo test suites PASS — react engine and Nurture untouched (spec's regression requirement).

- [ ] **Step 5: Commit**

```bash
cd autobots-devtools-shared-lib
git add tests/integration/
git commit -m "test(dynagent): skills+memory sanity test for the deep engine"
cd ../autobots-agents-mer
git add tests/integration/test_fserver_backend_live.py
git commit -m "test(mer): live-sidecar integration test for FileServerBackend"
```

---

## Coverage map (spec § → task)

| Spec section | Tasks |
|---|---|
| §1 config schema + env interpolation | 1, 2, 5 |
| §2 model profiles + `lm()` | 3, 4 |
| §3 backend registry + composite | 6, 12 |
| §4 `FileServerBackend` + raw refactor | 9, 10, 11 |
| §4b tool resilience | 7, 8 |
| §5 config-driven subagents | 13 |
| §6 response_format / interrupt_on / permissions | 14 |
| §7 escape hatches | 8 (`backend`), 12 (`store`), 15 (rest) |
| §8 factory end state | 8, 12–15, 17, 19 |
| §9 MCP servers (P6) | 16, 17 |
| §10 rubric grading (P7) | 18, 19 |
| Testing (unit/integration/regression) | per-task + 20 |

Known deviations from the spec (deliberate, documented above): description validation is gated to `deep-agents.yaml` files so react rosters keep loading; the AMA sanity test builds a temp domain instead of editing `agent_configs/ama/` (domain rollout is product work); `read_file`'s internal `"Payload: …"` debug log line is not preserved in the wrapper.

