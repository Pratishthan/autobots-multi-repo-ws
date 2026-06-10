# Flow-2 Chat → Dynagent + Chainlit Copilot — Design Spec

**Date:** 2026-06-10
**Status:** Approved (design); pending implementation plan
**Scope:** Replace Flow-2's mock chat agent with a real Dynagent agent surfaced through
the Chainlit copilot widget, preserving the flow-aware node-reference / canvas-jump UX.

---

## Problem

`Flow-2/chat-panel.jsx` ships a self-contained chat drawer whose only backend seam is
`sendToAgent(message, ctx)`, currently resolving a context-aware **mock** (`mockAgent`).
The mock answers questions about the active flow (owners, SLAs, decline paths, counts,
walkthrough) and returns `{ text, refs }`, where `refs` are node ids rendered as clickable
chips that jump the canvas to that node.

We want a **real Dynagent agent**, delivered through **Chainlit**, without losing the
flow-aware answers or the node-chip → canvas-jump experience.

## Decisions (locked during brainstorming)

| # | Decision | Choice |
|---|----------|--------|
| 1 | UI model | **Embed the Chainlit copilot widget** in the existing drawer (not keep custom panel behind an API, not iframe a full app). |
| 2 | Flow context delivery | **Agent reads flow data server-side via Dynagent tools.** Host sends only the active `flowId`. |
| 3 | Home repo | **New `flow` domain in `autobots-agents-jarvis`.** |
| 4 | Node-ref / jump UX | **Custom-element chips** (`cl.CustomElement`) that bridge clicks to a host canvas-jump function. |

**Scope:** demo-grade — anonymous access (no OAuth), in-memory context store, tracing on
but optional — matching the other Jarvis demo domains.

**Verified:** Chainlit 2.9.6 (already a shared-lib dependency) exposes `CopilotFunction`,
`CustomElement`, `send_window_message`, `on_window_message`, `user_session`, `context`.

---

## Architecture

```
┌─ Flow-2 (browser, no-build) ───────────────┐      ┌─ autobots-agents-jarvis ──────────────┐
│ Flow.html                                  │      │ domains/flow/server.py (Chainlit)     │
│   ├─ loads {server}/copilot/index.js       │      │   @cl.on_chat_start  create_base_agent│
│   ├─ window.mountChainlitWidget({server})  │ ◀──▶ │   @cl.on_message     stream_agent_... │
│   ├─ window.flowJumpToNode(id)  (host fn)  │      │   @cl.on_window_message  flow:switch  │
│   └─ ChatToggle opens drawer w/ widget     │      │ domains/flow/tools.py                 │
│ canvas jump  ◀── chip click                │      │   get_flow / list_nodes / get_node    │
└────────────────────────────────────────────┘      │ agent_configs/flow/ (agents.yaml,…)   │
        ▲ NodeChips custom element                   │ data/flows/ (server-side flow JSON)   │
        └─ public/elements/NodeChips.jsx             └───────────────────────────────────────┘
```

### Components

- **Server** (`domains/flow/server.py`) — Chainlit app mirroring `concierge/server.py`:
  tracing init, anonymous identifier, `create_base_agent(state_schema=FlowState)` stored in
  `cl.user_session`, `@cl.on_message` → `stream_agent_events(...)`. Adds an
  `@cl.on_window_message` handler that records the active `flow_id` into `cl.user_session`.
- **`FlowState(Dynagent)`** — extends the base state with a single `flow_id: str` field.
- **Tools** (`domains/flow/tools.py`) — `get_flow`, `list_nodes(type?)`, `get_node(id)`.
  Each reads `flow_id` from `runtime.state` and loads via the `flow_data` service.
  Registered once via `register_flow_tools()` before `create_base_agent()`.
- **`flow_data` service** (`domains/flow/services.py`) — loads pre-baked flow JSON from
  `data/flows/<id>.json`; provides `get_flow(id)`, `get_node(id, node_id)`,
  `list_nodes(id, type=None)`. Pure, no Chainlit imports (unit-testable).
- **Host wiring** (Flow-2) — mounts the copilot widget, exposes `window.flowJumpToNode(id)`,
  posts `flow:switch` window messages on flow change, retires the mock half of
  `chat-panel.jsx` while keeping the drawer chrome + `ChatToggle`.
- **`NodeChips`** (`public/elements/NodeChips.jsx`) — one Chainlit custom element rendering
  ref chips from `props.refs`; `onClick` → `window.flowJumpToNode(r.id)`.

---

## Data flow

### Message round-trip
1. User types in the copilot widget → `@cl.on_message`.
2. Server builds `input_state = { messages, flow_id, app_name, session_id }` (flow_id from
   `cl.user_session`).
3. `stream_agent_events` streams tokens into the widget.
4. Agent calls `get_node` / `list_nodes` / `get_flow` as needed to ground its answer.
5. Final answer carries structured `refs: [{ id, title, type, term }]`
   (schema `schemas/flow-answer.json`).
6. Server attaches a `NodeChips` `cl.CustomElement` (built from `refs`) to the reply message.

