# Deep Agent Engine Parity — config-first capabilities for `create_base_deepagent`

**Date:** 2026-07-03
**Status:** Approved design (pre-implementation)
**Scope:** `autobots-devtools-shared-lib` (config schema, backend registry, `FileServerBackend`, `lm()` extension, factory), domain configs (`deep-agents.yaml`)
**Builds on:** `2026-07-01-deepagent-engine-design.md` (thin wrapper, Tasks 1–7 of its plan)

## Problem

`create_base_deepagent` currently forwards only `model, tools, system_prompt, state_schema,
checkpointer, name, subagents` to deepagents' `create_deep_agent` (0.6.12). Everything else the
deep engine offers is unreachable from dynagent:

- `skills` (Anthropic-style skill folders), `memory` (`AGENTS.md` files)
- `backend` (virtual FS location: state / real disk / custom), `permissions`
- `interrupt_on` (HITL), `response_format` (the deep engine currently **ignores** the roster's
  `output:` schema config)
- `middleware`, `store`, `context_schema`, `debug`, `cache`
- Config-driven subagents (the original spec's "phase-2 hook" is still a raw Python passthrough)
- Per-agent model selection (everything runs on the single settings-configured `lm()`)

Additionally, MER's file I/O runs through a file-server sidecar (`fserver_client_utils.py`,
`FILE_SERVER_HOST:PORT`, default port 9002). Deep-engine domains need the agent's virtual
filesystem to be **backed by that sidecar**, with per-session workspace scoping
(`session_id`, `jira_number`, `repo_name`).

**Version note:** the comparison target is deepagents **0.6.12** (workspace venv, the pinned
Phase 0 target). The blog repo's venv holds 0.4.12 with an older API — not the reference. The
blog's `deep-agents-langchain-blog/agent.py` is the target *usage shape* for Phase 1
(skills + memory + filesystem backend).

## Goal

Phased path to full `create_deep_agent` parity, **config-first**: capabilities are declared in
`deep-agents.yaml` per agent; the factory instantiates everything. Python kwargs on
`create_base_deepagent` remain only as escape hatches for live objects that cannot be YAML.

## Non-Goals

- No changes to the react engine (`create_base_agent`, `inject_agent`) or Nurture.
- No file-server API changes (edit/glob/grep are emulated client-side; server endpoints are a
  possible later optimization, not scoped here).
- No per-agent API keys in YAML — secrets stay in `DynagentSettings`/env.
- No sandbox/`execute` backend support (no `SandboxBackendProtocol` implementation).

## Design

### 1. Config schema — new `deep-agents.yaml` keys

`AgentConfig.from_dict` gains optional, deep-engine-only fields (ignored by the react engine):

```yaml
# deep-agents.yaml
default_backend:              # domain-level; applies to main agent + subagents
  type: fserver               # state (default) | filesystem | fserver
  # root_dir: "${WORKSPACE_ROOT}"   # filesystem-type option, env-interpolated

agents:
  assistant:
    is_default: true          # existing key → designates the MAIN agent
    prompt: "assistant"
    model: "anthropic:claude-sonnet-4-6"   # NEW, optional → per-agent model
    tools: ["internet_search"]
    skills: ["skills/"]       # NEW → create_deep_agent(skills=...)
    memory: ["AGENTS.md"]     # NEW → create_deep_agent(memory=...)
    interrupt_on:             # NEW (P4) → HITL
      write_file: true
    permissions: []           # NEW (P4) → filesystem permission rules
    output:                   # existing key → response_format (P4)
      schema: "assistant.json"

  researcher:                 # non-default roster entry → subagent (P3)
    prompt: "researcher"
    description: "Deep research on a topic"   # NEW — required for subagents
    model: "anthropic:claude-opus-4-8"
    tools: ["internet_search"]
    skills: ["skills/research/"]

  code-doc:
    prompt: "code-doc"
    description: "Writes code documentation"
    model: "anthropic:claude-haiku-4-5"       # cheap model for doc generation
```

- **`AgentConfig`** new fields: `model: str | dict | None`, `skills: list[str]`,
  `memory: list[str]`, `interrupt_on: dict[str, bool | dict]`, `permissions: list`,
  `description: str | None`.
