# Nurture Eval CI Gate — Design Spec

**Date:** 2026-03-26
**Status:** Draft
**Relation:** Builds on [Dynagent Eval Framework Design](2026-03-22-dynagent-eval-framework-design.md) — cherry-picks YAML schema, deterministic assertions, cost Level 1, pytest plugin, linear runner. Redesigns CI integration. Adds golden match assertion and cost baseline comparison.

## 1. Problem

The Nurture App (autobots-agents-mer) is in production with real users. Prompt changes, schema updates, and tool code changes can silently regress agent behavior — producing incorrect model lists, malformed OAS specs, or broken Gherkin files. There is no automated gate to catch these regressions before they reach users.

Additionally, there is no visibility into cost/latency impact of changes. A prompt tweak that doubles token usage goes unnoticed until the bill arrives.

## 2. Goals

- **CI gate on prompt changes**: Every PR that touches `agent_configs/nurture/` automatically runs targeted evals and blocks merge on failure
- **Golden output validation**: Compare agent outputs against known-good reference outputs with clear diff reporting
- **Cost/latency regression visibility**: Track token usage, cost, and latency against committed baselines, surface deltas in PR comments
- **Targeted execution**: Only run evals for agents whose prompts/schemas changed, with manual full-suite override
- **Strict checks for all agents**: Both extractors (JSON output) and generators (file output) get strict validation
- **Framework-level**: Eval framework lives in `autobots-devtools-shared-lib`, available to all consumer repos

## 3. Non-Goals

- Goal-based / multi-turn conversational evals (all Nurture agents are single-turn pipeline agents)
- User simulators (response bank, LLM persona)
- LLM-as-judge assertions (Phase 2)
- Cost Level 2 utilization analysis (Phase 2)
- Cost regression gates that block PRs (future — start with report-only)
- Real-time production monitoring (this is offline eval, not live observability)
- Replacing existing unit/integration tests

## 4. Key Dependencies

| Dependency | Purpose | Status |
|---|---|---|
| `langfuse` | Token/cost data via trace queries, score posting | Existing |
| `jsonschema` | JSON schema validation for `response_matches_schema` | Existing |
| `pydantic` | YAML → model validation | Existing |
| `pytest` | Test runner, plugin system, parametrize, fixtures | Existing |
| `tiktoken` | Token estimation for cost attribution | New |
| `pytest-xdist` (dev) | Parallel eval execution | New |

## 5. Golden Match Assertion

The core mechanism for detecting breaking changes. Each eval case points to a golden reference file — a known-good output captured from a verified run.

### 5.1 Comparison Modes

| Mode | Behavior | Best for |
|---|---|---|
| `exact` | JSON deep-equal after key-sorting. Fails on any difference. | Extractors with deterministic schemas (model-list, behaviour-list, scenario-list) |
| `structural` | Validates same keys present, same array lengths, same types. String values are not compared (only presence checked). Supports `ignore_fields` to skip volatile fields entirely. | Generators where wording may vary but structure must match (OAS, Java, Gherkin) |

### 5.2 YAML Usage

**Extractor (exact mode):**

```yaml
assertions:
  - golden_match:
      reference: "fixtures/golden_output.json"
      mode: "exact"
```

**Generator (structural mode):**

```yaml
assertions:
  - golden_match:
      reference: "fixtures/golden_output.json"
      mode: "structural"
      ignore_fields: ["description", "x-fbp-comments"]
```

### 5.3 Diff Output on Failure

```
FAILED: golden_match
  Reference: fixtures/model-list-extractor/party-lld/golden_output.json

  Missing from actual:
    - models[2]: {"name": "ContactInfo", "schema_type": "value_object"}

  Unexpected in actual:
    - models[2]: {"name": "Contact", "schema_type": "entity"}

  Changed:
    - models[0].description: "Main party entity" → "Primary party model"
```

### 5.4 Updating Golden Outputs

When a prompt change is intentional and produces better output:

