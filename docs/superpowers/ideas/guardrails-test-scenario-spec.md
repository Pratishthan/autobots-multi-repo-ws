# Test Scenario Spec — Guardrails & Gates

| Field         | Value                          |
| ------------- | ------------------------------ |
| Feature       | DYN-X: Guardrails & Gates      |
| Author        | doc_pk                         |
| Status        | Draft                          |
| Version       | 1.0                            |
| Last Updated  | {YYYY-MM-DD}                   |
| Repository    | autobots-devtools-shared-lib   |

> This document is the **single source of truth** for guardrails feature acceptance.
> Each scenario row maps 1:1 to a pytest function.
> The agent generates test code from this spec — not the other way around.

---

## 1.0 Test Data

| Data Set Name        | Model / Entity     | Purpose                                   | Sample Data                                                                 | Notes                    |
| -------------------- | ------------------ | ----------------------------------------- | --------------------------------------------------------------------------- | ------------------------ |
| valid_agent_meta     | AgentMeta          | Provides agent config with guardrails     | `agents.yaml` with `guardrails: [input_length, pii_check]`                 | Uses concierge domain    |
| no_guardrails_meta   | AgentMeta          | Agent config without guardrails section   | `agents.yaml` with no `guardrails` key                                     | Existing agents unbroken |
| mock_llm_response    | str                | Simulates agent output for output gates   | `"Here is a joke about Python..."`                                         |                          |
| pii_input            | str                | Input containing PII for detection        | `"My SSN is 123-45-6789 and my email is alice@example.com"`                | Triggers PII guardrail   |
| oversized_input      | str                | Input exceeding configured max length     | 10,000 char string                                                          | Triggers length guard    |

---

## 1.1 Positive Tests

| Scenario Name                                          | Service / Unit           | Priority | Preconditions                          | Steps                                                                                                           | Expected Result                                                                                    | Reference Models |
| ------------------------------------------------------ | ------------------------ | -------- | -------------------------------------- | --------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- | ---------------- |
| Single guardrail passes on clean input                 | GuardrailChain           | P0       | Agent with `input_length` guardrail    | 1. Register guardrail `input_length` with max=5000 2. Invoke chain with 100-char input                         | 1. Chain returns `GuardrailResult(passed=True)` 2. Original input forwarded unchanged to agent     | AgentMeta        |
| Multiple guardrails execute in declared order          | GuardrailChain           | P0       | Agent with `[input_length, pii_check]` | 1. Register both guardrails 2. Invoke chain with clean 100-char input                                          | 1. Both guardrails execute 2. Execution order matches YAML declaration order 3. Both pass          | agents.yaml      |
| Agent without guardrails config runs normally          | GuardrailChain           | P0       | Agent with no `guardrails` key in YAML | 1. Load `no_guardrails_meta` 2. Invoke agent with any input                                                    | 1. No guardrail executes 2. Agent processes input as before 3. No error, no warning                | AgentMeta        |
| Guardrail receives AgentMeta context                   | GuardrailBase            | P1       | Any guardrail registered               | 1. Register custom guardrail that inspects context 2. Invoke with input                                        | 1. Guardrail's `execute()` receives `agent_name`, `domain`, `session_id` from AgentMeta            | AgentMeta        |
| Custom guardrail registered via YAML config            | agents.yaml parser       | P1       | `guardrails: [custom_profanity]`       | 1. Define `custom_profanity` guardrail in app code 2. Declare in `agents.yaml` 3. Load agent                   | 1. Agent's guardrail chain includes `custom_profanity` 2. Guardrail callable on agent invocation   | agents.yaml      |
| Output gate validates response before returning        | OutputGate               | P1       | Agent with output gate configured      | 1. Register output gate `response_length` 2. Agent produces 500-char response                                  | 1. Output gate runs after agent response 2. Returns `GateResult(passed=True)` 3. Response returned |                  |
| Guardrail pass logged via Langfuse span                | langfuse_span            | P2       | Langfuse enabled, guardrail configured | 1. Enable Langfuse tracing 2. Invoke agent with clean input                                                    | 1. Langfuse span created with name `guardrail:{name}` 2. Span shows `status: passed`              | TraceMetadata    |

## 1.2 Negative Tests