- **`load_agents_config`** additionally parses the top-level `default_backend` block.
- **`AgentMeta`** gains `model_map`, `skills_map`, `memory_map`, `interrupt_map`,
  `permissions_map`, `description_map`, `backend_config` — built like the existing maps.
- **Env interpolation:** `${VAR}` in string config values is expanded at load time
  (`string.Template`-style), e.g. `root_dir: "${WORKSPACE_ROOT}"`.

### 2. Per-agent models — `lm()` extension

- `lm()` becomes `lm(model: str | None = None, provider: str | None = None,
  temperature: float | None = None)`; every argument defaults to the current settings value, so
  all existing callers are untouched. API keys still come from settings only.
- YAML `model:` accepts:
  - `"provider:model"` string (deepagents convention), e.g. `"anthropic:claude-haiku-4-5"`;
  - bare `"model-name"` → settings-configured provider with that model;
  - dict form `{name: "...", provider: "...", temperature: 0.2}` for temperature overrides.
- Resolution lives in a helper (`resolve_agent_model(meta, agent_name) -> BaseChatModel`) that
  falls back to plain `lm()` when no `model:` is configured. Unknown provider → same
  `ValueError` path as today.

### 3. Backend registry + env interpolation

New module `dynagent/agents/deep_backend.py`:

```python
_BACKEND_REGISTRY: dict[str, Callable[[dict], BACKEND_TYPES | None]] = {
    "state":      lambda cfg: None,   # deepagents default (StateBackend)
    "filesystem": lambda cfg: FilesystemBackend(root_dir=cfg["root_dir"]),
    "fserver":    lambda cfg: _fserver_factory(cfg),   # returns a BackendFactory (see §4)
}
```

- `resolve_backend(backend_config, override=None)`: an explicit `backend=` kwarg instance
  (escape hatch) wins over YAML; unknown `type:` fails fast with the valid choices listed.
- `type: filesystem` creates `root_dir` if missing (mirrors the reference impl).

### 4. `FileServerBackend` — sidecar-backed virtual filesystem

Implements deepagents' `BackendProtocol` on top of the file-server REST API. Registered as
`type: fserver`. Because `BackendFactory = Callable[[ToolRuntime], BackendProtocol]`, the
registry returns a **factory**, so per-invocation state flows in:

```python
def _fserver_factory(cfg: dict) -> BackendFactory:
    return lambda rt: FileServerBackend(
        session_id=rt.state.get("session_id"),
        workspace_context=workspace_context_from_state(rt.state),  # jira_number, repo_name, ...
    )
```

Method mapping (host/port from `FILE_SERVER_HOST`/`FILE_SERVER_PORT` env, as today):

| BackendProtocol | File server | Approach |
|---|---|---|
| `ls` / `ls_info` | `POST /listFiles` | direct |
| `read` | `POST /readFile` | direct (UTF-8; binary → base64 as today) |
| `write` | `POST /writeFile` | direct |
| `edit` | — | client-side: read → occurrence-checked replace → write |
| `glob` | — | client-side: `listFiles` + `fnmatch` |
| `grep` | — | client-side: `listFiles` + `readFile` + search (accepted: chatty on large workspaces) |
| `upload_files` / `download_files` | `writeFile` / `readFile` + `createDownloadLink` | direct |

Async variants delegate via `asyncio.to_thread` in the first cut.

**Raw-function refactor (non-intrusive):** `fserver_client_utils` functions return tool-facing
error **strings**, while `BackendProtocol` expects structured results and raised errors. Extract
thin raw functions (return bytes / raise `httpx` errors) inside `fserver_client_utils`; the
existing tool functions become wrappers with byte-identical behavior; `FileServerBackend`
consumes the raw layer. Existing MER tools are untouched.

### 5. Config-driven subagents

- The `is_default: true` roster entry is the main agent; **every other entry becomes a
  deepagents `SubAgent`**:

```python
SubAgent(
    name=agent_id,
    description=meta.description_map[agent_id],
    system_prompt=_resolve_system_prompt(meta, agent_id, prompt_values),  # same format_map path
    tools=meta.tool_map.get(agent_id, []),
    skills=meta.skills_map.get(agent_id) or None,
    model=resolve_agent_model(meta, agent_id),   # per-agent model (§2)
)
```

