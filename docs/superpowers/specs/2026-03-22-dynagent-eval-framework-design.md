# Dynagent Eval Framework — Design Spec

**Date:** 2026-03-22
**Status:** Approved
**Location:** `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/eval/`

## 1. Problem

There is no mechanism to evaluate multi-turn agent conversations for correctness or cost efficiency. Prompt changes, agent config updates, and code changes can silently regress agent behavior. Cost optimization decisions (e.g., splitting large file reads, removing redundant tool calls) have no data to support them.

## 2. Goals

- **Correctness evals** with hybrid assertions: deterministic (tool calls, JSON schema, string matching) + LLM-as-judge (free-text quality)
- **Cost analysis** with token attribution (Level 1) and utilization analysis (Level 2) to surface actionable prompt optimization recommendations
- **Two eval modes**: linear scripts for one-shot/pipeline agents, goal-based for conversational agents
- **Pluggable user simulator**: response bank (phase 1), LLM persona (phase 2)
- **Runs locally and in CI** via pytest plugin
- **Framework-level**: lives in `autobots-devtools-shared-lib`, available to all consumers (Jarvis, MER, future apps)
- **YAML for test cases, Python for custom assertions/judges**

## 3. Non-Goals

- Real-time production monitoring (this is offline eval, not live observability)
- Replacing existing unit/integration tests (evals complement, not replace)
- Building a custom eval runner (we use pytest)
- Building LLM-as-judge or trajectory matching from scratch (we use OpenEvals)
- Building cost/token tracking from scratch (we query Langfuse)

## 4. Key Dependencies

| Dependency | Purpose |
|---|---|
| `openevals` | LLM-as-judge evaluators + trajectory matching (strict, subset, superset, unordered, LLM) |
| `langfuse` (existing) | Token/cost data via trace queries, score posting for eval results |
| `jsonschema` | JSON schema validation for `response_matches_schema` assertion |
| `tiktoken` | Token estimation for cost attribution |
| `pydantic` (existing) | YAML → model validation |
| `pytest` (existing) | Test runner, plugin system, parametrize, fixtures |
| `pytest-xdist` (dev) | Parallel eval execution |

## 5. Eval Case Definition (YAML Schema)

### 5.1 Linear Mode (one-shot / pipeline agents)

```yaml
eval:
  name: "Model list extraction from Party LLD"
  agent: "model-list-extractor"
  mode: linear
  tags: ["nurture", "model", "smoke"]

  state:
    user_name: "test-user"
    repo_name: "fbp-core"
    jira_number: "MER-99999"

  turns:
    - user: |
        user_name: test-user, repo_name: fbp-core, jira_number: MER-99999
        Retrieve the model list for the current workspace.
      assertions:
        - tool_called: "mer_read_file_tool"
        - tool_called: "set_context_tool"
        - response_matches_schema: "schemas/model_list_schema.json"
        - contains: "Party"
        - llm_judge:
            criteria: "Response contains a valid list of domain models extracted from the LLD"
            threshold: 0.8
            on_judge_error: warn  # warn (default) or fail

  retry:
    count: 2
    only_for: ["llm_judge", "trajectory_quality"]

  cost:
    track: true
```

`cost.max_turns` is only applicable to goal-based mode (caps the conversation loop). In linear mode, the number of turns is determined by the `turns` list.

### 5.2 Goal-Based Mode (conversational agents)

```yaml
eval:
  name: "Background and scope generation"
  agent: "coordinator"
  mode: goal
  tags: ["designer", "background", "smoke"]

  state:
    user_name: "test-user"
    repo_name: "fbp-core"
    jira_number: "MER-99999"

  goal:
    initial_message: "Generate the Background and Scope section of the LLD"
    success_criteria:
      - tool_called: "mer_write_file_tool"
        args_contain: "background"
      - response_matches_schema: "schemas/background_and_scope.json"
      - llm_judge:
          criteria: "Agent produced a coherent background document covering feature scope"
          threshold: 0.8
    max_turns: 10

  user_simulator:
    type: response_bank
    responses:
      - when_asked: ["project description", "feature", "what are you building"]
        respond: "A payment processing feature that handles credit card transactions"
      - when_asked: ["scope", "boundaries", "what's included"]
        respond: "Only credit cards, no debit or ACH"
      - when_asked: ["confirm", "look correct", "proceed", "approve"]
        respond: "Yes, that looks correct. Please proceed."
      - when_asked: ["clarify", "more detail", "elaborate"]
        respond: "The feature should support Visa, Mastercard, and Amex only"
    default: "Yes, please continue."
    max_default_count: 3

  cost:
    track: true
```