```bash
pytest tests/eval/nurture/ -k "party_lld" --update-golden
```

Overwrites golden output and cost baseline. The diff shows up in the PR for review.

## 6. Cost Tracking & Baseline Comparison

### 6.1 Data Capture (Level 1)

After each eval run, the cost tracker queries Langfuse using the eval's `session_id` and extracts:

```python
@dataclass
class EvalCostSnapshot:
    eval_name: str
    agent: str
    total_input_tokens: int
    total_output_tokens: int
    total_cost_usd: float
    total_latency_ms: int
    llm_calls: int
    per_tool_tokens: dict[str, int]  # tool_name → result_tokens
    timestamp: str                    # ISO 8601
```

### 6.2 Baseline Files

Each eval case has a corresponding baseline JSON, committed alongside the golden output:

```json
{
  "eval_name": "Model list extraction from Party LLD",
  "agent": "model-list-extractor",
  "total_input_tokens": 3200,
  "total_output_tokens": 600,
  "total_cost_usd": 0.008,
  "total_latency_ms": 4100,
  "llm_calls": 2,
  "per_tool_tokens": {
    "set_context_tool": 50,
    "mer_read_file_tool": 1900
  }
}
```

### 6.3 Comparison Logic

```python
@dataclass
class CostDelta:
    metric: str           # "input_tokens", "cost_usd", "latency_ms", etc.
    baseline: float
    actual: float
    delta_pct: float      # +12.5%, -3.2%, etc.
    status: str           # "ok", "warning"
```

Configurable thresholds per eval case:

```yaml
cost:
  track: true
  baseline: "fixtures/cost_baseline.json"
  thresholds:
    input_tokens: 20      # % increase triggers "warning"
    cost_usd: 25          # % increase triggers "warning"
    latency_ms: 30        # % increase triggers "warning"
```

### 6.4 Three Tiers

| Tier | Behavior | When |
|---|---|---|
| **Report** | Deltas shown in PR comment. No blocking. | Phase 1 (now) |
| **Warning** | PR comment flags metrics exceeding thresholds with warning icon | Phase 1 (now) |
| **Gate** | Configurable hard fail if thresholds exceeded | Future |

### 6.5 Updating Baselines

```bash
# Update cost baselines only (golden outputs unchanged)
pytest tests/eval/nurture/ -k "party_lld" --update-baseline

# Update both golden outputs + cost baselines
pytest tests/eval/nurture/ -k "party_lld" --update-golden
```

### 6.6 Terminal Summary

```
======================== eval cost comparison ========================
model-list-extractor (Party LLD):
  Input tokens:  3200 → 3580  (+11.9%)
  Output tokens:  600 → 610   (+1.7%)
  Cost:         $0.008 → $0.009 (+12.5%)  ⚠ warning (threshold: 25%)
  Latency:      4100ms → 3900ms (-4.9%)
  LLM calls:    2 → 2

behaviour-list-extractor (Party LLD):
  Input tokens:  4100 → 4050  (-1.2%)
  Cost:         $0.012 → $0.012 (+0.0%)
  Latency:      5200ms → 5100ms (-1.9%)
=====================================================================
```

## 7. Targeted CI Workflow

### 7.1 Resolution Chain

```
Changed file: agent_configs/nurture/prompts/model-list-extractor.md
         ↓ (agents.yaml lookup)
Agent:   model-list-extractor
         ↓ (scan eval YAMLs for agent: "model-list-extractor")
Evals:   test_model_list_extractor.yaml, test_model_list_party.yaml, ...
```

### 7.2 Trigger Modes

| Trigger | What runs | How |
|---|---|---|
| **PR push** (auto) | Only evals for changed agents | CI script resolves changed files → agents → eval YAMLs |
| **`/eval-full` comment** | All Nurture evals | Reviewer posts comment on PR, `issue_comment` trigger matches |
| **`workflow_dispatch`** | All Nurture evals | Manual trigger from Actions tab |

### 7.3 Resolution Rules

