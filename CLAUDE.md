# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Python monorepo workspace with 4 repos sharing a **single venv** at `ws-autobots/.venv/`:

| Repo | Purpose | Version |
|------|---------|---------|
| `autobots-devtools-shared-lib` | Dynagent multi-agent framework (core library) | 0.7.0 |
| `autobots-agents-jarvis` | Demo app: Concierge, Customer Support, Sales domains | 0.1.0 |
| `autobots-agents-mer` | SDLC automation: Designer, Nurture domains | 0.2.1 |
| `autobots-agents-pay` | Knowledge Base Extractor (KBE) | 0.1.0 |

Domain-specific guidance lives in `autobots-agents-mer/CLAUDE.md` and `autobots-agents-pay/CLAUDE.md`.

## Design Philosophy

@dyna-vault/README.md

- **Non-intrusive**: Solutions must not change existing developer workflows
- **Design First**: All significant work starts with a Low-Level Design (LLD) document
- Design templates: `dyna-vault/designs/templates/`

## Commands

### Workspace-level (from `ws-autobots/`)

```bash
make setup          # Create shared venv + install pre-commit hooks
make install-dev    # Install all repos with dev deps
make test           # Run all tests
make lint           # ruff check all repos
make format         # ruff format all repos
make type-check     # pyright all repos
make all-checks     # format-check + lint + type-check + test
```

### Per-repo (from inside any repo)

```bash
make test                                    # pytest with coverage
make test-fast                               # pytest without coverage, stop on first failure
make test-one TEST=tests/unit/test_foo.py::test_bar  # single test
make format                                  # ruff format
make lint                                    # ruff check --fix
make type-check                              # pyright
make check-format                            # ruff format --check + ruff check
```

## Gotchas

- **Shared venv**: All repos use `../.venv` (workspace root), not individual venvs. Activate with `source .venv/bin/activate` from workspace root.
- **Pre-commit hooks**: Commit from **inside each repo** (not workspace root). Hooks run ruff + pyright + pytest + poetry check.
- **Pyright config**: Must use `venvPath = ".."` and `venv = ".venv"` for monorepo mode. Some repos have this commented out — check if pyright fails.
- **Local path dependencies**: Jarvis and MER have `develop = true` path dep on shared-lib in pyproject.toml. Pay has it commented out.
- **DYNAGENT_CONFIG_ROOT_DIR**: Must be set in `.env` per domain before `create_base_agent()`. Different per domain: `agent_configs/concierge`, `agent_configs/nurture`, `agent_configs/demo`, etc.
- **Docker monorepo build**: Use `Dockerfile.monorepo` (not `Dockerfile`) to resolve local path deps.

## Code Style

- **Formatter/Linter**: Ruff, line-length 100, double quotes
- **Type checker**: Pyright (basic mode)
- **Python**: 3.12+
- **Ruff rules**: E, W, F, I, B, C4, UP, ARG, SIM, S, TCH, PTH, RET, TRY, PERF, RUF (ignore S101, E501, TRY003)

## Dynagent Agent Pattern

Agents are configured in YAML with prompts and optional output schemas:

```
agent_configs/<domain>/
├── agents.yaml          # Agent definitions
├── prompts/*.md         # Agent prompts
└── schemas/*.json       # Output schemas (optional)
```

Each agent in `agents.yaml`:
```yaml
agents:
  my_agent:
    prompt: "my-agent"              # → prompts/my-agent.md
    output_schema: "my-agent.json"  # → schemas/my-agent.json (optional)
    batch_enabled: false
    tools: ["my_tool", "handoff", "get_agent_list"]
```

### Tool Pattern

Tools use `ToolRuntime[None, Dynagent]` for state access:

```python
@tool
def my_tool(runtime: ToolRuntime[None, Dynagent], param: str) -> str:
    """Tool description for the LLM."""
    session_id = runtime.state.get("session_id", "default")
    return "result"
```

Register tools once at startup via `register_usecase_tools(tools)` before `create_base_agent()`.

### Domain Code Pattern

Each domain follows: `domains/{name}/server.py`, `tools.py`, `services.py`. Shared code in `common/`.

## Key Imports

```python
from autobots_devtools_shared_lib.dynagent import (
    create_base_agent, invoke_agent, ainvoke_agent,
    batch_invoker, register_usecase_tools, get_batch_enabled_agents,
)
from autobots_devtools_shared_lib.dynagent.ui import stream_agent_events
```

## Testing

- pytest with `asyncio_mode = "auto"` — async tests work out of the box
- Markers: `unit`, `integration`, `slow`, `sanity`
- Coverage reports to `htmlcov/`
