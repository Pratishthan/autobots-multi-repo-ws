# dyna-render: Deterministic JSON → Markdown Renderer

**Status:** Draft
**Date:** 2026-04-27
**Scope:** Workspace-level (lives in `autobots-devtools-shared-lib`)

## 1. Problem

Several agents (Designer, future agents in MER and elsewhere) produce structured JSON artifacts as their working output. Humans need a Markdown view of those artifacts.

Today, MER's `lld-consolidator` agent uses an LLM to fold ~20 JSON directive files into a single LLD Markdown document. Using an LLM for what is fundamentally a deterministic JSON-to-MD transformation is the wrong tool: it is non-deterministic, expensive, and re-formats content that already has a fixed shape.

## 2. Goals & Non-Goals

**Goals**

- A workspace-level library that converts structured JSON inputs into human-readable Markdown using templates only — no LLM in the rendering path.
- Deterministic: same JSON in, byte-identical MD out.
- Composable: a single document can stitch many JSONs together at arbitrary depth.
- I/O-agnostic: works against MER's file-server-backed workspace, local filesystems for CLI/tests, or any other backend.
- First-class fit alongside existing Dynagent config (`prompts/`, `schemas/`).

**Non-goals**

- Narrative / prose generation. If a domain wants intro paragraphs or transition text, that stays an agent concern (a separate sub-agent in `agents.yaml`) and is out of scope here.
- JSON Schema validation of inputs. Templates may assume well-formed input; validation, if needed, is a pre-step.
- Two-way binding. This is JSON → MD only.

## 3. Design Decisions Summary

| # | Decision | Choice |
|---|---|---|
| 1 | LLM in the loop? | No. Purely deterministic. Any prose stitching is a separate agent. |
| 2 | Where do templates live? | Per-domain, co-located with schemas (`agent_configs/<domain>/templates/`). Shared-lib provides only the engine. |
| 3 | How are JSON inputs bound to templates? | Explicit YAML manifest per domain (`render.yaml`). |
| 4 | Composition shape? | Recursive node tree (leaves and composites are interchangeable; same render function at every depth). |
| 5 | Render flow? | Two-pass / fragments-as-strings: each leaf renders to a Markdown string; composite parents receive children as pre-rendered strings via `sections.<name>`. |
| 6 | API surface? | Layer 1 pure core function + a Dynagent tool wrapper. No filesystem convenience wrappers in v1. |
| 7 | Strictness on missing inputs? | `strict: bool` flag on the engine call (`True` by default). Lenient mode emits placeholders and collects errors. |
| 8 | Template engine? | Jinja2 (`StrictUndefined` in strict mode). |

## 4. Module Layout

New module in `autobots-devtools-shared-lib`:

```
src/autobots_devtools_shared_lib/dyna_render/
├── __init__.py        # public API exports
├── engine.py          # render_document() — Layer 1 pure core
├── manifest.py        # manifest dataclasses + parser
├── tool.py            # Dynagent tool wrapper
└── errors.py
```

Additionally, two new helpers added to the existing `dynagent/agents/agent_config_utils.py` next to `load_prompt` and `load_schema`:

- `load_template(name: str) -> str` — reads `<config_dir>/templates/<name>`
- `load_render_manifest() -> dict` — reads `<config_dir>/render.yaml`

These are not engine parameters; they are shared-lib internals consumed by `render_document`.

## 5. Public API

```python
from autobots_devtools_shared_lib.dyna_render import render_document, RenderResult

def render_document(
    document_name: str,                          # key under `documents` in render.yaml
    load_json: Callable[[str], dict],            # caller supplies — workspace JSON I/O
    strict: bool = True,
) -> RenderResult: ...

@dataclass
class RenderResult:
    md: str
    errors: list[RenderError]                    # always present; empty when fully successful

@dataclass
class RenderError:
    node_path: str                               # dotted path in the manifest, e.g. "lld.data.models"
    kind: Literal["missing_json", "missing_template", "undefined_variable"]
    message: str                                 # human-readable detail
    cause: Exception | None = None               # original exception, if any
```