## 6. Architecture

### 6.1 Module Structure

```
src/autobots_devtools_shared_lib/
├── dynagent/                    # Existing agent framework
├── common/                      # Existing shared utilities
└── eval/                        # NEW: Eval framework
    ├── __init__.py              # Public API exports
    ├── core/
    │   ├── __init__.py
    │   ├── loader.py            # YAML eval case parser → EvalCase models
    │   ├── runner.py            # Drives conversation (linear + goal-based)
    │   ├── result.py            # EvalResult, TurnResult dataclasses
    │   └── cost_tracker.py      # Langfuse trace query + utilization analysis
    │
    ├── assertions/
    │   ├── __init__.py
    │   ├── deterministic.py     # Wraps OpenEvals exact, json, trajectory.*
    │   ├── llm_judge.py         # Wraps OpenEvals create_llm_as_judge, trajectory.llm
    │   └── registry.py          # Maps YAML assertion names → evaluator functions
    │
    ├── simulators/
    │   ├── __init__.py
    │   ├── base.py              # UserSimulator protocol/ABC
    │   ├── response_bank.py     # Pattern-match simulator (phase 1)
    │   └── llm_persona.py       # LLM-driven simulator (phase 4)
    │
    ├── scoring/
    │   ├── __init__.py
    │   └── langfuse_scorer.py   # Posts eval scores to Langfuse, queries cost data
    │
    ├── pytest_plugin/
    │   ├── __init__.py
    │   ├── plugin.py            # pytest plugin (conftest auto-discovery)
    │   ├── fixtures.py          # dynagent_eval fixture, YAML parametrize
    │   └── reporting.py         # Cost report artifact generation
    │
    └── models/
        ├── __init__.py
        └── eval_case.py         # Pydantic models: EvalCase, Turn, Assertion, Goal, etc.
```

### 6.2 Consumer Usage (e.g., MER)

```
autobots-agents-mer/
├── evals/
│   ├── nurture/
│   │   ├── test_model_list_extractor.yaml
│   │   ├── test_behaviour_pipeline.yaml
│   │   └── schemas/
│   │       └── model_list_schema.json
│   └── designer/
│       ├── test_background_generation.yaml
│       └── response_banks/
│           └── background_responses.yaml
├── tests/
│   └── eval/
│       ├── conftest.py            # register_eval_tools fixture
│       └── test_evals.py          # Thin pytest wrapper
```

**test_evals.py** — minimal:

```python
from autobots_devtools_shared_lib.eval import load_eval_cases, run_eval

@pytest.mark.eval
@pytest.mark.eval_linear
@pytest.mark.parametrize("eval_case", load_eval_cases("evals/nurture"), ids=lambda c: c.name)
def test_nurture(eval_case, dynagent_eval):
    result = dynagent_eval(eval_case)
    assert result.passed, result.summary()

@pytest.mark.eval
@pytest.mark.eval_goal
@pytest.mark.parametrize("eval_case", load_eval_cases("evals/designer"), ids=lambda c: c.name)
def test_designer(eval_case, dynagent_eval):
    result = dynagent_eval(eval_case)
    assert result.passed, result.summary()
```

**conftest.py** — tool registration (mirrors production `server.py`):

```python
@pytest.fixture(autouse=True)
def register_eval_tools():
    _reset_usecase_tools()
    AgentMeta.reset()
    register_nurture_tools()
    register_validation_tools()
    yield
    _reset_usecase_tools()
    AgentMeta.reset()
```

## 7. Assertion System

### 7.1 Registry

Maps YAML assertion names to evaluator functions. Common signature:

```python
type EvalFn = Callable[[AgentOutput, dict[str, Any]], AssertionResult]

@dataclass
class AssertionResult:
    passed: bool
    name: str
    detail: str
    inconclusive: bool = False  # True when judge errors (not assertion failure)
```

Built-in registry:

| YAML assertion | Implementation | LLM needed? |
|---|---|---|
| `contains` | Built-in string check | No |
| `regex` | Built-in regex match | No |
| `exact_match` | OpenEvals `exact` | No |
| `json_match` | OpenEvals `json` | No |
| `response_matches_schema` | `jsonschema` validation | No |
| `tool_called` | OpenEvals `trajectory.subset` | No |
| `tool_sequence` | OpenEvals `trajectory.strict` | No |
| `no_extra_tools` | OpenEvals `trajectory.superset` | No |
| `tools_unordered` | OpenEvals `trajectory.unordered` | No |
| `llm_judge` | OpenEvals `create_llm_as_judge()` | Yes |
| `trajectory_quality` | OpenEvals `trajectory.llm` | Yes |

