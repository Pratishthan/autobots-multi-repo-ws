# BIAN Vertical Layer — Deposits Coverage Graph (design)

**Status:** Design approved in brainstorming; ready for implementation planning.
**Date:** 2026-07-04
**Author:** PK
**Pilot scope:** BIAN Deposits domain → deposits systemic APIs.

---

## 1. Goal & shape

Add a **business-process tier** (BIAN) on top of the existing **systemic tier**
(services / APIs / data models / Java behaviours) in the **same** Neo4j graph,
welded by realization edges, so that **coverage / gap analysis for the Deposits
domain is a Cypher query**.

- **Primary outcome:** coverage / gap analysis — given a BIAN Service Domain,
  Service Operation, or Business Scenario, show which systemic APIs realize it and
  where the gaps are. A "gap" is a first-class, queryable thing: a BIAN element with
  no realization.
- **Why:** accelerate rollouts by making "which business capabilities do we already
  have wired up, and what's missing?" answerable directly from the graph.
- Everything is keyed by stable `kgId` and loaded via Cypher `MERGE`, exactly like
  the current systemic pipeline. The two tiers coexist by **kgId namespace + labels**.

Chosen architecture: **unified graph, two labeled tiers** (rejected: federated
two-graph + crosswalk; rejected: lightweight tag overlay — it cannot represent
business scenarios and, fatally, an *unrealized* capability has no node to tag, so
the most important gaps become invisible).

---

## 2. Ontology (graph model)

### 2.1 BIAN tier (new labels, `bian:` kgId namespace)

| Label | kgId example | key properties |
|---|---|---|
| `:ServiceDomain` | `bian:sd:deposit-account` | `name`, `bianRef` |
| `:ServiceOperation` | `bian:so:deposit-account:initiate` | `name`, `action` (CR/BQ/…), `bianRef` |
| `:BusinessScenario` | `bian:scn:open-term-deposit` | `name`, `desc` |
| `:ScenarioStep` | `bian:scn:open-term-deposit:2` | `seq`, `label` |

BIAN-internal edges:
- `:HAS_OPERATION` — `:ServiceDomain → :ServiceOperation`
- `:HAS_STEP` + `:NEXT` — `:BusinessScenario → :ScenarioStep` (ordered chain)
- `:INVOKES_SD` — `:ScenarioStep → :ServiceDomain`

### 2.2 The weld — reified realization (authored ONLY at operation level)

