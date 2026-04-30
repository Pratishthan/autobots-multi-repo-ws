# Migrate `lld_consolidator` to dynadoc

**Status:** Draft
**Date:** 2026-04-28
**Scope:** `autobots-agents-mer` — Designer domain
**Depends on:** [`2026-04-27-dynadoc-design.md`](./2026-04-27-dynadoc-design.md), shared-lib ≥ 0.7.0

## 1. Problem

Designer's `lld_consolidator` agent uses an LLM to fold ~7 directive JSON files into a single LLD Markdown document. The transformation is fundamentally deterministic — render JSON tables into a fixed template — yet today it pays for an LLM round trip on every consolidation.

With the new `dynadoc` library landed in shared-lib, we can replace the LLM-driven assembly with a pure Python service. This spec defines that replacement.

## 2. Goals & Non-Goals

**Goals**

- Remove the `lld_consolidator` agent and its prompt.
- Render the LLD deterministically using `dynadoc.render_document("lld", ...)`.
- Same on-disk output path and contents (byte-identical for the same inputs) as today, modulo any deliberate, reviewed differences.
- Surface missing directive JSONs as visible "Section pending" placeholders in the rendered document.

**Non-goals**

- The interactive per-section "regenerate or keep existing" merge dialog. Dropped — see §4.
- Filename-suggestion chat loop. Replaced with deterministic slug from `featureName`.
- Migrating other domains (Nurture, KBE, Jarvis).
- Any change to the upstream designer agents (`background_and_scope`, `data_models`, etc.) or their schemas.
- Sub-document addressing in dynadoc (deferred to dynadoc v2).

## 3. Design Decisions

| # | Decision | Choice |
|---|---|---|
| 1 | Keep an agent for consolidation? | **No.** Pure Python service called from `coordinator` via a single tool. |
| 2 | Existing-LLD merge strategy? | **Always overwrite.** Source of truth is the JSON. The PR diff is the audit surface. The current rule already says "do not edit the LLD between runs." |
| 3 | Section 3 (Enumerations) is inside `data_models.json`. How? | Composite `data` wrapper with two leaves over the same JSON: one renders Section 2, the other renders Section 3. |
| 4 | Section 13 (Revision History) needs today's date — no JSON for it. | Reuse `lld_header.json`. Service stamps `lastUpdated = today` before render. Revision history is a normal leaf reading `lld_header.json`. |
| 5 | Missing-input behavior. | `strict=False`. Renders the `> _Section pending: <node_path>_` placeholder for missing JSONs. Visible signal in the MD; coordinator surfaces the error list to the user. |
| 6 | Filename selection. | Deterministic slug of `lld_header.featureName`. Service accepts an optional `business_name` override but never asks. |
| 7 | Service responsibilities. | Render **and** write the file. Returns `{path, md, errors}`. PR-raising stays a separate, explicit coordinator tool call. |

## 4. Architecture

```
User → coordinator agent → consolidate_lld_tool → services/lld_consolidator.py
                                                    ├── load lld_header.json
                                                    ├── stamp lastUpdated = today
                                                    ├── write lld_header.json
                                                    ├── dynadoc.render_document("lld",
                                                    │       load_json=mer_load_json, strict=False)
                                                    └── mer_write_file_tool →
                                                        docs/FeatureLLD/<JIRA>/<JIRA>-<slug>-LLD.md
                                                  → returns { path, md, errors[] }
```

The dynadoc engine never writes to disk — the consolidator service does, using `mer_write_file_tool`. This keeps dynadoc's stated invariant intact (engine has no I/O).

## 5. Manifest — `agent_configs/designer/dynadoc.yaml`

```yaml
documents:
  lld:
    template: lld.md.j2
    children:
      header:        { json: lld_header.json,           template: header.md.j2 }
      background:    { json: background_and_scope.json, template: background.md.j2 }
      data:
        template: data_section.md.j2
        children:
          models:    { json: data_models.json, template: data_models.md.j2 }
          enums:     { json: data_models.json, template: enumerations.md.j2 }
      services:      { json: service_definitions.json,      template: services.md.j2 }
      lpus:          { json: logical_processing_units.json, template: lpus.md.j2 }
      data_access:   { json: data_accesses.json,            template: data_access.md.j2 }
      errors:        { json: error_definitions.json,        template: errors.md.j2 }
      revision:      { json: lld_header.json,               template: revision_history.md.j2 }
```

JSON paths are workspace-relative; `load_json` (supplied by the service) resolves them against `docs/FeatureLLD/<JIRA>/`.

Sections 6, 8, 10, 11, 12 are not in the manifest at all — they are omitted entirely from the document, matching the existing rule.

## 6. Templates

13 templates under `agent_configs/designer/templates/`:

| Template | Purpose |
|---|---|
| `lld.md.j2` | Top-level layout shell — concatenates `sections.header`, `sections.background`, `sections.data`, `sections.services`, `sections.lpus`, `sections.data_access`, `sections.errors`, `sections.revision`. |
| `header.md.j2` | Document header table from `lld_header.json`. |
| `background.md.j2` | Section 1 — purpose, functional overview, in/out scope, assumptions, dependencies, references. |
| `data_section.md.j2` | Composite wrapper: `{{ sections.models }}` then `{{ sections.enums }}`. |
| `data_models.md.j2` | Section 2 — iterates `dataModels[]`; properties + schema + business metadata + FBP extension tables. |
| `enumerations.md.j2` | Section 3 — flat table over `enumerations[]`. Emits an empty fragment when absent/empty (valid state, not a missing input). |
| `services.md.j2` | Section 4 — service identity, I/O, FBP extensions, async properties. |
| `lpus.md.j2` | Section 5 — LPU table + per-unit FBP behaviours sub-blocks. |
| `data_access.md.j2` | Section 7 — data access table + FBP repository queries. |
| `errors.md.j2` | Section 9 — errors table. |
| `revision_history.md.j2` | Section 13 — single-row table using `version` and `lastUpdated` from `lld_header.json`. |

