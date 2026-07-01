# Deep Agent Engine — `create_base_deepagent`

**Date:** 2026-07-01
**Status:** Approved design (pre-implementation)
**Scope:** `autobots-devtools-shared-lib` (new factory + state), `autobots-agents-mer` (new AMA domain)

## Problem

Dynagent today ships a single agent engine: `create_base_agent` wraps LangChain's
`create_agent` and implements "multi-agent" behavior as **deterministic role-switching in one
shared context** — the `inject_agent` middleware hot-swaps prompt + tool subset per LLM call,
keyed on `state["agent_name"]`. This fits deterministic pipelines like the Nurture SDLC flow.

We now need to build **open-ended, general-assistant use cases** (an "AMA chatbot": retrieval +
action tools, where the model decides its own plan, steps, and when to delegate heavy subtasks
into isolated context). That is a fundamentally different execution model — it needs planning,
sub-agent context isolation, and large-tool-result offloading, none of which `create_base_agent`
provides. LangChain's Deep Agents (`create_deep_agent`) provides exactly this scaffolding.

## Goal

Introduce a **second, parallel engine** — `create_base_deepagent` wrapping `create_deep_agent` —
mirroring how `create_base_agent` wraps `create_agent`. Nurture stays on the existing engine;
AMA-style use cases run on the deep engine. Both share dynagent's config, state-identity, tool
registry, invocation, and streaming plumbing.

## Non-Goals

- No changes to `create_base_agent`, `inject_agent`, or the Nurture pipeline.
- Not migrating existing domains onto the deep engine ("unify-later" is explicitly deferred).
- Not mapping the full agent roster to deepagents `subagents=` in the first cut (phase-2 hook only).

## Chosen Approach: Thin Idiomatic Wrapper (Approach A)

`create_base_deepagent` is the truest analog to "`create_base_agent` wraps `create_agent`." It
reuses dynagent's building blocks (`lm()`, checkpointer default, tool registry, `AgentMeta`
config) but delegates the agent loop to `create_deep_agent`, using deepagents **natively** for
planning / filesystem / sub-agents / summarization / prompt-caching.

Rejected alternatives:
- **B — Config-bridged:** also run `inject_agent` inside the deep stack for per-call prompt/tool
  hot-swap. Rejected: it fights deepagents' own prompt assembly and subagent model for little gain,
  since AMA is one main agent, not a role-swap pipeline. (We still retain `format_map` templating —
  see §4 — just not the dynamic per-call swap.)
- **C — Unify-later:** treat deepagents as the future single engine and migrate Nurture too.
  Rejected for now: largest scope, unnecessary to ship AMA.

## Verified Compatibility Facts (deepagents 0.6.7)

- `create_deep_agent(model: str | BaseChatModel, tools, *, system_prompt, middleware=(),
  subagents, skills, memory, permissions, backend, interrupt_on, response_format,
  state_schema: type[DeepAgentState] | None, context_schema, checkpointer, store, ...)`.
- Accepts a `BaseChatModel` instance → `lm()` works directly.
- Ships its own base middleware stack: `TodoListMiddleware` (planning), `FilesystemMiddleware`,
  `SubAgentMiddleware`, `SummarizationMiddleware`, `AnthropicPromptCachingMiddleware`, plus HITL via
  `interrupt_on`. **We must NOT re-add our `SummarizationMiddleware`.**
- `state_schema` must be a `DeepAgentState` subclass. `DeepAgentState(AgentState)` only overrides
  `messages` (with a delta reducer), so subclassing to add identity keys is trivial.
- Both factories return a `CompiledStateGraph`, so the existing `stream_agent_events(...)` streaming
  path works for the deep engine unchanged.

## Design

### 1. Module Layout

```
autobots-devtools-shared-lib/.../dynagent/agents/base_deepagent.py   # create_base_deepagent (new)
autobots-devtools-shared-lib/.../dynagent/models/deep_state.py       # DynaDeepAgent (new)
autobots-devtools-shared-lib/.../dynagent/agents/invocation_utils.py # + invoke_deepagent / ainvoke_deepagent
autobots-agents-mer/.../agent_configs/ama/                           # new AMA domain (deep-agents.yaml, prompts/)
```

The deep engine lives **beside** the react engine — parallel, not entangled.

### 2. `create_base_deepagent` — signature & behavior

```python
def create_base_deepagent(
    checkpointer: Any = None,
    initial_agent_name: str | None = None,
    state_schema: type[DeepAgentState] = DynaDeepAgent,
    prompt_values: dict[str, Any] | None = None,   # placeholder substitution values, e.g. {"language": "java"}
    subagents: Sequence[SubAgent] | None = None,   # optional phase-2 hook (roster → deepagents subagents)
) -> CompiledStateGraph:
    ...
```

Behavior:
1. Default `checkpointer` → `InMemorySaver()` (same as react engine).
2. Warm `AgentMeta.instance()`; resolve `initial_agent_name` via `get_default_agent()` when `None`.
3. Read the agent's raw prompt (`meta.prompt_map[name]`) and tool subset (`meta.tool_map[name]`).
4. Build the **static** `system_prompt` by applying `format_map` once (see §4).
5. `model = lm()`.
6. Return `create_deep_agent(model=model, tools=tools, system_prompt=system_prompt,
   state_schema=state_schema, checkpointer=checkpointer, name=initial_agent_name,
   subagents=subagents)`.