The Dynagent tool `render_document_tool` returns the rendered MD **as a string** plus a serialized error list. It does not write to the filesystem — the calling agent decides where to persist (e.g. via `mer_write_file_tool`).

`load_template` and `load_render_manifest` are resolved internally from `DYNAGENT_CONFIG_ROOT_DIR`, exactly like `load_prompt` and `load_schema` already are.

The only caller-supplied loader is `load_json`, because JSON *inputs* are workspace artifacts whose backend varies by deployment:

| Caller | `load_json` implementation |
|---|---|
| MER agents | hits the file server (`mer_file_service`) at the workspace path |
| CLI / scripts | local filesystem |
| Tests | in-memory dict |

A Dynagent tool `render_document_tool` is also exported. Domains register it once with their `load_json`:

```python
from autobots_devtools_shared_lib.dyna_render.tool import make_render_document_tool

register_usecase_tools([
    make_render_document_tool(load_json=mer_load_workspace_json),
])
```

## 6. Manifest Format

One YAML file per domain at `agent_configs/<domain>/render.yaml`. Top-level `documents` map; each value is a node tree.

A **node** is exactly one of:

- **Leaf** — `{ json: <relative-workspace-path>, template: <template-name> }`
- **Composite** — `{ template: <template-name>, children: { <name>: <node>, ... } }`

A node may **not** contain both `json` and `children` — the manifest parser rejects this as a validation error at load time. Recursive: any child can itself be a leaf or a composite. No depth limit.