A Service Operation can be realized by more than one systemic API. A flat set of
edges would be a **bag of APIs**, losing **order** and **data binding** — so the
realization is **reified as a node** that is itself a small flow (reusing the Flow
concept-note ontology — steps ordered by `:NEXT`, data flow via `:DataItem` with
`:PRODUCES`/`:CONSUMES`, the Flow note's `EMITS`/`CONSUMES` renamed for clarity here).

```
:ServiceOperation ─[:REALIZED_BY {status, confidence, source, rationale}]→ :Realization
:Realization ─[:HAS_STEP]→ :RealizationStep
:RealizationStep ─[:NEXT {condition?}]→ :RealizationStep      ← ORDER
:RealizationStep ─[:INVOKES]→ :ApiOperation                  (systemic, per-endpoint kgId)
:RealizationStep ─[:PRODUCES]→ :DataItem                     ← DATA OUT
:RealizationStep ─[:CONSUMES]→ :DataItem                     ← DATA IN
:DataItem ─[:BOUND_TO]→ :DataModel                           (systemic schema, by kgId)
```

- `:Realization` props: `status: proposed | confirmed`, `confidence`, `source`
  (agent run id), `rationale`, plus confirmation metadata (who/when).
- **1:1 case** is a single-step `:Realization` — degenerate, cheap, same query shape.
- **`:DataItem` binds to a real `:DataModel`** via `:BOUND_TO` (by `kgId`), not a
  free-text string. The systemic layer *is* the controlled vocabulary — this avoids
  the string-equality dedup blocker the Flow concept note flagged.

### 2.3 Cardinality

The weld is **many-to-many** at the Service-Operation ↔ ApiOperation level, and is
**authored only there**. Coarser coverage is **derived by roll-up, never authored**
(authoring at multiple levels would create two sources of truth that can contradict):

- **Service-Domain coverage** = aggregate of its Service Operations' realizations.
- **Business-Scenario coverage** = derived from its steps (each step points at a
  Service Domain / Operation, not directly at an API).

Reaching Java behaviours is **transitive**, not a new weld:
`:ServiceOperation → :Realization → :RealizationStep → :ApiOperation → (existing) → :Behaviour`.

### 2.4 Prerequisites (resolved)

Every API endpoint already has its own `kgId`, so per-endpoint `:ApiOperation` nodes
exist and are a valid weld target. No systemic-tier prerequisite work is required.

---

## 3. Ingestion pipeline

Reuse the existing pattern: **source → `kgId` records → Cypher `MERGE`** (idempotent
on `kgId`).

- **BIAN seed source:** a **CSV / Excel owned by the Product Owner** (not
  hand-authored JSON). The PO maintains the Deposits catalogue there.
- **Loader:** parses the (denormalized) CSV — columns identify service domain,
  service operation + action, scenario, step seq + label — and normalizes rows into
  the BIAN-tier nodes/edges of §2.1 via `MERGE` (dedup by `kgId`).
- **No change** to how the systemic tier is loaded; BIAN nodes coexist by namespace
  + labels.
- Re-running the loader on an updated CSV is idempotent (MERGE on `kgId`); removals
  are handled by the loader diffing the CSV against existing `bian:` nodes.

*(Exact CSV column contract is an implementation-plan artifact, agreed with the PO.)*

---

## 4. Mapping / weld agent (LLM-assisted proposer)

A MER-style agent pass, run per Service Operation, produces **proposed**
realizations for a human to confirm:

1. **Retrieve candidates** — pull systemic `:ApiOperation`s plausibly related to the
   operation (name / description / schema similarity over the KG).
2. **Synthesize the plan** — order candidate APIs by matching output→input schemas
   (topological sort over request/response `:DataModel`s), emitting `:RealizationStep`s
   with `:NEXT` order and `:DataItem` bindings (`:BOUND_TO` the matched `:DataModel`).
3. **Score & explain** — attach `confidence` + `rationale`.
4. **Write as `proposed`** — `MERGE` the `:Realization` subgraph with `status: proposed`.

Deterministic where possible (schema matching, topo sort); the LLM handles fuzzy
candidate retrieval and naming. Order and data flow are therefore *derived* from the
API contracts already in the KG, not hand-guessed.

**Human confirmation** flips `proposed → confirmed` (the governance gate). No edge is
trusted for coverage until confirmed.

---

## 5. Gap-analysis queries (the product)

- **Uncovered** — `:ServiceOperation` with no `confirmed` `:REALIZED_BY`.
- **Partial** — has a `:Realization`, but a step's `:INVOKES` target is missing, or a
  `:DataItem` is unbound / dangling (have the APIs, can't sequence them).
- **Orphan API** (inverse) — `:ApiOperation` that no realization step invokes
  (un-catalogued surface).
- **Roll-ups** — Service-Domain coverage % from its operations; Business-Scenario
  green / amber / red from its steps' service domains.
- **Output** — a coverage report (Cypher → table / JSON): the concrete
  "accelerate rollouts" deliverable.

---

## 6. Provenance & confirmation workflow

- Every `:Realization` records `source` (agent run id), `confidence`, `status`, and
  confirmation metadata.
- **Review / confirmation reuses the Flow UI** (to be wired in from PK's other
  codebase). Reviewers see a proposed realization as a small flow and confirm it,
  flipping `status` to `confirmed`. No bespoke review UI is built in this pilot.

---

## 7. Testing

- **Deterministic parts** — ingestion idempotency, roll-up + gap Cypher: tested with
  fixtures. A fixed Deposits seed (CSV) + a fixed systemic-API fixture → assert the
  gap queries return the expected uncovered / partial / orphan sets.
- **Agent proposer** — tested against a small **golden set** (known operation →
  expected plan), scored for precision / recall on proposed steps. Human review stays
  manual, not asserted.

---

## 8. Non-goals (pilot)

- Branching / conditional realizations (`:Decision` nodes) — `:NEXT` may carry a
  `condition` label if one appears, but reified decisions are deferred.
- Parsing official BIAN machine-readable artifacts (Service Landscape spreadsheets /
  semantic API) — the PO-owned CSV is the seed for now.
- Scaffold / stub generation into the MER nurture pipeline (a different, un-chosen
  outcome).
- Domains beyond Deposits.

---

## 9. Resolved open questions

1. **`:ApiOperation` nodes exist?** — Yes; every API endpoint has its own `kgId`.
2. **BIAN seed source / owner?** — A CSV / Excel owned by the Product Owner.
3. **Confirmation UI?** — Reuse the Flow UI (wired from PK's other codebase).