### Flow-switch
- Flow-2's existing flow-change handler sends a window message `{ kind: "flow:switch",
  flowId }` to the widget.
- `@cl.on_window_message` parses it and stores `flow_id` in `cl.user_session`.
- Sent once on first mount (initial flow) and on every subsequent switch.

### Canvas jump
- Chip click in `NodeChips` → `window.flowJumpToNode(id)` (host function wrapping Flow-2's
  existing `onJump`/canvas pan+highlight).
- The copilot widget mounts into the host page (same-page React root), so the element can
  call the host global directly — no iframe/postMessage hop.
- `window.flowJumpToNode` no-ops gracefully if `id` is not in the current flow.

---

## Server-side `flow` domain — file layout

```
autobots-agents-jarvis/
  src/autobots_agents_jarvis/domains/flow/
    server.py          # Chainlit entry (concierge pattern + on_window_message)
    tools.py           # get_flow / list_nodes / get_node + register_flow_tools()
    services.py        # flow_data loader over data/flows/<id>.json
  src/autobots_agents_jarvis/common/models/state.py
    # add FlowState(Dynagent) with flow_id   (or domain-local module if that fits better)
  agent_configs/flow/
    agents.yaml        # single 'flow_assistant' agent
    prompts/flow-assistant.md
    schemas/flow-answer.json   # { answer: str, refs: [ { id, title, type, term } ] }
  data/flows/          # server-side flow JSON (generated; see below)
  scripts/build_flow_data.py   # data/*.flow.mmd + *.cards.yaml → data/flows/*.json
  public/elements/NodeChips.jsx
```

### Flow data on the server (the accepted "data copy" cost)
Flow-2 parses Mermaid topology (`data/<id>.flow.mmd`) + card YAML (`data/<id>.cards.yaml`)
in the browser. Rather than re-implement that parser in Python, a small build script
(`scripts/build_flow_data.py`) converts each flow into a single
`data/flows/<id>.json` with normalized node records:

```json
{
  "id": "lend.underwrite",
  "name": "Loan Underwriting",
  "nodes": [
    { "id": "n1", "title": "...", "type": "system|manual|decision|terminal",
      "term": "start|end|declined|null", "owner": "...", "team": "...",
      "sla": "...", "inputs": [...], "outputs": [...], "documents": [...],
      "desc": "..." }
  ]
}
```

`services.py` only reads JSON. Re-syncing after a flow data change is one command
(`python scripts/build_flow_data.py`). This is the single sync cost accepted under
decision #2.

### Agent prompt
`prompts/flow-assistant.md` follows the repo's 13 agent-prompt guidelines: role in the
first sentence; XML sections (`<role>`, `<inputs>`, `<workflow>`, `<tools>`,
`<examples>`, `<error_handling>`); explicit tool manifest (only `get_flow`, `list_nodes`,
`get_node`); 3 examples — nominal (owner lookup with refs), fallback (vague query →
clarify), empty (no `flow_id` / unknown node). Capability baseline mirrors the mock:
owners, SLAs, decline/fallout paths, manual/system/decision counts, walkthrough/overview,
documents produced.

---

## Host-side wiring (Flow-2)

- **`Flow.html`** — add `<script src="{CHAINLIT_SERVER}/copilot/index.js">`; on load call
  `window.mountChainlitWidget({ chainlitServer: CHAINLIT_SERVER })`.
- **`flow-chat.js`** (new; supersedes the agent half of `chat-panel.jsx`) —
  - defines `window.flowJumpToNode(id)` routing to the existing canvas jump,
  - posts `flow:switch` window messages when the active flow changes (hook into the same
    place that sets `flowId`).
- **Drawer** — keep `ChatToggle` and the drawer chrome; host the copilot inside it.
  (Open detail for the plan: mount copilot inside the existing drawer vs. use Chainlit's
  own launcher button — resolve during planning; default = inside the existing drawer to
  preserve current toggle/placement.)
- **`public/elements/NodeChips.jsx`** — renders chips from `props.refs`, palette-styled to
  match the current chip look; `onClick={() => window.flowJumpToNode(r.id)}`.
- `_legacy/` and `_backup/` are left untouched. `chat-panel.jsx` is retired (its drawer
  shell/chrome may be lifted into the kept wrapper; its `mockAgent` is deleted).

---

## Error handling

- **Server unreachable / CORS** — widget surfaces its own connection error; the Flow-2
  canvas keeps working. Server configures `allow_origins` for the Flow-2 origin.
- **Unknown `flow_id` / node** — tools return an explicit "not found" payload; agent asks
  the user to pick a flow or rephrase (covered by the empty-case prompt example).
- **No `flow_id` yet** (window message not received before first message) — tools guard on
  missing `flow_id`; agent answers generically and prompts the user to open a flow.
- **Stale jump target** — `window.flowJumpToNode` no-ops if the id is not in the current
  flow.

---

## Testing

- **Unit (pytest, jarvis):**
  - `flow_data` loader — load, node lookup hit/miss, `list_nodes` by type, missing flow id.
  - tools — `get_node` hit/miss, `list_nodes` filtering, missing-`flow_id` guard.
  - `build_flow_data.py` — sample `.mmd` + `.cards.yaml` → expected JSON.
- **Integration:**
  - `stream_agent_events` over a canned flow yields structured `refs`.
  - `@cl.on_window_message` sets session `flow_id`.
- **Manual / host smoke** (no JS test harness in this no-build app, matching current
  practice): load `Flow.html`, switch flows, ask "who owns X" / "where can it get
  declined", click a chip → canvas jumps.

---

## Out of scope (YAGNI)

- RAG / vector search over flows (tools leave room for it later).
- Sub-flow drill-down integration (tracked separately in `SUBFLOW_BRIEF.md`).
- OAuth / multi-user auth, persistent context store, conversation history persistence.
- Multi-agent handoff — single `flow_assistant` agent only.

---

## Open items for the implementation plan

1. Where `FlowState` lives — `common/models/state.py` alongside `JarvisState`, or a
   domain-local `domains/flow/state.py`.
2. Exact window-message envelope/format accepted by `@cl.on_window_message` (string vs
   JSON) in Chainlit 2.9.6 — confirm against the installed API during the first task.
3. Copilot placement: inside the existing drawer vs. Chainlit's own launcher (default:
   inside the drawer).
4. How structured `refs` are produced — structured-output schema vs. a lightweight
   `cite_nodes` tool call — pick one in the plan; schema is the default.