| Changed file pattern | Eval scope |
|---|---|
| `agent_configs/nurture/prompts/<agent>.md` | Evals for that agent only |
| `agent_configs/nurture/agents.yaml` | All evals (structural change) |
| `agent_configs/nurture/schemas/<schema>.json` | Evals for agents using that schema |
| `src/autobots_agents_mer/domains/nurture/**` | All evals (tool/service logic change) |
| `tests/eval/nurture/<agent>/**` | That specific eval (fixture update) |

### 7.4 Resolver Script

A Python script at `.github/scripts/resolve_evals.py` called by CI:

```bash
python .github/scripts/resolve_evals.py \
  --changed-files "agent_configs/nurture/prompts/model-list-extractor.md" \
  --agents-yaml "agent_configs/nurture/agents.yaml" \
  --eval-dir "tests/eval/nurture/"

# Output: tests/eval/nurture/model-list-extractor/party-lld.yaml
```

### 7.5 GitHub Actions Workflow

```yaml
name: Nurture Eval Gate
on:
  pull_request:
    paths:
      - "agent_configs/nurture/**"
      - "src/autobots_agents_mer/domains/nurture/**"
      - "tests/eval/nurture/**"

  workflow_dispatch:
    inputs:
      full_suite:
        description: "Run full eval suite"
        type: boolean
        default: true

  issue_comment:
    types: [created]
```

### 7.6 PR Comment Reporter

**On success:**

```markdown
## Eval Results — Nurture

| Agent | Eval | Result | Tokens (Δ) | Cost (Δ) | Latency (Δ) |
|---|---|---|---|---|---|
| model-list-extractor | Party LLD | ✅ Pass | 3580 (+11.9%) | $0.009 (+12.5%) | 3.9s (-4.9%) |
| model-list-extractor | Order LLD | ✅ Pass | 2900 (-2.1%) | $0.007 (-3.0%) | 3.5s (-1.2%) |

**Triggered by:** prompt change in `model-list-extractor.md`
**Scope:** 2 targeted evals (comment `/eval-full` to run all 15)
```

**On failure:**

```markdown
## Eval Results — Nurture

| Agent | Eval | Result | Failure |
|---|---|---|---|
| model-list-extractor | Party LLD | ❌ Fail | golden_match: Missing models[2] "ContactInfo" |

<details>
<summary>Full diff</summary>

Missing from actual:
  - models[2]: {"name": "ContactInfo", "schema_type": "value_object"}

Unexpected in actual:
  - models[2]: {"name": "Contact", "schema_type": "entity"}

</details>
```

## 8. Eval Fixture Structure

### 8.1 Directory Layout

```
autobots-agents-mer/
├── tests/
│   └── eval/
│       ├── conftest.py                    # Tool registration, dynagent_eval fixture
│       ├── test_nurture_evals.py          # Thin pytest wrapper (parametrized)
│       └── nurture/
│           ├── model-list-extractor/
│           │   ├── party-lld.yaml
│           │   └── fixtures/
│           │       ├── golden_input.md
│           │       ├── golden_output.json
│           │       └── cost_baseline.json
│           ├── model-oas-generator/
│           │   ├── party-model.yaml
│           │   └── fixtures/ ...
│           ├── behaviour-list-extractor/
│           │   ├── party-lld.yaml
│           │   └── fixtures/ ...
│           ├── behaviour-md-generator/
│           │   ├── create-party.yaml
│           │   └── fixtures/ ...
│           ├── behaviour-java/
│           │   ├── create-party.yaml
│           │   └── fixtures/ ...
│           ├── scenario-list-extractor/
│           │   ├── party-lld.yaml
│           │   └── fixtures/ ...
│           ├── scenario-md-generator/
│           │   ├── create-party-positive.yaml
│           │   └── fixtures/ ...
│           └── scenario-feature-generator/
│               ├── create-party-positive.yaml
│               └── fixtures/ ...
```

