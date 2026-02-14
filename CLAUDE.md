# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a **Python multi-repo workspace** (`ws-jarvis`) containing two main repositories that work together:

- **autobots-devtools-shared-lib**: Core framework library providing the Dynagent multi-agent system
- **autobots-agents-jarvis**: Demo application showcasing Dynagent framework with a multi-agent AI assistant

All repos share a **single virtual environment** at `ws-jarvis/.venv/`.

## Architecture

### Dynagent Framework

The core concept is a **multi-agent system** where:

1. **Agents** are defined in YAML configs (`agent_configs/jarvis/agents.yaml` for Jarvis)
2. Each agent has:
   - A **prompt** (markdown file in `configs/jarvis/prompts/`)
   - Optional **output schema** (JSON file in `configs/jarvis/schemas/`)
   - A list of **tools** it can use
     - Some bootstrap tools are provided by Dynagent - others need to be code for my the use case. E.g.  `get_forecast` in `jarvis_tools.py`
   - Optional **batch processing** capability
3. **Agent handoff** (a Dynagent tool) allows agents to transfer control to specialized agents - this is useful to create agent mesh architecture.
4. **Tools** are LangChain tools registered in the application code
5. **State management** through Dynagent state objects passed to tools - the use case can extend the state object so they can use in their tools.
6. **Default Agent** one of the agents can be nominated to the "welcome" agent or "coordinator" agent especially useful for UI based use cases.

### Key Components

**autobots-devtools-shared-lib structure:**

```
src/autobots_devtools_shared_lib/
├── dynagent/              # Core multi-agent framework
│   ├── agents/           # Agent orchestration
│   ├── config/           # Config loading (YAML)
│   ├── llm/              # LLM integrations
│   ├── models/           # State and data models
│   ├── services/         # Core services (batch, etc.)
│   ├── tools/            # Framework-level tools (handoff, etc.)
│   └── ui/               # Chainlit UI integration
└── common/               # Shared utilities
    ├── observability/    # Langfuse integration
    ├── tools/            # Common tool helpers
    └── utils/            # General utilities
```

**autobots-agents-jarvis structure:**

```
src/autobots_agents_jarvis/
├── tools/                # Custom tools for Jarvis agents
├── services/             # Business logic (joke, weather, batch)
├── servers/              # Chainlit UI server (jarvis_ui.py)
├── configs/              # Pydantic settings
├── models/               # Data models
└── utils/                # Formatting helpers

agent_configs/jarvis/           # Agent configuration
├── agents.yaml           # Agent definitions
├── prompts/              # Agent system prompts (.md files)
└── schemas/              # Output JSON schemas
```

## Development Commands

### Workspace-level (run from `ws-jarvis/`)

```bash
# Setup
make setup              # Create shared venv, install pre-commit hooks
make install            # Install all dependencies from both repos
make install-dev        # Install with dev dependencies

# Quality checks (runs across all repos)
make format             # Format with ruff
make lint               # Lint with ruff
make type-check         # Type check with pyright
make test               # Run all tests
make all-checks         # Run format check, lint, type-check, test

# Maintenance
make clean              # Remove venv and cache files
make update-deps        # Update all dependencies
```

### Repo-specific (run from `autobots-agents-jarvis/` or `autobots-devtools-shared-lib/`)

```bash
# Testing
make test                                    # Run tests with coverage
make test-fast                              # Run tests without coverage (faster)
make test-one TEST=tests/unit/test_file.py::test_func  # Run specific test

# Code quality
make format             # Format code
make lint               # Lint with auto-fix
make check-format       # Check formatting without modifying
make type-check         # Run pyright

# Jarvis-specific
make chainlit-dev       # Run Chainlit UI server (port 1337)

# Docker (Jarvis only)
make docker-build       # Build Docker image
make docker-up          # Start with docker-compose
make docker-down        # Stop docker-compose services
make docker-logs-compose # View logs
```

## Working with Agents

### Adding a New Agent to Jarvis

1. **Define agent in `configs/jarvis/agents.yaml`:**

   ```yaml
   agents:
     my_agent:
       prompt: "my-new-agent"
       output_schema: "my-new-agent.json"  # optional
       batch_enabled: false
       tools:
         - "my_tool" # Use case 
         - "handoff" # Dynagent
         - "get_agent_list"  # Dynagent
   ```