Templates are mechanical translations of the existing `<output-structure>` blocks in `prompts/lld_consolidator.md`. No prose; no LLM judgment. Conditional sub-blocks (FBP extensions, async, etc.) are pure Jinja `{% if %}` over the JSON shape.

## 7. Service & Tool

`src/autobots_agents_mer/domains/designer/services/lld_consolidator.py`:

```python
@dataclass
class ConsolidateResult:
    path: str                # workspace-relative path written
    md: str                  # rendered MD (for preview / debugging)
    errors: list[dict]       # serialized RenderError list (lenient mode)

def consolidate_lld(
    state: MerState,
    business_name: str | None = None,
) -> ConsolidateResult:
    """
    1. Resolve jira_number, repo_name, user_name from state (raise if missing).
    2. Read lld_header.json from workspace; stamp lastUpdated = today (ISO date).
    3. Write lld_header.json back.
    4. Build load_json closure that reads from docs/FeatureLLD/<JIRA>/ via mer file service.
    5. Determine slug: business_name if given, else slugify(lld_header["featureName"]).
    6. Call dynadoc.render_document("lld", load_json, strict=False).
    7. Write result.md to docs/FeatureLLD/<JIRA>/<JIRA>-<slug>-LLD.md.
    8. Return ConsolidateResult.
    """
```

Tool wrapper in `domains/designer/tools.py`:

```python
@tool
def consolidate_lld_tool(
    runtime: ToolRuntime[None, MerState],
    business_name: str | None = None,
) -> dict:
    """Render and save the consolidated LLD for the current Jira ticket."""
    result = consolidate_lld(runtime.state, business_name=business_name)
    return {"path": result.path, "errors": result.errors}
```

Registered via `register_designer_tools()` before `create_base_agent()`. `DYNAGENT_CONFIG_ROOT_DIR=agent_configs/designer` is already set, so `load_render_manifest()` and `load_template()` resolve correctly without further wiring.

## 8. Coordinator Changes

**`agent_configs/designer/agents.yaml`:**

- Delete the entire `lld_consolidator:` entry.
- Add `consolidate_lld_tool` to `coordinator.tools`.

**`agent_configs/designer/prompts/coordinator.md`:**

Add a brief instruction:

> When the user asks to assemble or finalize the LLD, call `consolidate_lld_tool`. After it succeeds, offer to call `push_generated_and_raise_pull_request_tool` to raise the PR.

No per-section regeneration dialog. No filename suggestion loop.

## 9. Migration & Validation

The migration must produce output that matches the current LLD pipeline's behavior on real inputs. Process:

1. **Pick a real reference LLD** — most recent shipped `docs/FeatureLLD/<JIRA>/<JIRA>-<slug>-LLD.md` whose source JSONs are still available in the workspace.
2. **Per-section validation** — extract each section from the reference MD; render the corresponding dynadoc subtree from the actual JSON; diff.
3. **Acceptance** — every section either matches byte-for-byte, or any divergence is explicitly approved and documented inline in the migration PR review.
4. **Lock it in** — the chosen reference LLD + its source JSONs become a golden integration test (`tests/integration/designer/test_lld_consolidator.py`) so future template edits can't silently regress.

## 10. Files Touched

**Added:**
- `autobots-agents-mer/agent_configs/designer/dynadoc.yaml`
- `autobots-agents-mer/agent_configs/designer/templates/*.md.j2` (13 files)
- `autobots-agents-mer/src/autobots_agents_mer/domains/designer/services/__init__.py`
- `autobots-agents-mer/src/autobots_agents_mer/domains/designer/services/lld_consolidator.py`
- `autobots-agents-mer/tests/unit/designer/services/test_lld_consolidator.py`
- `autobots-agents-mer/tests/integration/designer/test_lld_consolidator.py` (golden test from §9)

**Modified:**
- `autobots-agents-mer/agent_configs/designer/agents.yaml` — drop `lld_consolidator`; add tool to coordinator
- `autobots-agents-mer/agent_configs/designer/prompts/coordinator.md` — add consolidation instruction
- `autobots-agents-mer/src/autobots_agents_mer/domains/designer/tools.py` — register `consolidate_lld_tool`
- `autobots-agents-mer/pyproject.toml` — require `autobots-devtools-shared-lib >= 0.7.0`

**Deleted:**
- `autobots-agents-mer/agent_configs/designer/prompts/lld_consolidator.md`

## 11. Testing

- **Unit** (`tests/unit/designer/services/test_lld_consolidator.py`): mocks file service; asserts rendered MD shape, asserts file write happened at expected path, asserts `lastUpdated` was stamped on `lld_header.json`, asserts slug derivation.
- **Integration** (`tests/integration/designer/test_lld_consolidator.py`): fixture LLD + source JSONs → byte-identical document. Locks in the validation gate from §9.
- **Lenient-mode behavior**: omitting any single source JSON yields a "Section pending" placeholder in the rendered output and a corresponding entry in `errors[]`.

## 12. Out of Scope (revisit later)

- Per-section interactive merge of an existing LLD against updated JSONs. Drop entirely; users edit the JSON, not the MD.
- Sub-document addressing (`render_document("lld.data", ...)`) — depends on dynadoc v2.
- Custom Jinja filters (slugify lives in the service, not in the templates).
- Migration plans for other domains (Nurture, KBE, Jarvis).
