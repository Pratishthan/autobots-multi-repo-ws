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

**Reference pass:** ChainAgents' `chainagents/runtime/core.py` (TOML-driven deepagents runtime)
was reviewed as a second reference. Adopted from it: **CompositeBackend path routes**, **named
model profiles**, and **tool-execution resilience middleware** (see §2–§4b). Explicitly not
adopted: nested/async subagents, summarization tuning + status events, configurable
`recursion_limit`, MCP server config, per-provider tool-schema sanitization (dynagent's tool
registry and backend design cover or defer these).

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
- No nested subagents (subagents owning child subagents) and no async/remote subagents
  (Agent Protocol) — flat main + one subagent level covers the AMA use case.
- No summarization tuning/status events, no configurable `recursion_limit`, no MCP server
  config (reviewed in the ChainAgents pass, deliberately not adopted).

## Design

### 1. Config schema — new `deep-agents.yaml` keys

`AgentConfig.from_dict` gains optional, deep-engine-only fields (ignored by the react engine):

```yaml
# deep-agents.yaml
models:                       # NEW — named model profiles (see §2)
  main:
    provider: anthropic
    name: claude-sonnet-4-6
  researcher:
    provider: anthropic
    name: claude-opus-4-8
    temperature: 0.3
  cheap-docs:
    provider: anthropic
    name: claude-haiku-4-5

default_backend:              # domain-level; applies to main agent + subagents
  type: composite             # state (default) | filesystem | fserver | composite
  routes:                     # composite-type option (see §3)
    "/workspace/": {type: fserver}
    "/memories/": {type: store}          # requires the store= kwarg (escape hatch)
  # root_dir: "${WORKSPACE_ROOT}"   # filesystem-type option, env-interpolated

agents:
  assistant:
    is_default: true          # existing key → designates the MAIN agent
    prompt: "assistant"
    model: main               # NEW, optional → profile name or inline "provider:name"
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
    model: researcher
    tools: ["internet_search"]
    skills: ["skills/research/"]

  code-doc:
    prompt: "code-doc"
    description: "Writes code documentation"
    model: cheap-docs         # cheap model for doc generation
```

- **`AgentConfig`** new fields: `model: str | None`, `skills: list[str]`,
  `memory: list[str]`, `interrupt_on: dict[str, bool | dict]`, `permissions: list`,
  `description: str | None`.
- **`load_agents_config`** additionally parses the top-level `default_backend` and `models`
  blocks.
- **`AgentMeta`** gains `model_map`, `skills_map`, `memory_map`, `interrupt_map`,
  `permissions_map`, `description_map`, `backend_config`, `model_profiles` — built like the
  existing maps.
- **Env interpolation:** `${VAR}` in string config values is expanded at load time
  (`string.Template`-style), e.g. `root_dir: "${WORKSPACE_ROOT}"`.

### 2. Per-agent models — named profiles + `lm()` extension

- Top-level `models:` block defines **named profiles**: `{provider, name, temperature}` per
  profile, all fields optional — omitted fields fall back to `DynagentSettings` values. API
  keys never appear in YAML; they stay in settings/env.
- Per-agent `model:` accepts:
  - a **profile name** (`model: cheap-docs`) — looked up in `model_profiles`;
  - an inline `"provider:model"` string (deepagents convention) for one-off use;
  - a bare `"model-name"` → settings-configured provider with that model.
  Lookup order: profile name first, then inline parse. A `model:` value that is neither a
  known profile nor parseable fails fast at config load.
- `lm()` becomes `lm(model: str | None = None, provider: str | None = None,
  temperature: float | None = None)`; every argument defaults to the current settings value, so
  all existing callers are untouched.
- Resolution lives in a helper (`resolve_agent_model(meta, agent_name) -> BaseChatModel`) that
  resolves profile/inline config through `lm(...)` and falls back to plain `lm()` when no
  `model:` is configured. **Inheritance:** subagents without `model:` use the main agent's
  resolved model. Unknown provider → same `ValueError` path as today.

### 3. Backend registry + env interpolation

New module `dynagent/agents/deep_backend.py`:

```python
_BACKEND_REGISTRY: dict[str, Callable[..., BACKEND_TYPES | None]] = {
    "state":      lambda cfg: None,   # deepagents default (StateBackend)
    "filesystem": lambda cfg: FilesystemBackend(root_dir=cfg["root_dir"]),
    "fserver":    lambda cfg: _fserver_factory(cfg),   # returns a BackendFactory (see §4)
    "store":      lambda cfg, store: StoreBackend(...),          # needs the store= kwarg
    "composite":  lambda cfg, **kw: _composite_factory(cfg, **kw),  # routes → recursion
}
```

- `resolve_backend(backend_config, override=None, store=None)`: an explicit `backend=` kwarg
  instance (escape hatch) wins over YAML; unknown `type:` fails fast with the valid choices
  listed.
- `type: filesystem` creates `root_dir` if missing (mirrors the reference impl).
- **`type: composite`** (adopted from ChainAgents) maps to deepagents' `CompositeBackend`:
  each entry in `routes:` is itself a backend config resolved recursively through the same
  registry; the unrouted default is `StateBackend`. Example: `/workspace/` → `fserver` (durable,
  session-scoped files), `/memories/` → `store` (persistent agent memories), everything else →
  ephemeral state. A `store`-type route without a `store=` kwarg fails fast at build time with
  a clear message.

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

### 4b. Tool-execution resilience middleware

Adopted from ChainAgents: a small `AgentMiddleware` in shared-lib
(`dynagent/middleware/tool_resilience.py`) implementing `wrap_tool_call` / `awrap_tool_call`:
a tool exception becomes a `ToolMessage(status="error")` with a truncated summary telling the
model to adjust inputs or take another approach, instead of aborting the whole run
(`asyncio.CancelledError` is re-raised). Always on for the deep engine — appended to the
`middleware` sequence passed to `create_deep_agent`. Deep-engine only; the react engine is
untouched.

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
    backend=resolve_backend(meta.backend_config, override=backend, store=store),
    subagents=merged_subagents or None,          # YAML roster + kwarg escape hatch
    response_format=resolved_output_schema,      # from output: config
    interrupt_on=meta.interrupt_map.get(agent_name) or None,
    permissions=meta.permissions_map.get(agent_name) or None,
    middleware=[ToolResilienceMiddleware(), *(middleware or ())],   # §4b, always on
    store=store, cache=cache, context_schema=context_schema, debug=debug,
)
```

## Phasing (build order — reference-impl first)

| Phase | Content |
|---|---|
| **P1** | Config keys (`skills`, `memory`, `model`, `models` profiles, `default_backend`) + `AgentMeta` maps + env interpolation + backend registry (`state`/`filesystem`) + `lm()` extension + model-profile resolution + `ToolResilienceMiddleware` → parity with the blog reference `agent.py` |
| **P2** | `FileServerBackend` (`type: fserver`): raw-function extraction in `fserver_client_utils`, `BackendProtocol` implementation with client-side edit/glob/grep, runtime-state factory. Plus `composite`/`store` registry types (CompositeBackend routes) |
| **P3** | Config-driven subagents: roster mapping (with per-subagent model/skills), description validation, merge with `subagents:` kwarg |
| **P4** | `response_format` from `output:`, `interrupt_on`, `permissions` |
| **P5** | Escape-hatch kwargs (`store`, `middleware`, `cache`, `context_schema`, `debug`) — note `store` moves up to P2 if a `store`-type route is needed then |

Each phase is independently shippable; P2–P5 have no ordering dependencies between them beyond
P1's config plumbing.

## Testing

- **Unit (per phase):** fake `AgentMeta` + monkeypatched `create_deep_agent` asserting forwarded
  params (existing factory-test pattern); backend registry incl. `${VAR}` interpolation,
  unknown-type failure, and composite-route recursion (incl. `store` route without `store=`
  kwarg failing fast); model-profile resolution (profile name, inline string, unknown-value
  load failure, subagent inheritance); `lm()` override args + backward compatibility;
  `ToolResilienceMiddleware` (exception → error `ToolMessage`, `CancelledError` re-raised);
  `FileServerBackend` against a mocked httpx transport — direct methods plus emulation
  semantics (especially `edit`'s unique-occurrence check and `glob`/`grep` filtering); subagent
  mapping (roster → `SubAgent` list, description validation, kwarg merge precedence);
  `response_format` wiring from `output:` config.
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