2. **Create prompt** at `configs/jarvis/prompts/my-new-agent.md`
3. **Create output schema** (if needed) at `configs/jarvis/schemas/my-new-agent.json`
4. **Implement tools** in `src/autobots_agents_jarvis/tools/jarvis_tools.py`:

   ```python
   @tool
   def my_tool(runtime: ToolRuntime[None, Dynagent], param: str) -> str:
       """Tool description for the LLM."""
       session_id = runtime.state.get("session_id", "default")
       # Implementation
       return "result"
   ```
5. **Register tools** in the `register_jarvis_tools()` function
6. **Add tests** in `tests/unit/` or `tests/integration/`

### Tool Implementation Pattern

Tools receive a `ToolRuntime[None, Dynagent]` which provides:

- `runtime.state`: Access to Dynagent state (session_id, user context, etc.)
- State is shared across agent handoffs within a session

## Configuration

### Environment Variables

Create `.env` in `autobots-agents-jarvis/`:

```bash
# Required
GOOGLE_API_KEY=your-api-key                     # For Gemini LLM
ANTHROPIC_API_KEY=your-api-key                  # For Claude Sonnet LLM

# Optional
DYNAGENT_CONFIG_ROOT_DIR=configs/jarvis         # Agent config location
LANGFUSE_PUBLIC_KEY=...                         # Observability
LANGFUSE_SECRET_KEY=...
LANGFUSE_HOST=...
OAUTH_GITHUB_CLIENT_ID=...                      # GitHub OAuth
OAUTH_GITHUB_CLIENT_SECRET=...
```

### Python Environment

- **Python version**: 3.12 (preferred) or 3.13 (experimental)
- **Formatter**: Ruff (line length: 100)
- **Linter**: Ruff with strict rules
- **Type checker**: Pyright (basic mode)
- **Test framework**: pytest with coverage

## Local Development Path Dependency

When developing both repos together, `autobots-agents-jarvis` uses a **local path dependency** to `autobots-devtools-shared-lib`:

- Defined in `autobots-agents-jarvis/pyproject.toml`:
  ```toml
  [tool.poetry.dependencies]
  autobots-devtools-shared-lib = {path = "../autobots-devtools-shared-lib", develop = true}
  ```
- This allows immediate testing of shared-lib changes without publishing to PyPI
- For production, update to versioned PyPI dependency

## Running Jarvis

```bash
cd autobots-agents-jarvis

# Ensure .env is configured with GOOGLE_API_KEY
cp .env.example .env
# Edit .env

# Run the Chainlit UI
make chainlit-dev

# Or use the run script
./sbin/run_jarvis.sh

# Or directly
chainlit run src/autobots_agents_jarvis/servers/jarvis_ui.py --port 1337
```

Access at http://localhost:1337

## Testing

### Test Organization

- **Unit tests** (`tests/unit/`): Test individual functions/services
- **Integration tests** (`tests/integration/`): Test agent interactions
- Tests use pytest with async support (`asyncio_mode = "auto"`)

### Running Tests

```bash
# From workspace root (tests all repos)
make test

# From specific repo (e.g., jarvis)
cd autobots-agents-jarvis
make test-fast                              # Quick iteration
make test-one TEST=tests/unit/test_joke_service.py::test_get_joke  # Specific test
make test                                   # With coverage
```

## Pre-commit Hooks

Both repos have pre-commit hooks that run automatically:

- Ruff formatting and linting
- Pyright type checking
- Conventional commit message validation

```bash
# Install hooks (done automatically by make setup)
make install-hooks

# Run manually
make pre-commit
```

## Batch Processing

Jarvis supports **batch processing** for agents with `batch_enabled: true`:

```python
from autobots_agents_jarvis.services.jarvis_batch import jarvis_batch

prompts = ["Tell me a joke", "Another joke", "One more"]
result = jarvis_batch("joke_agent", prompts)

for record in result.results:
    if record.success:
        print(f"Record {record.index}: {record.output}")
```

Batch processing runs multiple prompts in parallel for the same agent.

## Important Notes

- **Shared venv**: All repos use `ws-jarvis/.venv/`, not individual venvs
- **Pyright config**: Set `venvPath = ".."` and `venv = ".venv"` to find the shared venv
- **Import paths**: Use package names (`autobots_devtools_shared_lib`, `autobots_agents_jarvis`)
- **Config location**: Jarvis expects configs at `configs/jarvis/` (set via `DYNAGENT_CONFIG_ROOT_DIR`)
- **Agent handoff**: Use the built-in `handoff` tool to transfer control between agents
- **Session state**: Tools can access session-scoped state via `runtime.state`