### 7.2 Custom Assertions

Consumers register domain-specific assertions:

```python
# In MER conftest.py
from autobots_devtools_shared_lib.eval.assertions.registry import register_assertion

def file_written_to_workspace(agent_output, config):
    """Custom MER assertion: verify file written via file server."""
    # ... check mer_write_file_tool was called with expected path
    return AssertionResult(...)

register_assertion("file_written", file_written_to_workspace)
```

Then usable in YAML:

```yaml
assertions:
  - file_written: "agentic-generator-meta/fbp-model-meta/MER-99999/model_list.json"
```

### 7.3 Registry Flow (tool_called example)

YAML:
```yaml
assertions:
  - tool_called: "mer_read_file_tool"
```

Resolution:
```python
def tool_called(agent_output: AgentOutput, config: dict) -> AssertionResult:
    tool_name = config  # "mer_read_file_tool"
    reference = [
        {"role": "assistant", "tool_calls": [{"function": {"name": tool_name, "arguments": "{}"}}]}
    ]
    evaluator = create_trajectory_subset_evaluator()
    result = evaluator(outputs=agent_output.messages, reference_outputs=reference)
    return AssertionResult(
        passed=result["score"],
        name=f"tool_called:{tool_name}",
        detail=result.get("comment", ""),
    )
```

### 7.4 Registry Flow (tool_sequence with args)

YAML:
```yaml
assertions:
  - tool_sequence:
      - tool: "set_context_tool"
        args_contain: { "agent_name": "model-list-extractor" }
      - tool: "mer_read_file_tool"
        args_contain: { "path": "docs/FBPAppMeta.md" }
      - tool: "mer_write_file_tool"
```

Resolution:
```python
def tool_sequence(agent_output: AgentOutput, config: list[dict]) -> AssertionResult:
    reference = []
    for step in config:
        tool_call = {"function": {"name": step["tool"], "arguments": "{}"}}
        if "args_contain" in step:
            tool_call["function"]["arguments"] = json.dumps(step["args_contain"])
        reference.append({"role": "assistant", "tool_calls": [tool_call]})

    evaluator = create_trajectory_match_evaluator(
        trajectory_match_mode="strict",
        tool_args_match_mode="subset" if any("args_contain" in s for s in config) else "ignore",
    )
    result = evaluator(outputs=agent_output.messages, reference_outputs=reference)
    return AssertionResult(passed=result["score"], name="tool_sequence", detail=result.get("comment", ""))
```

## 8. Execution Flow

### 8.1 Linear Mode

```
pytest discovers test_evals.py
  ├─ load_eval_cases("evals/nurture/") → list[EvalCase]
  ├─ parametrize creates one test per EvalCase
  └─ test_nurture(eval_case, dynagent_eval)
      └─ dynagent_eval fixture:
          ├─ registers tools (same as production)
          ├─ creates checkpointer, session_id, thread_id
          ├─ creates TraceMetadata(tags=["eval", *eval_case.tags])
          └─ runner.run_linear_eval(eval_case):
              ├─ Turn 1:
              │   ├─ invoke_agent(agent_name, input_state, config)
              │   │   └─ Langfuse trace created automatically
              │   ├─ registry resolves each assertion → evaluator function
              │   └─ TurnResult(turn=1, assertions=[...], passed=T/F)
              ├─ Turn 2: (reuses thread_id for continuity)
              ├─ After all turns:
              │   ├─ cost_tracker.query_langfuse(session_id) → CostReport
              │   └─ langfuse_scorer.post_scores(trace_id, results)
              └─ EvalResult(passed, turns, cost_report)
```

### 8.2 Goal-Based Mode

```
test_designer(eval_case, dynagent_eval)
  └─ runner.run_goal_eval(eval_case):
      ├─ simulator = ResponseBank(eval_case.user_simulator)
      ├─ message = eval_case.goal.initial_message
      ├─ met_criteria: set = {}
      └─ Loop (up to max_turns):
          ├─ invoke_agent(agent_name, {messages: [user: message]}, config)
          │   └─ same thread_id throughout (multi-turn accumulation)
          ├─ run_assertions(result, goal.success_criteria)
          │   ├─ track met_criteria cumulatively across turns
          │   ├─ all met? → break, eval passed
          │   └─ partial? → continue
          ├─ agent_last_message = extract from result
          └─ message = simulator.respond(agent_last_message)
              ├─ keyword match → canned response
              ├─ no match → default
              └─ 3x consecutive defaults → EvalStuckError, fail fast
```