### 8.2 Eval Case YAML — Extractor Example

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

  setup:
    workspace_files:
      - src: "fixtures/golden_input.md"
        dest: "docs/FeatureLLD/MER-99999---Party-Feature.md"

  turns:
    - user: |
        user_name: test-user, repo_name: fbp-core, jira_number: MER-99999
        Retrieve the model list for the current workspace.
      assertions:
        - tool_called: "mer_read_file_tool"
        - tool_called: "set_context_tool"
        - response_matches_schema: "schemas/model-list.json"
        - golden_match:
            reference: "fixtures/golden_output.json"
            mode: "exact"

  cost:
    track: true
    baseline: "fixtures/cost_baseline.json"
    thresholds:
      input_tokens: 20
      cost_usd: 25
      latency_ms: 30
```

### 8.3 Eval Case YAML — Generator Example

```yaml
eval:
  name: "OAS generation for Party model"
  agent: "model-oas-generator"
  mode: linear
  tags: ["nurture", "model-oas", "smoke"]

  state:
    user_name: "test-user"
    repo_name: "fbp-core"
    jira_number: "MER-99999"

  setup:
    workspace_files:
      - src: "fixtures/golden_input.md"
        dest: "docs/FeatureLLD/MER-99999---Party-Feature.md"
      - src: "fixtures/model_list.json"
        dest: "agentic-generator-meta/fbp-model-meta/MER-99999/model_list.json"

  turns:
    - user: |
        Generate OAS for the Party model.
      assertions:
        - tool_called: "mer_read_file_tool"
        - tool_called: "mer_write_file_tool"
        - golden_match:
            reference: "fixtures/golden_output.json"
            mode: "structural"
            ignore_fields: ["description", "x-fbp-comments"]

  cost:
    track: true
    baseline: "fixtures/cost_baseline.json"
```

### 8.4 Setup Block — Workspace File Staging

The `setup.workspace_files` block is a new addition not in the original spec. Nurture agents expect files to exist in the workspace (LLD documents, meta JSONs). The eval framework stages these files before the agent runs and tears them down after.

Handled by the `dynagent_eval` fixture:
1. Create temp workspace directory
2. Copy each `src` fixture to `dest` path within workspace
3. Set context store with workspace path
4. Run agent
5. Tear down workspace

### 8.5 Test File

```python
# tests/eval/test_nurture_evals.py
import pytest
from autobots_devtools_shared_lib.eval import load_eval_cases

@pytest.mark.eval
@pytest.mark.eval_linear
@pytest.mark.parametrize(
    "eval_case",
    load_eval_cases("tests/eval/nurture"),
    ids=lambda c: c.name,
)
def test_nurture(eval_case, dynagent_eval):
    result = dynagent_eval(eval_case)
    assert result.passed, result.summary()
```

### 8.6 conftest.py

```python
# tests/eval/conftest.py
import pytest
from autobots_devtools_shared_lib.dynagent import AgentMeta, register_usecase_tools
from autobots_agents_mer.domains.nurture.tools.nurture_tools import get_nurture_tools

@pytest.fixture(autouse=True)
def register_eval_tools():
    AgentMeta.reset()
    register_usecase_tools(get_nurture_tools())
    yield
    AgentMeta.reset()
```

## 9. Framework Module Structure

### 9.1 Layout in shared-lib

```
src/autobots_devtools_shared_lib/eval/
├── __init__.py                  # Public API exports
├── models/
│   ├── __init__.py
│   ├── eval_case.py             # EvalCase, Turn, Assertion, SetupConfig, CostConfig
│   └── result.py                # EvalResult, TurnResult, AssertionResult, CostDelta
│
├── core/
│   ├── __init__.py
│   ├── loader.py                # YAML discovery + Pydantic validation
│   ├── runner.py                # run_linear_eval()
│   ├── workspace.py             # Stage/teardown workspace_files
│   └── cost_tracker.py          # Langfuse trace query + baseline comparison
│
├── assertions/
│   ├── __init__.py
│   ├── registry.py              # YAML name → evaluator function mapping
│   ├── deterministic.py         # contains, regex, exact_match, json_match, schema_match,
│   │                            # tool_called, tool_sequence, no_extra_tools, tools_unordered
│   └── golden.py                # golden_match: exact + structural modes, diff reporting
│
├── scoring/
│   ├── __init__.py
│   └── langfuse_scorer.py       # Post scores to Langfuse, query cost data
│
└── pytest_plugin/
    ├── __init__.py
    ├── plugin.py                # pytest hook registration, CLI options
    ├── fixtures.py              # dynagent_eval fixture, workspace setup/teardown
    └── reporting.py             # Terminal cost summary, JSON report generation