| Scenario Name                                          | Service / Unit           | Priority | Preconditions                          | Steps                                                                                                           | Expected Result                                                                                    | Reference Models |
| ------------------------------------------------------ | ------------------------ | -------- | -------------------------------------- | --------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- | ---------------- |
| Chain halts on first guardrail failure                 | GuardrailChain           | P0       | Agent with `[pii_check, input_length]` | 1. Invoke chain with `pii_input` (contains SSN)                                                                | 1. `pii_check` fails 2. `input_length` never executes 3. Returns `GuardrailResult(passed=False)`   | AgentMeta        |
| Guardrail failure returns structured error             | GuardrailChain           | P0       | Any guardrail that rejects input       | 1. Invoke chain with input that triggers failure                                                                | 1. Result contains `error_code`, `guardrail_name`, `message` 2. No exception raised                |                  |
| Guardrail does not mutate input message                | GuardrailChain           | P0       | Any guardrail registered               | 1. Capture input string reference before chain 2. Invoke chain (pass or fail)                                  | 1. Input string is identical (by value) after chain completes 2. No side effects on input          |                  |
| Guardrail timeout treated as failure                   | GuardrailBase            | P1       | Guardrail with timeout=1s configured   | 1. Register guardrail that sleeps 3s 2. Invoke chain                                                           | 1. Returns `GuardrailResult(passed=False, error_code="GUARDRAIL_TIMEOUT")` 2. Does not hang        |                  |
| Unknown guardrail name in YAML raises on agent load    | agents.yaml parser       | P1       | `guardrails: [nonexistent_guard]`      | 1. Declare unknown guardrail name in YAML 2. Attempt to load agent                                             | 1. Raises `GuardrailRegistrationError` at load time 2. Error message includes the unknown name     | AgentMeta        |
| Output gate failure blocks response                    | OutputGate               | P1       | Agent with output gate configured      | 1. Register output gate that rejects responses > 1000 chars 2. Agent produces 2000-char response               | 1. Output gate fails 2. Agent response NOT returned to user 3. Structured error returned instead   |                  |

## 1.3 Edge Cases

| Scenario Name                                          | Service / Unit           | Priority | Preconditions                          | Steps                                                                                                           | Expected Result                                                                                    | Reference Models |
| ------------------------------------------------------ | ------------------------ | -------- | -------------------------------------- | --------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- | ---------------- |
| Empty guardrails list in YAML treated as no guardrails | agents.yaml parser       | P1       | `guardrails: []`                       | 1. Declare empty guardrails list 2. Load agent 3. Invoke with any input                                        | 1. No guardrail executes 2. Agent runs normally 3. No error, no warning                            | AgentMeta        |
| Guardrail with empty input string                      | GuardrailChain           | P2       | `input_length` guardrail configured    | 1. Invoke chain with `""` (empty string)                                                                       | 1. Guardrail executes without error 2. Passes (empty is within length) 3. Agent receives `""`      |                  |
| Concurrent guardrail invocations are isolated          | GuardrailChain           | P2       | Same agent, two sessions               | 1. Invoke guardrail chain for session_A with clean input 2. Simultaneously invoke for session_B with PII input | 1. Session_A passes, session_B fails 2. No state leakage between sessions                         |                  |
| Guardrail failure during batch_invoker                 | batch_invoker            | P1       | Batch agent with guardrails            | 1. Submit 3 records: clean, PII, clean 2. Run batch                                                            | 1. Record 1 succeeds 2. Record 2 fails with guardrail error 3. Record 3 succeeds                  | BatchResult      |

## 1.4 Sanity Scenarios

| Scenario Name                                        | Steps                                                                                                                                                                      | Assertions                                                                                                       |
| ---------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| Guardrails E2E via Jarvis concierge                  | 1. Configure `joke_agent` with `input_length` guardrail (max=500) 2. Send short joke request via Chainlit 3. Send 1000-char input                                        | 1. Short request → joke returned 2. Long request → user-friendly rejection message 3. Langfuse spans visible     |
| Existing agents unaffected by guardrails feature     | 1. Run `make all-checks` on Jarvis with no YAML changes 2. Run concierge sanity test                                                                                     | 1. All existing tests pass 2. No warnings about missing guardrails config 3. Agent behaviour identical to before |