## 9. Response Bank Simulator

### 9.1 Matching Logic

```python
class ResponseBank:
    rules: list[ResponseRule]     # keyword → response mappings
    default: str                  # fallback response
    max_default_count: int        # stuck detection threshold
    _consecutive_defaults: int

    def respond(self, agent_message: str) -> str:
        agent_text = agent_message.lower()
        for rule in self.rules:
            if any(keyword in agent_text for keyword in rule.keywords):
                self._consecutive_defaults = 0
                return rule.response
        self._consecutive_defaults += 1
        if self._consecutive_defaults >= self.max_default_count:
            raise EvalStuckError(...)
        return self.default
```

### 9.2 Pluggable Protocol

```python
class UserSimulator(Protocol):
    def respond(self, agent_message: str) -> str: ...
```

Both `ResponseBank` and future `LLMPersona` implement this protocol. The runner is agnostic to which simulator is driving.

## 10. Cost Analysis Engine

### 10.1 Level 1: Token Attribution (from Langfuse trace)

Walks Langfuse trace spans and categorizes token consumption:

```python
@dataclass
class ToolAttribution:
    tool_name: str
    tool_input: str
    result_tokens: int
    utilization: float | None         # Level 2
    used_content_summary: str | None  # Level 2
    recommendation: str | None        # Level 2

@dataclass
class TokenAttribution:
    system_prompt_tokens: int
    conversation_history_tokens: int
    tool_result_tokens: int
    tools: list[ToolAttribution]
    overhead_tokens: int

@dataclass
class TurnCost:
    turn: int
    model: str
    input_tokens: int
    output_tokens: int
    cost_usd: float
    latency_ms: int
    attribution: TokenAttribution

@dataclass
class CostReport:
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

Attribution source: Langfuse trace spans contain tool call inputs/outputs with content. Token estimation via `tiktoken`. System prompt size from agent config `.md` file. Conversation history = total input tokens minus prompt minus tool results.

### 10.2 Level 2: Utilization Analysis (LLM-as-judge)

For each tool result > 50 tokens, an LLM judge evaluates:

- **utilization** (0.0–1.0): fraction of tool result the agent actually used
- **used_content_summary**: what the agent extracted
- **recommendation**: actionable suggestion if utilization < 0.5

Judge prompt:
```
You are analyzing token efficiency in an AI agent's tool usage.

The agent called the tool: {tool_name}
The tool returned this content ({result_tokens} tokens):
<tool_result>{tool_result}</tool_result>

The agent then produced this output:
<agent_output>{agent_output}</agent_output>

Evaluate:
1. utilization (0.0–1.0): What fraction of the tool result was actually used?
2. used_content_summary: What specific parts did the agent use?
3. recommendation: If utilization < 0.5, suggest a concrete action to reduce wasted tokens.

Return JSON: {"utilization": float, "used_content_summary": "...", "recommendation": "..." or null}
```

Edge cases:
- Tool results > 4000 tokens: truncated (head + tail) for the judge
- Tool results > 10000 tokens: auto-flagged without judge call ("too large, almost certainly wasteful")
- Tool results < 50 tokens: skipped (not worth analyzing)

### 10.3 CLI Flags

```bash
# Default: Level 1 attribution
pytest tests/eval/ --eval-cost-report=reports/eval_cost.json