```

### 9.2 Public API

```python
# eval/__init__.py
from autobots_devtools_shared_lib.eval.core.loader import load_eval_cases
from autobots_devtools_shared_lib.eval.core.runner import run_linear_eval
from autobots_devtools_shared_lib.eval.models.eval_case import EvalCase, Turn, Assertion
from autobots_devtools_shared_lib.eval.models.result import (
    EvalResult, TurnResult, AssertionResult, CostDelta, EvalCostSnapshot,
)
from autobots_devtools_shared_lib.eval.assertions.registry import register_assertion
```

### 9.3 Boundary: Framework vs Consumer

| Concern | Location | Why |
|---|---|---|
| Eval framework (models, runner, assertions, plugin) | `shared-lib/eval/` | Reusable across all consumer repos |
| Eval YAML cases + fixtures | `mer/tests/eval/nurture/` | Co-located with prompts they test |
| Custom assertions (if any) | `mer/tests/eval/conftest.py` | Domain-specific |
| CI workflow + resolver script | `mer/.github/` | Repo-specific trigger rules |
| Makefile targets | `mer/Makefile` | Repo-specific convenience |

### 9.4 New Dependencies

```toml
# shared-lib pyproject.toml
[tool.poetry.dependencies]
tiktoken = ">=0.7.0"

[tool.poetry.group.dev.dependencies]
pytest-xdist = ">=3.0.0"

[tool.poetry.plugins."pytest11"]
dynagent_eval = "autobots_devtools_shared_lib.eval.pytest_plugin.plugin"
```

### 9.5 Key Design Decisions

1. **No OpenEvals dependency in Phase 1** — `tool_called` and `tool_sequence` are implemented as simple list-membership checks on message history. OpenEvals comes in Phase 2 with LLM-as-judge.
2. **`golden.py` is separate from `deterministic.py`** — golden match has its own diff engine, update mechanism, and failure reporting. First-class concept, not just another assertion.
3. **`workspace.py` handles file staging** — framework-level because any consumer's agents may need pre-staged files.
4. **pytest plugin auto-discovery** — any repo that depends on shared-lib gets the plugin automatically.

## 10. Makefile Targets & CLI

### 10.1 Makefile (autobots-agents-mer)

```makefile
eval:                              ## Run all nurture evals with cost report
	pytest tests/eval/ -m eval --eval-cost-report=reports/eval_cost.json -v

eval-smoke:                        ## Run smoke-tagged evals only
	pytest tests/eval/ -m eval --eval-tags=smoke -v

eval-agent AGENT=:                 ## Run evals for a specific agent
	pytest tests/eval/ -m eval --eval-agent=$(AGENT) -v

update-golden:                     ## Re-capture golden outputs + baselines
	pytest tests/eval/ -m eval --update-golden -v

update-baseline:                   ## Re-capture cost baselines only
	pytest tests/eval/ -m eval --update-baseline -v