- Subagents inherit the domain backend; deepagents wires its own middleware stack per subagent.
- The `subagents:` Python kwarg stays as an **additive** escape hatch (e.g. `CompiledSubAgent`);
  YAML roster and kwarg lists are merged, kwarg wins on name collision.
- Validation: a non-default roster entry without `description:` fails fast at config load
  (deepagents requires it for the `task` tool).

### 6. Structured output, HITL, permissions

- **`response_format`**: when the main agent has `output:` config, pass the resolved JSON schema
  dict from `output_schema_map` to `create_deep_agent(response_format=...)` — closes the gap
  where the deep engine silently ignores `output_schema`.
- **`interrupt_on`**: YAML map forwarded (`true`/`false` or `InterruptOnConfig` dict form). Only
  meaningful with a checkpointer + interrupt-aware driver; documented in the domain setup notes.
- **`permissions`**: YAML list forwarded to `create_deep_agent(permissions=...)`.

### 7. Escape-hatch kwargs (live objects / dev flags)

`create_base_deepagent` keeps/gains kwargs only for what cannot be YAML:
`checkpointer` (exists), `backend` (instance override), `store`, `middleware`, `cache`,
`context_schema`, `debug`. `debug: true` is additionally allowed in YAML (scalar).
YAML remains the primary surface; kwargs are overrides.

### 8. Factory result (end state)

```python
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
    subagents=merged_subagents or None,          # YAML roster + kwarg escape hatch
    response_format=resolved_output_schema,      # from output: config
    interrupt_on=meta.interrupt_map.get(agent_name) or None,
    permissions=meta.permissions_map.get(agent_name) or None,
    middleware=middleware or (),
    store=store, cache=cache, context_schema=context_schema, debug=debug,
)
```

## Phasing (build order — reference-impl first)

| Phase | Content |
|---|---|
| **P1** | Config keys (`skills`, `memory`, `model`, `default_backend`) + `AgentMeta` maps + env interpolation + backend registry (`state`/`filesystem`) + `lm()` extension → parity with the blog reference `agent.py` |
| **P2** | `FileServerBackend` (`type: fserver`): raw-function extraction in `fserver_client_utils`, `BackendProtocol` implementation with client-side edit/glob/grep, runtime-state factory |
| **P3** | Config-driven subagents: roster mapping (with per-subagent model/skills), description validation, merge with `subagents:` kwarg |
| **P4** | `response_format` from `output:`, `interrupt_on`, `permissions` |
| **P5** | Escape-hatch kwargs (`store`, `middleware`, `cache`, `context_schema`, `debug`) |

Each phase is independently shippable; P2–P5 have no ordering dependencies between them beyond
P1's config plumbing.

## Testing

- **Unit (per phase):** fake `AgentMeta` + monkeypatched `create_deep_agent` asserting forwarded
  params (existing factory-test pattern); backend registry incl. `${VAR}` interpolation and
  unknown-type failure; `lm()` override args + backward compatibility; `FileServerBackend`
  against a mocked httpx transport — direct methods plus emulation semantics (especially
  `edit`'s unique-occurrence check and `glob`/`grep` filtering); subagent mapping (roster →
  `SubAgent` list, description validation, kwarg merge precedence); `response_format` wiring
  from `output:` config.
- **Integration (`sanity`):** AMA agent with `skills` + `memory` on `FilesystemBackend` answers
  a question and reads a `SKILL.md`; one MER-side `integration`-marked test running
  `FileServerBackend` against a live sidecar.
- **Regression:** react engine + Nurture unaffected (new YAML keys are ignored on the
  `create_base_agent` path; `lm()` default behavior unchanged).

## Risks & Open Items

- **grep emulation cost** on large file-server workspaces (N+1 reads). Accepted for now;
  sidecar `/grep` endpoint is the known future optimization behind the same backend method.
- **Binary files via `read`**: base64 passthrough matches today's tool behavior but is odd
  inside an agent context window; revisit if AMA workspaces hold binaries.
- **`interrupt_on` end-to-end**: forwarding is trivial, but a driver (Chainlit/stream loop) must
  handle interrupts for it to be useful — P4 delivers the plumbing, driver UX is a separate
  effort.
- **deepagents version drift**: design is pinned to 0.6.12 semantics (`permissions`,
  `state_schema`, `BackendFactory`); re-verify signatures on any bump.