# Deep: Level 1 + Level 2 utilization analysis
pytest tests/eval/ --eval-cost-report=reports/eval_cost.json --eval-cost-deep
```

### 10.4 Cost Report Output Example

```json
{
  "eval_name": "Model list extraction from Party LLD",
  "agent": "model-list-extractor",
  "total_cost_usd": 0.035,
  "total_input_tokens": 3200,
  "llm_calls": 2,
  "turns": [
    {
      "turn": 1,
      "model": "gemini-2.0-flash",
      "input_tokens": 3200,
      "output_tokens": 600,
      "attribution": {
        "system_prompt_tokens": 800,
        "conversation_history_tokens": 150,
        "tool_result_tokens": 2100,
        "overhead_tokens": 150,
        "tools": [
          {
            "tool_name": "set_context_tool(agent_name=model-list-extractor)",
            "result_tokens": 50,
            "utilization": 1.0,
            "recommendation": null
          },
          {
            "tool_name": "mer_read_file_tool(docs/FeatureLLD/MER-74405---Party-Feature.md)",
            "result_tokens": 1900,
            "utilization": 0.10,
            "used_content_summary": "Agent extracted 3 model names (Party, Address, ContactInfo) from a 1900-token LLD document",
            "recommendation": "Split the LLD into sections by domain model. Read only the model-definitions section. Estimated saving: ~1700 tokens."
          }
        ]
      }
    }
  ],
  "lowest_utilization_tools": [
    {
      "tool_name": "mer_read_file_tool(docs/FeatureLLD/MER-74405---Party-Feature.md)",
      "utilization": 0.10,
      "result_tokens": 1900,
      "recommendation": "Split the LLD into sections by domain model..."
    }
  ],
  "recommendations": [
    "model-list-extractor: mer_read_file_tool on FeatureLLD has 10% utilization (1900 tokens). Split the LLD into sections by domain model. Estimated saving: ~1700 tokens per invocation."
  ]
}
```

### 10.5 Terminal Summary

```
=========================== eval cost summary ============================
Total eval cost: $0.42 across 12 evals

Low utilization detected (3 tools below 50%):

  model-list-extractor -> mer_read_file_tool(FeatureLLD/MER-74405)
    Utilization: 10% (1900 tokens read, ~200 used)
    -> Split the LLD into sections by domain model

  behaviour-list-extractor -> mer_read_file_tool(FeatureLLD/MER-74405)
    Utilization: 15% (1900 tokens read, ~285 used)
    -> Split the LLD into sections by behaviour

  scenario-md-generator -> mer_read_file_tool(existing_scenarios.md)
    Utilization: 5% (2400 tokens read, ~120 used)
    -> Pre-filter scenarios to only those related to the current feature

Full report: reports/eval_cost.json
=====================================================================
```

## 11. Pytest Plugin & CI

### 11.1 Plugin Registration

```toml
# autobots-devtools-shared-lib/pyproject.toml
[tool.poetry.plugins."pytest11"]
dynagent_eval = "autobots_devtools_shared_lib.eval.pytest_plugin.plugin"
```

Auto-discovered by any repo that depends on `autobots-devtools-shared-lib`.

### 11.2 CLI Options

```bash
pytest tests/eval/ --eval-dir=evals              # Root dir for YAML files (default: evals)
pytest tests/eval/ --eval-tags=smoke              # Filter by tags
pytest tests/eval/ --eval-cost-report=report.json # Write cost report
pytest tests/eval/ --eval-cost-deep               # Enable Level 2 utilization analysis
pytest tests/eval/ --eval-no-langfuse-score       # Skip Langfuse score posting
pytest tests/eval/ -n 4                           # Parallel execution (pytest-xdist)
```

### 11.3 Makefile Targets

```makefile
eval:                          ## Run all evals
	pytest tests/eval/ -m eval --eval-cost-report=reports/eval_cost.json

eval-smoke:                    ## Run smoke evals only
	pytest tests/eval/ -m eval --eval-tags=smoke

eval-fast:                     ## Run evals without Langfuse scoring
	pytest tests/eval/ -m eval --eval-no-langfuse-score

eval-deep:                     ## Run evals with deep cost analysis
	pytest tests/eval/ -m eval --eval-cost-report=reports/eval_cost.json --eval-cost-deep
```

### 11.4 CI Integration (GitHub Actions)

```yaml
name: Agent Evals
on:
  pull_request:
    paths:
      - "agent_configs/**"
      - "evals/**"
      - "src/**"

jobs:
  eval:
    runs-on: ubuntu-latest
    env:
      GOOGLE_API_KEY: ${{ secrets.GOOGLE_API_KEY }}
      LANGFUSE_PUBLIC_KEY: ${{ secrets.LANGFUSE_PUBLIC_KEY }}
      LANGFUSE_SECRET_KEY: ${{ secrets.LANGFUSE_SECRET_KEY }}
      LANGFUSE_HOST: ${{ secrets.LANGFUSE_HOST }}

    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.12"
      - name: Install dependencies
        run: make install-dev
      - name: Run smoke evals
        run: make eval-smoke
      - name: Run full evals
        if: github.event.pull_request.labels.*.name == 'run-full-evals'
        run: make eval-deep
      - name: Upload cost report
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: eval-cost-report
          path: reports/eval_cost.json