```

### 10.2 pytest CLI Options

| Flag | Purpose |
|---|---|
| `--eval-tags=smoke,model` | Filter eval cases by tags (comma-separated, OR logic) |
| `--eval-agent=model-list-extractor` | Filter eval cases by agent name |
| `--eval-cost-report=path.json` | Write cost report JSON to file |
| `--update-golden` | Overwrite golden outputs + cost baselines with actual results (superset of `--update-baseline`) |
| `--update-baseline` | Overwrite cost baselines only (golden outputs unchanged) |
| `--eval-no-langfuse-score` | Skip posting scores to Langfuse |

## 11. Data Models

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

@dataclass
class TurnResult:
    turn: int
    assertions: list[AssertionResult]
    passed: bool
    agent_message: str | None
    error: str | None = None

@dataclass
class CostDelta:
    metric: str
    baseline: float
    actual: float
    delta_pct: float
    status: str  # "ok", "warning"

@dataclass
class EvalCostSnapshot:
    eval_name: str
    agent: str
    total_input_tokens: int
    total_output_tokens: int
    total_cost_usd: float
    total_latency_ms: int
    llm_calls: int
    per_tool_tokens: dict[str, int]
    timestamp: str

@dataclass
class EvalResult:
    name: str
    passed: bool
    turns: list[TurnResult]
    cost_snapshot: EvalCostSnapshot | None  # Replaces parent spec's CostReport (simpler for Phase 1)
    cost_deltas: list[CostDelta] | None    # Baseline comparison (new, not in parent spec)
    error: str | None = None

    def summary(self) -> str:
        """Human-readable summary for pytest failure output."""
```

## 12. Error Handling

| Scenario | Behavior |
|---|---|
| Agent exception during eval | Eval fails, partial cost captured, `error` field populated |
| Langfuse unavailable | Evals run, cost tracking skipped, warning logged |
| Golden file missing | Fail fast with clear message: "Run with --update-golden to create" |
| Cost baseline missing | Cost deltas skipped, absolute values still reported |
| Missing tool registration | Fail fast before agent runs, list missing tools |
| Invalid YAML eval case | Pydantic validation at load time, file path in error |
| Workspace file staging fails | Fail fast, report which fixture file is missing |
| Unknown agent in eval case | Fail fast, list available agents |

## 13. Production Code Reuse

| Component | Production | Eval |
|---|---|---|
| `invoke_agent()` / `ainvoke_agent()` | Same | Same (no mocking) |
| `register_usecase_tools()` | Called in `server.py` | Called in `conftest.py` fixture |
| `TraceMetadata` | Same | Same (with `tags=["eval"]` added) |
| Langfuse `CallbackHandler` | Same | Same (traces are real) |
| Checkpointer (`InMemorySaver`) | Same | Same |
| Agent configs (YAML) | Same | Same (evals run against real configs) |

The eval framework adds no mocks or shims. Agents are invoked identically to production.

## 14. Phased Delivery

### Phase 1: CI Gate (this spec)

- `eval/models/`, `eval/core/` (loader, runner linear mode, workspace, cost_tracker Level 1)
- `eval/assertions/` (deterministic + registry + golden match)
- `eval/scoring/` (langfuse_scorer)
- `eval/pytest_plugin/` (plugin, fixtures, reporting)
- Eval cases for all 9 Nurture agents in MER
- Makefile targets + CLI options
- CI workflow with targeted triggers + PR comment reporter + `/eval-full` override

### Phase 2: LLM-as-Judge + Cost Level 2

- `eval/assertions/llm_judge.py` (wraps OpenEvals)
- `eval/core/cost_tracker.py` Level 2 utilization analysis
- `--eval-cost-deep` flag
- Retry config for flaky LLM assertions
- Advisory recommendations in cost report
- Cost regression gate (configurable hard fail on threshold breach)

### Phase 3: Goal-Based Evals

- `eval/core/runner.py` goal-based mode
- `eval/simulators/` (response bank, LLM persona)
- `eval/models/eval_case.py` goal + simulator config
- `eval_goal` pytest marker

### Phase Dependencies

```
Phase 1 (CI Gate) ← this spec
   |
   |---> Phase 2 (LLM Judge + Cost Deep + Regression Gate)
   |
   |---> Phase 3 (Goal-based + Simulators)
```

Phases 2 and 3 are independent.