Example (Designer's LLD):

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
          models:    { json: data_models.json,   template: data_models.md.j2 }
          accesses:  { json: data_accesses.json, template: data_accesses.md.j2 }
      services:
        template: services_section.md.j2
        children:
          definitions: { json: service_definitions.json,     template: service_definitions.md.j2 }
          sync_props:  { json: service_sync_properties.json, template: service_sync_props.md.j2 }
      logical_processing_units:
        json: logical_processing_units.json
        template: lpus.md.j2
      error_definitions:
        json: error_definitions.json
        template: errors.md.j2
```

Templates are looked up under `agent_configs/<domain>/templates/`. JSON paths are workspace-relative (resolved by the caller-supplied `load_json`).

## 7. Render Algorithm

```python
def render(node, ctx) -> Fragment:
    if node.is_leaf():
        try:
            data = ctx.load_json(node.json)
        except FileNotFoundError as e:
            return ctx.handle_missing(node, e)         # respects strict flag
        return Fragment(jinja.render(load_template(node.template), data))

    # composite
    sections = {name: render(child, ctx) for name, child in node.children.items()}
    return Fragment(jinja.render(
        load_template(node.template),
        {"sections": {k: v.md for k, v in sections.items()}},
    ))
```

Children of a composite are rendered in **manifest insertion order** (YAML preserves it; the parser must not re-sort). Determinism is a stated goal, so this ordering is part of the contract.

Properties:

- Same render function at any depth. Depth is a property of the manifest, not the engine.
- Parent templates only ever see direct children's pre-rendered MD strings via `sections.<name>` — they never inspect children's structure.
- A leaf and a composite are interchangeable from the parent's POV. A leaf can be refactored into a subtree without touching the parent template.
- Any subtree is independently renderable (`render_document("lld.data", ...)` produces a valid MD doc for just the data section). *(This addressing form is a future extension; v1 only renders top-level documents.)*

A parent template is mechanical:

```jinja
{# data_section.md.j2 #}
## Data

{{ sections.models }}

{{ sections.accesses }}
```

A leaf template is data-driven:

```jinja
{# data_models.md.j2 #}
### Data Models
{% for model in models %}
#### {{ model.name }}

| Field | Type | Required | Description |
|-------|------|----------|-------------|
{% for f in model.fields -%}
| {{ f.name }} | {{ f.type }} | {{ "yes" if f.required else "no" }} | {{ f.description }} |
{% endfor %}
{% endfor %}
```

## 8. Strictness

The `strict` flag on `render_document` controls behavior on missing or malformed inputs.

| Condition | `strict=True` | `strict=False` |
|---|---|---|
| Missing JSON file | raise `MissingInputError` | fragment = `> _Section pending: <node_path>_` (where `<node_path>` is the dotted manifest path, e.g. `lld.data.models`), error appended to `RenderResult.errors` |
| Missing template file | raise `MissingTemplateError` | placeholder fragment, error appended |
| Jinja `UndefinedError` in template | raise (Jinja `StrictUndefined`) | placeholder fragment, error appended |
| Malformed JSON (parse failure) | raise | raise (not recoverable; same in both modes) |

`RenderResult.errors` is always returned (empty when fully successful). Callers can surface accumulated errors to the user even when render succeeded with placeholders.

Designer's expected usage:

- During iterative design: `strict=False` — partial documents render with placeholders for sections still being authored.
- Final consolidate step: `strict=True` — fail loudly if anything is missing.

## 9. I/O Boundary

The engine has no knowledge of filesystems or the file server. Resources split as follows:

| Resource | Lives where | Loaded by |
|---|---|---|
| `prompts/*.md` | domain config dir (`DYNAGENT_CONFIG_ROOT_DIR`) | `load_prompt` *(existing, shared-lib)* |
| `schemas/*.json` | domain config dir | `load_schema` *(existing, shared-lib)* |
| `templates/*.md.j2` | domain config dir | `load_template` *(new, shared-lib)* |
| `render.yaml` | domain config dir | `load_render_manifest` *(new, shared-lib)* |
| JSON inputs (artifacts) | workspace (file server in MER, local fs in CLI/tests) | caller-supplied `load_json` |

Rationale: templates and the manifest are domain *config* — they ship with the codebase and live next to prompts/schemas. JSON *inputs* are runtime artifacts produced by agents into a workspace, and the workspace backend genuinely varies.

## 10. Migration: Replacing `lld-consolidator`

1. Add `agent_configs/designer/render.yaml` defining the `lld` document.
2. Add per-section templates under `agent_configs/designer/templates/` (one `.md.j2` per directive currently consumed by `lld-consolidator`, plus the parent `lld.md.j2`).
3. Designer's `coordinator` agent gains `render_document_tool` (registered with file-server-backed `load_json`) and calls it with `document_name="lld"` instead of handing off to `lld-consolidator`.
4. Coordinator writes the returned MD via the existing `mer_write_file_tool`. The engine never writes files — output destination is the agent's concern.
5. Remove the `lld_consolidator` agent entry from `agent_configs/designer/agents.yaml` and delete `prompts/lld_consolidator.md`.

Other domains (Nurture, KBE, Jarvis) adopt incrementally on their own timelines — there is no flag day. The shared-lib changes are additive only.

## 11. Testing

- **Engine unit tests** with in-memory loaders, table-driven manifests covering:
  - leaf only
  - 2-level composite
  - N-level composite (≥3 deep)
  - missing JSON in `strict=True` (raises) and `strict=False` (placeholder + error in result)
  - missing template (both modes)
  - undefined variable in template (both modes)
  - malformed JSON (raises in both modes)
- **Refactor invariance test**: replacing a leaf with a composite whose template is a pass-through (`{{ sections.inner }}`) yields byte-identical output. Locks in the "leaf and composite are interchangeable" property.
- **Designer integration test**: a fixture set of all directive JSONs → expected golden LLD MD, byte-for-byte.

## 12. Open Questions / Future Extensions

- Sub-document addressing (`render_document("lld.data", ...)`) — natural fit, deferred to v2 once a real use case appears.
- Custom Jinja filters (e.g. table formatters, anchor slugifiers) — defer until a template needs one; add to `dyna_render/filters.py` then.
- A fs-backed convenience wrapper (`render_document_from_paths`) — defer; trivial to add when a non-agent caller materializes.

## 13. Out of Scope (revisit later)

- Validation of JSON inputs against their schemas before render.
- A reverse path (MD → JSON).
- Templates that compose across domains.
- A narrative-stitching sub-agent that consumes rendered fragments. (Mentioned as a possible *future* sibling agent; this spec does not define it.)