```

Strategy:
- **Every PR**: smoke-tagged evals only (fast, cheap, catches regressions)
- **On-demand** (label `run-full-evals`): full eval suite with cost report
- **Triggered by**: agent config, eval case, or source code changes only

## 12. Data Models

```python
@dataclass
class AgentOutput:
    messages: list[BaseMessage]
    structured_response: dict | None
    agent_name: str
    raw_state: dict[str, Any]

@dataclass
class AssertionResult:
    passed: bool
    name: str
    detail: str
    inconclusive: bool = False

@dataclass
class TurnResult:
    turn: int
    assertions: list[AssertionResult]
    passed: bool
    agent_message: str | None
    error: str | None = None

@dataclass
class EvalResult:
    name: str
    passed: bool
    turns: list[TurnResult]
    cost_report: CostReport | None
    termination_reason: str | None = None  # goal mode: all_criteria_met | max_turns_exceeded | stuck
    error: str | None = None

    def summary(self) -> str:
        """Human-readable summary for pytest failure output."""
```

## 13. Error Handling

| Scenario | Behavior |
|---|---|
| Agent exception mid-conversation | Eval fails, partial cost report captured, `termination_reason="agent_error"` |
| Langfuse unavailable | Evals run, cost report is `None`, warning logged |
| LLM judge error (rate limit, timeout) | Assertion marked `inconclusive`, configurable `on_judge_error: warn\|fail` |
| Agent answers immediately (goal mode) | Eval passes on turn 1, simulator never called |
| Success criteria met across multiple turns | Cumulative tracking via `met_criteria` set |
| Missing tool registration | Fail fast before agent runs, lists missing tools |
| Invalid YAML eval case | Pydantic validation at load time, file path in error |
| Flaky LLM assertions | Configurable retry (re-runs judge, not agent): `retry.count` + `retry.only_for` |
| Tool result too large for utilization judge | > 4000 tokens: truncate (head+tail). > 10000 tokens: auto-flag without judge |
| Unknown agent in eval case | Fail fast, list available agents |
| Response bank stuck (goal mode) | `max_default_count` consecutive defaults triggers `EvalStuckError` |

## 14. Production Code Reuse

| Component | Production | Eval |
|---|---|---|
| `invoke_agent()` / `ainvoke_agent()` | Same | Same (no mocking) |
| `register_usecase_tools()` | Called in `server.py` | Called in `dynagent_eval` fixture |
| `TraceMetadata` | Same | Same (with `tags=["eval"]` added) |
| Langfuse `CallbackHandler` | Same | Same (traces are real) |
| Checkpointer (`InMemorySaver`) | Same | Same |
| Agent configs (YAML) | Same | Same (evals run against real configs) |

The eval framework adds no mocks or shims. Agents are invoked identically to production.

## 15. Phased Delivery

### Phase 1: Foundation

Linear evals + deterministic assertions + cost Level 1.

Scope:
- `eval/models/`, `eval/core/` (loader, runner linear mode, result, cost_tracker Level 1)
- `eval/assertions/` (deterministic + registry)
- `eval/scoring/` (langfuse_scorer)
- `eval/pytest_plugin/` (plugin, fixtures, reporting)
- 2-3 nurture eval cases in MER as proof
- `make eval` and `make eval-smoke` targets
- CI workflow (smoke evals on PR)

### Phase 2: LLM-as-Judge + Cost Level 2

Scope:
- `eval/assertions/llm_judge.py`
- `eval/core/cost_tracker.py` Level 2 utilization analysis
- `--eval-cost-deep` flag
- Retry config for flaky tolerance
- Updated nurture evals with LLM judge assertions

### Phase 3: Goal-Based Evals + Response Bank

Scope:
- `eval/core/runner.py` goal-based mode
- `eval/simulators/base.py` + `response_bank.py`
- `eval/models/eval_case.py` goal + simulator config
- 2-3 designer eval cases in MER as proof
- `eval_goal` pytest marker

### Phase 4: LLM Persona Simulator

Scope:
- `eval/simulators/llm_persona.py`
- YAML config for persona definition
- Designer evals upgraded from response bank to LLM persona

### Phase Dependencies

```
Phase 1 (Foundation)
   |
   |---> Phase 2 (LLM Judge + Cost Deep)
   |
   |---> Phase 3 (Goal-based + Response Bank)
              |
              |---> Phase 4 (LLM Persona)
```

Phases 2 and 3 are independent — can be built in parallel or in either order. Phase 4 depends on Phase 3.