Key difference from the react engine: **no `inject_agent`, no `SummarizationMiddleware`** — deepagents
supplies planning, filesystem, subagents, summarization, and prompt caching itself.

### 3. State — `DynaDeepAgent`

```python
class DynaDeepAgent(DeepAgentState):
    agent_name: NotRequired[str]
    session_id: NotRequired[str]
    user_name: NotRequired[str]
```

Same routing/identity keys as `Dynagent`, on the deepagents base — so it keeps deepagents' `messages`
delta reducer and todo/file state channels. Tools that read `runtime.state["session_id"]` keep working.

### 4. Prompt templating (retained `format_map`)

Placeholder substitution is retained but moved from per-call middleware to **once at factory-build
time**, since the deep engine uses a static `system_prompt`:

```python
raw = meta.prompt_map[name]
input_directives = {k: json.dumps(v, indent=2, sort_keys=True)
                    for k, v in meta.input_schema_map.get(name, {}).items()}
values = {
    "input_schemas": input_directives,
    "output_schema": meta.output_schema_map.get(name, {}) or {},
    **(prompt_values or {}),
}
system_prompt = raw.format_map(defaultdict(str, values))
```

- Unknown placeholders resolve to empty string (`defaultdict(str)`), matching current react behavior;
  prompts remain written brace-safe.
- `prompt_values` carries domain constants such as `{"language": "java"}`.
- **Limitation (accepted):** because the prompt is resolved once, per-turn dynamic placeholder values
  are not supported on the deep engine. This is fine for AMA (single main agent, static domain config).

### 5. Config surface — AMA domain + `deep-agents.yaml`

- New `agent_configs/ama/` domain in **`autobots-agents-mer`**, selected via `DYNAGENT_CONFIG_ROOT_DIR`
  like every other domain.
- The deep engine's config file is named **`deep-agents.yaml`** (not `agents.yaml`) to make the engine
  obvious at a glance.
- Mechanism: add `agents_config_filename: str = "agents.yaml"` to `DynagentSettings`. `load_agents_config()`
  reads `Path(config_dir) / get_dynagent_settings().agents_config_filename` instead of the hardcoded
  name. The AMA domain's `.env` sets `agents_config_filename` (env: the corresponding settings var) to
  `deep-agents.yaml`. `AgentMeta` is untouched — it flows through `config_utils`.
- First cut: `deep-agents.yaml` has **one default `assistant` agent** (prompt + retrieval/action tool
  names). deepagents' built-in tools (`write_todos`, `ls`, `read_file`, `write_file`, `edit_file`, `glob`,
  `grep`, `task`, …) are
  additive and come for free. Additional roster entries may map to `subagents=` in phase-2.

### 6. Invocation & streaming

- **Streaming (primary for a chat UI):** AMA is a Chainlit chat and streams via the existing
  `stream_agent_events(agent, ...)` — works unchanged (it's a `CompiledStateGraph`).
- **Programmatic invoke:** add **separate** `invoke_deepagent` / `ainvoke_deepagent` functions that build
  via `create_base_deepagent` (instead of `create_base_agent`), reusing the same Langfuse/OTel wrapper.
  Separate functions keep the react path's blast radius at zero.

### 7. Public API

Export `create_base_deepagent` and `DynaDeepAgent` from `dynagent/__init__.py` alongside the existing
surface. `invoke_deepagent` / `ainvoke_deepagent` exported next to `invoke_agent` / `ainvoke_agent`.

## Phase 0 — Dependency / version resolution (BLOCKER)

Installed `deepagents 0.6.7` imports `langgraph.stream.run_stream`, which is absent in the installed
`langgraph 1.1.3` → deepagents fails to import today. **Nothing else can proceed until this is fixed.**

Phase 0 is a spike to find a compatible `(deepagents, langgraph, langchain)` pin set, update the
relevant `pyproject.toml` files, and verify the **whole workspace still imports and tests green**
(Nurture / react engine included). Exact pins are a plan-time investigation, not fixed here.

## Testing

- **Unit:** `create_base_deepagent` returns a compiled graph and wires model / tools / resolved prompt /
  state / checkpointer from AMA config (assert via a fake `AgentMeta` and a monkeypatched
  `create_deep_agent`). Assert `format_map` substitutes `prompt_values` and leaves unknown placeholders empty.
- **Integration (`sanity`):** a real AMA invoke answers a simple question and can call one registered tool
  plus `write_todos`.
- **Regression:** existing Nurture / react-engine tests remain unaffected.

## Risks & Open Items

- **Version resolution (Phase 0)** may force upgrades that ripple across the workspace — validate broadly.
- **Tool overlap:** deepagents ships virtual-filesystem tools; MER also has file-server tools
  (`mer_read_file_tool`, …). AMA should prefer deepagents' virtual FS; mixing both is out of scope for now.
- **Model provider:** deepagents prompt-caching is Anthropic/Bedrock-specific and no-ops elsewhere; `lm()`
  may return Gemini. Acceptable (caching simply doesn't apply); note in AMA domain setup.
```
