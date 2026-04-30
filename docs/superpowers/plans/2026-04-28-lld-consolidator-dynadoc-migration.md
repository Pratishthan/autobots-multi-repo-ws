# Migrate `lld_consolidator` to dynadoc — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace MER Designer's LLM-driven `lld_consolidator` agent with a deterministic Python service that uses `dynadoc.render_document("lld", ...)`.

**Architecture:** A new pure-Python service `consolidate_lld()` in `domains/designer/services/lld_consolidator.py` reads `lld_header.json`, stamps `lastUpdated = today`, calls `dynadoc.render_document("lld", load_json=mer_load_json, strict=False)` against a per-domain `dynadoc.yaml` manifest with 13 Jinja templates, and writes the resulting Markdown via `mer_write_file_tool`. A thin `consolidate_lld_tool` wraps the service and replaces the deleted `lld_consolidator` agent on the coordinator's tool list.

**Tech Stack:** Python 3.12, `autobots-devtools-shared-lib >= 0.7.0` (`dynadoc`), Jinja2, pytest, ruff, pyright.

**Spec:** `docs/superpowers/specs/2026-04-28-lld-consolidator-dynadoc-migration-design.md`

**Repo root:** `autobots-agents-mer/` (paths below are repo-relative unless prefixed).

**Test layout convention:** This repo organizes tests as `tests/unit/domains/<domain>/...` and `tests/integration/domains/<domain>/...`. Spec §10 listed them under `tests/{unit,integration}/designer/...` for brevity — use the actual repo layout.

---

## File Structure

**New files (under `autobots-agents-mer/`):**

| Path | Responsibility |
|---|---|
| `agent_configs/designer/dynadoc.yaml` | Manifest binding the `lld` document tree to JSON inputs and templates |
| `agent_configs/designer/templates/lld.md.j2` | Top-level shell concatenating section fragments |
| `agent_configs/designer/templates/header.md.j2` | Document-header table from `lld_header.json` |
| `agent_configs/designer/templates/background.md.j2` | Section 1 — Background & Scope |
| `agent_configs/designer/templates/data_section.md.j2` | Composite wrapper for Sections 2 + 3 |
| `agent_configs/designer/templates/data_models.md.j2` | Section 2 — Data Models |
| `agent_configs/designer/templates/enumerations.md.j2` | Section 3 — Enumerations |
| `agent_configs/designer/templates/services.md.j2` | Section 4 — Service Definitions |
| `agent_configs/designer/templates/lpus.md.j2` | Section 5 — Logical Processing Units |
| `agent_configs/designer/templates/data_access.md.j2` | Section 7 — Data Access |
| `agent_configs/designer/templates/errors.md.j2` | Section 9 — Error Definitions |
| `agent_configs/designer/templates/revision_history.md.j2` | Section 13 — Revision History |
| `src/autobots_agents_mer/domains/designer/services/__init__.py` | Package marker |
| `src/autobots_agents_mer/domains/designer/services/lld_consolidator.py` | `consolidate_lld()` service + `ConsolidateResult` dataclass |
| `tests/unit/domains/designer/__init__.py` | Test package marker (if absent) |
| `tests/unit/domains/designer/services/__init__.py` | Test package marker |
| `tests/unit/domains/designer/services/test_lld_consolidator.py` | Unit tests for service + per-template render |
| `tests/integration/domains/designer/__init__.py` | Test package marker (if absent) |
| `tests/integration/domains/designer/test_lld_consolidator.py` | Golden integration test from §9 |
| `tests/integration/domains/designer/fixtures/lld/<JIRA>/*.json` | Reference JSON inputs for the golden test |
| `tests/integration/domains/designer/fixtures/lld/<JIRA>/expected.md` | Reference rendered LLD for the golden test |

**Modified files:**

| Path | Change |
|---|---|
| `pyproject.toml` | Bump `autobots-devtools-shared-lib` constraint to `>= 0.7.0` |
| `agent_configs/designer/agents.yaml` | Delete `lld_consolidator:` entry; add `consolidate_lld_tool` to `coordinator.tools` |
| `agent_configs/designer/prompts/coordinator.md` | Add a single instruction line: when the user asks to assemble/finalize the LLD, call `consolidate_lld_tool`, then offer to call `push_generated_and_raise_pull_request_tool` |
| `src/autobots_agents_mer/domains/designer/tools/designer_tools.py` | Define `consolidate_lld_tool` and add it to `register_designer_tools()` |

**Deleted files:**

| Path | Reason |
|---|---|
| `agent_configs/designer/prompts/lld_consolidator.md` | Agent removed |

---

## Conventions used throughout the plan

- All shell paths and `git add` paths are **relative to `autobots-agents-mer/`** unless prefixed with `../` (workspace-root). Run commands from `autobots-agents-mer/`.
- Activate the shared venv first: `source ../.venv/bin/activate`.
- Run tests via `make test-one TEST=<path>::<name>` (see `CLAUDE.md`).
- Commit from inside `autobots-agents-mer/` (pre-commit hooks live per repo).
- Each task ends with a commit.

---

## Task 1: Bump `autobots-devtools-shared-lib` to ≥ 0.7.0

**Files:**
- Modify: `autobots-agents-mer/pyproject.toml`

- [ ] **Step 1: Inspect the current constraint**

Run from `autobots-agents-mer/`:
```bash
grep -n "autobots-devtools-shared-lib" pyproject.toml
```
Expected: a line under `[tool.poetry.dependencies]` like
```
autobots-devtools-shared-lib = { version = "^0.x.0", develop = true, path = "../autobots-devtools-shared-lib" }
```

- [ ] **Step 2: Bump the version constraint**

Edit `pyproject.toml` and change the `version` field of that dependency to `">=0.7.0"` (keep the `develop = true` and `path` keys exactly as-is). Result line should look like:

```toml
autobots-devtools-shared-lib = { version = ">=0.7.0", develop = true, path = "../autobots-devtools-shared-lib" }
```

- [ ] **Step 3: Refresh the lockfile and verify import**

Run:
```bash
poetry lock --no-update && poetry install --extras dev
../.venv/bin/python -c "from autobots_devtools_shared_lib.dynadoc import render_document; print(render_document.__module__)"
```
Expected: prints `autobots_devtools_shared_lib.dynadoc.engine`. No errors.

- [ ] **Step 4: Commit**

```bash
git add pyproject.toml poetry.lock
git commit -m "chore(mer): require shared-lib >= 0.7.0 for dynadoc"
```

---

## Task 2: Create the dynadoc manifest

**Files:**
- Create: `autobots-agents-mer/agent_configs/designer/dynadoc.yaml`
- Test: `autobots-agents-mer/tests/unit/domains/designer/services/test_lld_consolidator.py` (new file — first test added here)

- [ ] **Step 1: Create the test directories and `__init__.py` markers**

```bash
mkdir -p tests/unit/domains/designer/services
touch tests/unit/domains/designer/__init__.py
touch tests/unit/domains/designer/services/__init__.py
```

- [ ] **Step 2: Write a failing test that loads and validates the manifest**

Create `tests/unit/domains/designer/services/test_lld_consolidator.py`:

```python
# ABOUTME: Unit tests for the deterministic dynadoc-backed LLD consolidator service.

import os
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[5]
DESIGNER_CONFIG_DIR = REPO_ROOT / "agent_configs" / "designer"


@pytest.fixture(autouse=True)
def _designer_config_root(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("DYNAGENT_CONFIG_ROOT_DIR", str(DESIGNER_CONFIG_DIR))


def test_dynadoc_manifest_loads_and_defines_lld_document() -> None:
    from autobots_devtools_shared_lib.dynadoc.manifest import parse_manifest
    from autobots_devtools_shared_lib.dynagent.agents.agent_config_utils import (
        load_render_manifest,
    )

    raw = load_render_manifest()
    documents = parse_manifest(raw)

    assert "lld" in documents
    lld = documents["lld"]
    # Top-level is composite with the 8 expected sections in this exact order.
    assert [c.name for c in lld.children] == [
        "header",
        "background",
        "data",
        "services",
        "lpus",
        "data_access",
        "errors",
        "revision",
    ]
    # `data` is a composite with two leaves over the same JSON.
    data_node = next(c for c in lld.children if c.name == "data")
    assert [c.name for c in data_node.children] == ["models", "enums"]
```

> Note: `parse_manifest` returns dataclasses whose composite/leaf children are exposed as a list preserving manifest insertion order. If the actual API names differ (e.g. `documents["lld"].children_by_name`), adapt the assertions to call sites that match `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/dynadoc/manifest.py`. Do not change the assertion intent — order and names must hold.

- [ ] **Step 3: Run the test and confirm it fails**

```bash
make test-one TEST=tests/unit/domains/designer/services/test_lld_consolidator.py::test_dynadoc_manifest_loads_and_defines_lld_document
```
Expected: FAIL with `FileNotFoundError` or similar — `dynadoc.yaml` does not exist yet.

- [ ] **Step 4: Create the manifest**

Create `agent_configs/designer/dynadoc.yaml`:

```yaml
# ABOUTME: dynadoc render manifest for the Designer LLD document.

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

- [ ] **Step 5: Re-run the test**

```bash
make test-one TEST=tests/unit/domains/designer/services/test_lld_consolidator.py::test_dynadoc_manifest_loads_and_defines_lld_document
```
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add agent_configs/designer/dynadoc.yaml tests/unit/domains/designer
git commit -m "feat(designer): add dynadoc manifest binding lld document tree"
```

---

## Task 3: Service skeleton — `consolidate_lld` (slug + date stamp + render call)

This task sets up the service and tests slug derivation, date stamping, and the render-and-write contract. Templates in this task can be temporary stubs (every template just emits the node name); real templates land in Tasks 5–12.

**Files:**
- Create: `src/autobots_agents_mer/domains/designer/services/__init__.py`
- Create: `src/autobots_agents_mer/domains/designer/services/lld_consolidator.py`
- Create temporary stub templates: `agent_configs/designer/templates/{lld,header,background,data_section,data_models,enumerations,services,lpus,data_access,errors,revision_history}.md.j2`
- Test: `tests/unit/domains/designer/services/test_lld_consolidator.py` (extend)

- [ ] **Step 1: Create the services package**

```bash
mkdir -p src/autobots_agents_mer/domains/designer/services
touch src/autobots_agents_mer/domains/designer/services/__init__.py
```

Add to `__init__.py`:

```python
# ABOUTME: Designer domain services package.
```

- [ ] **Step 2: Create stub templates so dynadoc renders cleanly during tests**

```bash
mkdir -p agent_configs/designer/templates
```

Create each of the following files with the listed content. The stubs let the engine render — Tasks 5–12 replace them.

`templates/lld.md.j2`:
```jinja
{{ sections.header }}

{{ sections.background }}

{{ sections.data }}

{{ sections.services }}

{{ sections.lpus }}

{{ sections.data_access }}

{{ sections.errors }}

{{ sections.revision }}
```

`templates/data_section.md.j2`:
```jinja
{{ sections.models }}

{{ sections.enums }}
```

The remaining nine leaf templates are intentionally *empty stubs* for now (size 0). Create them so the loader resolves:

```bash
for f in header background data_models enumerations services lpus data_access errors revision_history; do
  : > "agent_configs/designer/templates/${f}.md.j2"
done
```

- [ ] **Step 3: Write failing tests for slug, date stamp, and render-and-write**

Append to `tests/unit/domains/designer/services/test_lld_consolidator.py`:

```python
import datetime as dt
import json
from typing import Any
from unittest.mock import patch


def test_slugify_business_name_uses_lld_header_feature_name() -> None:
    from autobots_agents_mer.domains.designer.services.lld_consolidator import slugify

    assert slugify("Payment Limit") == "payment-limit"
    assert slugify("Customer Onboarding 2.0") == "customer-onboarding-2-0"
    assert slugify("  Multi   Space   ") == "multi-space"


def test_consolidate_lld_stamps_today_writes_header_and_writes_doc(monkeypatch: pytest.MonkeyPatch) -> None:
    from autobots_agents_mer.domains.designer.services import lld_consolidator as svc

    state: dict[str, Any] = {
        "user_name": "alice",
        "jira_number": "FBP-1234",
        "repo_name": "fbp-app",
    }

    today = dt.date(2026, 5, 1)

    class _FakeDate(dt.date):
        @classmethod
        def today(cls) -> "_FakeDate":
            return cls(today.year, today.month, today.day)

    monkeypatch.setattr(svc.dt, "date", _FakeDate)

    header_initial = {
        "ticket": "FBP-1234",
        "featureName": "Payment Limit",
        "version": "1.0",
        "lastUpdated": "1900-01-01",
    }

    written: dict[str, str] = {}

    def fake_read(file_name: str, state: dict[str, Any]) -> str:
        if file_name == "docs/FeatureLLD/FBP-1234/lld_header.json":
            return json.dumps(header_initial)
        raise FileNotFoundError(file_name)

    def fake_write(file_name: str, content: str, state: dict[str, Any]) -> str:
        written[file_name] = content
        return "ok"

    monkeypatch.setattr(svc, "mer_read_file", fake_read)
    monkeypatch.setattr(svc, "mer_write_file", fake_write)

    result = svc.consolidate_lld(state)

    # Header was rewritten with stamped lastUpdated.
    header_path = "docs/FeatureLLD/FBP-1234/lld_header.json"
    assert header_path in written
    assert json.loads(written[header_path])["lastUpdated"] == "2026-05-01"

    # LLD path uses slug from featureName.
    expected_path = "docs/FeatureLLD/FBP-1234/FBP-1234-payment-limit-LLD.md"
    assert result.path == expected_path
    assert expected_path in written
    assert isinstance(result.md, str) and len(result.md) > 0
    # Lenient mode is in use — errors list exists (most JSONs absent in this test).
    assert isinstance(result.errors, list)


def test_consolidate_lld_business_name_override_skips_slug_derivation(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from autobots_agents_mer.domains.designer.services import lld_consolidator as svc

    state: dict[str, Any] = {
        "user_name": "alice",
        "jira_number": "FBP-1234",
        "repo_name": "fbp-app",
    }
    monkeypatch.setattr(
        svc, "mer_read_file", lambda *_args, **_kw: json.dumps({"featureName": "ignored"})
    )
    written: dict[str, str] = {}
    monkeypatch.setattr(
        svc,
        "mer_write_file",
        lambda f, c, state: written.setdefault(f, c) or "ok",
    )

    result = svc.consolidate_lld(state, business_name="Custom Override")
    assert result.path == "docs/FeatureLLD/FBP-1234/FBP-1234-custom-override-LLD.md"


def test_consolidate_lld_raises_when_state_missing_required_fields() -> None:
    from autobots_agents_mer.domains.designer.services.lld_consolidator import consolidate_lld

    with pytest.raises(ValueError, match="jira_number"):
        consolidate_lld({"user_name": "alice", "repo_name": "fbp-app"})
```

- [ ] **Step 4: Run the new tests to confirm they fail**

```bash
make test-one TEST=tests/unit/domains/designer/services/test_lld_consolidator.py
```
Expected: FAIL with `ModuleNotFoundError` or `ImportError` for `lld_consolidator`.

- [ ] **Step 5: Implement `lld_consolidator.py`**

Create `src/autobots_agents_mer/domains/designer/services/lld_consolidator.py`:

```python
# ABOUTME: Deterministic LLD consolidator — renders dynadoc("lld") and writes the MD doc.

from __future__ import annotations

import datetime as dt
import json
import re
from dataclasses import dataclass, field
from typing import Any, Mapping

from autobots_devtools_shared_lib.dynadoc import RenderError, render_document

from autobots_agents_mer.common.utils.file_service_utils import (
    mer_read_file,
    mer_write_file,
)

WORKSPACE_LLD_DIR_TEMPLATE = "docs/FeatureLLD/{jira_number}"
HEADER_FILENAME = "lld_header.json"


@dataclass
class ConsolidateResult:
    path: str
    md: str
    errors: list[dict[str, Any]] = field(default_factory=list)


def slugify(value: str) -> str:
    """Lowercase, replace non-alphanumerics with '-', collapse and trim."""
    lowered = value.strip().lower()
    replaced = re.sub(r"[^a-z0-9]+", "-", lowered)
    return replaced.strip("-")


def _require(state: Mapping[str, Any], key: str) -> str:
    value = state.get(key)
    if not isinstance(value, str) or not value:
        raise ValueError(f"MerState is missing required field: {key}")
    return value


def _serialize_errors(errors: list[RenderError]) -> list[dict[str, Any]]:
    return [
        {"node_path": e.node_path, "kind": e.kind, "message": e.message}
        for e in errors
    ]


def consolidate_lld(
    state: Mapping[str, Any],
    business_name: str | None = None,
) -> ConsolidateResult:
    """Render dynadoc("lld") and write the resulting MD into the workspace.

    Steps:
      1. Validate required state fields (jira_number, user_name, repo_name).
      2. Read lld_header.json from workspace.
      3. Stamp lastUpdated = today (ISO date) and write the header back.
      4. Render dynadoc("lld") with strict=False.
      5. Write the rendered MD to docs/FeatureLLD/<JIRA>/<JIRA>-<slug>-LLD.md.
      6. Return ConsolidateResult.
    """
    jira_number = _require(state, "jira_number")
    _require(state, "user_name")
    _require(state, "repo_name")

    workspace_dir = WORKSPACE_LLD_DIR_TEMPLATE.format(jira_number=jira_number)
    header_path = f"{workspace_dir}/{HEADER_FILENAME}"

    header_raw = mer_read_file(header_path, state=state)
    header = json.loads(header_raw)
    header["lastUpdated"] = dt.date.today().isoformat()
    mer_write_file(header_path, json.dumps(header, indent=2), state=state)

    feature_name = (
        business_name if business_name is not None else header.get("featureName", jira_number)
    )
    slug = slugify(feature_name)

    def _load_json(rel_path: str) -> dict[str, Any]:
        # rel_path is workspace-relative to docs/FeatureLLD/<JIRA>/.
        body = mer_read_file(f"{workspace_dir}/{rel_path}", state=state)
        return json.loads(body)

    result = render_document("lld", load_json=_load_json, strict=False)

    out_path = f"{workspace_dir}/{jira_number}-{slug}-LLD.md"
    mer_write_file(out_path, result.md, state=state)

    return ConsolidateResult(
        path=out_path,
        md=result.md,
        errors=_serialize_errors(result.errors),
    )
```

- [ ] **Step 6: Run the tests to confirm pass**

```bash
make test-one TEST=tests/unit/domains/designer/services/test_lld_consolidator.py
```
Expected: PASS for all four tests.

> If `_load_json` raises `FileNotFoundError` from missing JSONs, dynadoc should append `RenderError(kind="missing_json", ...)` rather than raise (because `strict=False`). Verify the engine surfaces the underlying `FileNotFoundError` correctly — if not, wrap the loader to catch and re-raise `FileNotFoundError` so dynadoc's strict-mode handler triggers. The shared-lib spec §8 mandates this behavior.

- [ ] **Step 7: Run lint / format / type-check on changed files**

```bash
make format && make lint && make type-check
```
Expected: clean.

- [ ] **Step 8: Commit**

```bash
git add src/autobots_agents_mer/domains/designer/services agent_configs/designer/templates tests/unit/domains/designer/services/test_lld_consolidator.py
git commit -m "feat(designer): add consolidate_lld service backed by dynadoc"
```

---

## Task 4: Tool wrapper + register in `register_designer_tools()`

**Files:**
- Modify: `src/autobots_agents_mer/domains/designer/tools/designer_tools.py`
- Test: `tests/unit/domains/designer/services/test_lld_consolidator.py` (extend)

- [ ] **Step 1: Write a failing test for the tool wrapper**

Append to the test module:

```python
def test_consolidate_lld_tool_returns_path_and_errors(monkeypatch: pytest.MonkeyPatch) -> None:
    from autobots_agents_mer.domains.designer.services import lld_consolidator as svc
    from autobots_agents_mer.domains.designer.tools.designer_tools import consolidate_lld_tool

    fake_result = svc.ConsolidateResult(path="some/path-LLD.md", md="rendered", errors=[])

    monkeypatch.setattr(svc, "consolidate_lld", lambda state, business_name=None: fake_result)

    class _Runtime:
        state = {"user_name": "a", "jira_number": "J", "repo_name": "r"}

    out = consolidate_lld_tool.invoke({"runtime": _Runtime(), "business_name": None})
    assert out == {"path": "some/path-LLD.md", "errors": []}


def test_register_designer_tools_includes_consolidate_lld_tool() -> None:
    from autobots_devtools_shared_lib.dynagent import _usecase_tools_registry  # type: ignore[attr-defined]

    from autobots_agents_mer.domains.designer.tools.designer_tools import (
        consolidate_lld_tool,
        register_designer_tools,
    )

    register_designer_tools()
    assert any(t is consolidate_lld_tool for t in _usecase_tools_registry())
```

> If shared-lib does not expose `_usecase_tools_registry`, replace with whatever public/test inspector it offers. As a fallback, assert that `consolidate_lld_tool` is one of the tools passed to `register_usecase_tools` by patching it and capturing the call.

A safer, dependency-free version of the second test using `monkeypatch`:

```python
def test_register_designer_tools_includes_consolidate_lld_tool(monkeypatch: pytest.MonkeyPatch) -> None:
    from autobots_agents_mer.domains.designer.tools import designer_tools

    captured: list[Any] = []

    def fake_register(tools: list[Any]) -> None:
        captured.extend(tools)

    monkeypatch.setattr(designer_tools, "register_usecase_tools", fake_register)
    designer_tools.register_designer_tools()
    assert designer_tools.consolidate_lld_tool in captured
```

Use the monkeypatch version — it doesn't depend on shared-lib internals.

- [ ] **Step 2: Run the new tests to confirm they fail**

```bash
make test-one TEST=tests/unit/domains/designer/services/test_lld_consolidator.py
```
Expected: FAIL — `consolidate_lld_tool` does not exist yet.

- [ ] **Step 3: Implement the tool and register it**

Edit `src/autobots_agents_mer/domains/designer/tools/designer_tools.py`. Update imports and add the tool below the existing tools registration:

```python
from langchain.tools import ToolRuntime, tool

from autobots_agents_mer.domains.designer.services.lld_consolidator import (
    consolidate_lld,
)


@tool
def consolidate_lld_tool(
    runtime: ToolRuntime[None, MerState],
    business_name: str | None = None,
) -> dict[str, object]:
    """Render and save the consolidated LLD for the current Jira ticket.

    Returns the workspace-relative output path and any non-fatal render errors
    (e.g. sections still pending input JSON).
    """
    result = consolidate_lld(runtime.state, business_name=business_name)
    return {"path": result.path, "errors": result.errors}
```

Then add `consolidate_lld_tool` to the `register_usecase_tools([...])` list inside `register_designer_tools()` (alongside `mer_write_file_tool`, etc.).

- [ ] **Step 4: Run the tests to confirm pass**

```bash
make test-one TEST=tests/unit/domains/designer/services/test_lld_consolidator.py
```
Expected: PASS for all tool-wrapper tests.

- [ ] **Step 5: Quality gates**

```bash
make format && make lint && make type-check
```

- [ ] **Step 6: Commit**

```bash
git add src/autobots_agents_mer/domains/designer/tools/designer_tools.py tests/unit/domains/designer/services/test_lld_consolidator.py
git commit -m "feat(designer): expose consolidate_lld_tool and register it"
```

---

## Tasks 5–12: Implement the leaf templates

Each template task follows the same shape: write a failing render test that fixes the expected MD, implement the Jinja template, run, commit. The expected MD strings come from the `<output-structure>` blocks in `agent_configs/designer/prompts/lld_consolidator.md` (preserved at the time of writing this plan). When in doubt, treat that prompt as the authoritative spec for column headings, ordering, and conditional sub-blocks.

**Shared test scaffolding (add once at top of the test module):**

```python
from autobots_devtools_shared_lib.dynadoc import render_document


def _render_with(load_json: dict[str, Any]) -> str:
    """Render the lld document with an in-memory JSON loader."""
    def _loader(path: str) -> dict[str, Any]:
        if path not in load_json:
            raise FileNotFoundError(path)
        return load_json[path]
    return render_document("lld", load_json=_loader, strict=False).md
```

> Each per-template test below renders the *full* document with only the relevant JSON populated. Other sections fall back to the `> _Section pending: <node_path>_` placeholder under lenient mode — that is fine; assertions slice out the section under test.

---

### Task 5: `header.md.j2`

**Files:**
- Modify: `agent_configs/designer/templates/header.md.j2`
- Test: `tests/unit/domains/designer/services/test_lld_consolidator.py`

- [ ] **Step 1: Write the failing test**

```python
def test_header_template_renders_document_header_table() -> None:
    md = _render_with({
        "lld_header.json": {
            "ticket": "FBP-1234",
            "featureName": "Payment Limit",
            "author": "alice",
            "reviewers": ["bob", "carol"],
            "status": "Draft",
            "version": "1.0",
            "lastUpdated": "2026-05-01",
            "repository": "fbp-app",
            "domain": "payments",
        }
    })
    assert "# FBP-1234 — Payment Limit Low-Level Design" in md
    assert "| Ticket        | FBP-1234 |" in md
    assert "| Author        | alice |" in md
    assert "| Reviewers     | bob, carol |" in md
    assert "| Status        | Draft |" in md
    assert "| Version       | 1.0 |" in md
    assert "| Last Updated  | 2026-05-01 |" in md
    assert "| Repository    | fbp-app |" in md
    assert "| Domain        | payments |" in md


def test_header_template_uses_em_dash_for_missing_optional_fields() -> None:
    md = _render_with({
        "lld_header.json": {
            "ticket": "FBP-1",
            "featureName": "X",
            "repository": "r",
            "domain": "d",
        }
    })
    assert "| Author        | — |" in md
    assert "| Reviewers     |  |" in md or "| Reviewers     | — |" in md
    assert "| Status        | Draft |" in md
    assert "| Version       | 1.0 |" in md
    assert "| Last Updated  | — |" in md
```

- [ ] **Step 2: Run — confirm fail**

```bash
make test-one TEST=tests/unit/domains/designer/services/test_lld_consolidator.py::test_header_template_renders_document_header_table
```
Expected: FAIL — heading missing (template is empty).

- [ ] **Step 3: Implement `header.md.j2`**

```jinja
# {{ ticket }} — {{ featureName }} Low-Level Design

| Field         | Value |
| ------------- | ----- |
| Ticket        | {{ ticket }} |
| Author        | {{ author or "—" }} |
| Reviewers     | {{ reviewers | default([]) | join(", ") }} |
| Status        | {{ status or "Draft" }} |
| Version       | {{ version or "1.0" }} |
| Last Updated  | {{ lastUpdated or "—" }} |
| Repository    | {{ repository }} |
| Domain        | {{ domain }} |
```

- [ ] **Step 4: Run — confirm pass**

```bash
make test-one TEST=tests/unit/domains/designer/services/test_lld_consolidator.py::test_header_template_renders_document_header_table
make test-one TEST=tests/unit/domains/designer/services/test_lld_consolidator.py::test_header_template_uses_em_dash_for_missing_optional_fields
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add agent_configs/designer/templates/header.md.j2 tests/unit/domains/designer/services/test_lld_consolidator.py
git commit -m "feat(designer): implement lld header template"
```

---

### Task 6: `background.md.j2`

**Files:**
- Modify: `agent_configs/designer/templates/background.md.j2`
- Test: `tests/unit/domains/designer/services/test_lld_consolidator.py`

- [ ] **Step 1: Write the failing test**

```python
def test_background_renders_required_subsections_and_omits_empty_optional_arrays() -> None:
    md = _render_with({
        "background_and_scope.json": {
            "purpose": "Limit payments to safe ranges.",
            "functionalOverview": "Validates each transfer.",
            "inScope": ["Sync limits", "Async notifications"],
            "outOfScope": [],
            "assumptions": [],
            "dependencies": [
                {"name": "AccountSvc", "type": "service", "owner": "core",
                 "status": "active", "notes": "—"},
            ],
            "references": [
                {"refNumber": "R1", "type": "Jira", "linkOrLocation": "FBP-1234"},
            ],
        }
    })
    assert "# 1. Background & Scope" in md
    assert "## 1.1 Purpose\nLimit payments to safe ranges." in md
    assert "## 1.2 Functional Overview\nValidates each transfer." in md
    assert "## 1.3 In Scope\n- Sync limits\n- Async notifications" in md
    # Optional empty arrays: subsection is omitted entirely.
    assert "## 1.4 Out of Scope" not in md
    assert "## 1.5 Assumptions" not in md
    assert "## 1.6 Dependencies" in md
    assert "| AccountSvc | service | core | active | — |" in md
    assert "## 1.7 References" in md
    assert "| R1 | Jira | FBP-1234 |" in md
```

- [ ] **Step 2: Run — confirm fail.** Run command shape as above.

- [ ] **Step 3: Implement `background.md.j2`**

```jinja
# 1. Background & Scope

## 1.1 Purpose
{{ purpose }}

## 1.2 Functional Overview
{{ functionalOverview }}

## 1.3 In Scope
{% for item in inScope -%}
- {{ item }}
{% endfor %}
{%- if outOfScope %}
## 1.4 Out of Scope
{% for item in outOfScope -%}
- {{ item }}
{% endfor %}
{%- endif %}
{%- if assumptions %}
## 1.5 Assumptions
{% for item in assumptions -%}
- {{ item }}
{% endfor %}
{%- endif %}

## 1.6 Dependencies
| Dependency | Type | Owner | Status | Notes |
| ---------- | ---- | ----- | ------ | ----- |
{% for d in dependencies -%}
| {{ d.name }} | {{ d.type }} | {{ d.owner }} | {{ d.status }} | {{ d.notes or "—" }} |
{% endfor %}

## 1.7 References
| Ref # | Type | Link / Location |
| ----- | ---- | --------------- |
{% for r in references -%}
| {{ r.refNumber }} | {{ r.type }} | {{ r.linkOrLocation }} |
{% endfor %}
```

- [ ] **Step 4: Run — confirm pass.**

- [ ] **Step 5: Commit**

```bash
git add agent_configs/designer/templates/background.md.j2 tests/unit/domains/designer/services/test_lld_consolidator.py
git commit -m "feat(designer): implement background_and_scope template"
```

---

### Task 7: `data_section.md.j2` + `data_models.md.j2` + `enumerations.md.j2`

The composite `data` node in the manifest renders models then enumerations in order. Implement all three together.

**Files:**
- Modify: `agent_configs/designer/templates/data_section.md.j2` (already exists from Task 3 — confirm content)
- Modify: `agent_configs/designer/templates/data_models.md.j2`
- Modify: `agent_configs/designer/templates/enumerations.md.j2`
- Test: `tests/unit/domains/designer/services/test_lld_consolidator.py`

- [ ] **Step 1: Write the failing tests**

```python
def test_data_models_template_renders_models_with_schema_and_business_metadata() -> None:
    md = _render_with({
        "data_models.json": {
            "dataModels": [
                {
                    "dataModelName": "Account",
                    "type": "Entity",
                    "isNew": True,
                    "parent": None,
                    "dataModelTypeProperties": {"Entity": {"primaryKeyStrategy": "uuid"}},
                    "fields": [
                        {
                            "name": "id",
                            "dataType": "string",
                            "mandatory": "Y",
                            "defaultValue": None,
                            "description": "Account id",
                            "businessName": "Account ID",
                            "businessKey": "Y",
                            "validations": "—",
                        }
                    ],
                    "domainExtension": {"fbp": {"idGeneratorType": "UUID", "skipAddIDColumn": False}},
                }
            ]
        }
    })
    assert "# 2. Data Models" in md
    assert "## 2.1 `Account`" in md
    assert "| primaryKeyStrategy   | uuid |" in md
    assert "### Structure — Schema" in md
    assert "| id | string | Y | — | Account id |" in md
    assert "### Structure — Business Metadata" in md
    assert "| id | Account ID | Y | — |" in md
    assert "### Domain Extensions — FBP" in md
    assert "| idGeneratorType       | UUID |" in md


def test_data_models_template_omits_fbp_block_when_absent() -> None:
    md = _render_with({
        "data_models.json": {
            "dataModels": [
                {
                    "dataModelName": "X",
                    "type": "Entity",
                    "isNew": False,
                    "parent": None,
                    "dataModelTypeProperties": {},
                    "fields": [],
                }
            ]
        }
    })
    assert "## 2.1 `X`" in md
    assert "### Domain Extensions — FBP" not in md


def test_enumerations_template_renders_section_when_enumerations_present() -> None:
    md = _render_with({
        "data_models.json": {
            "dataModels": [],
            "enumerations": [
                {"name": "Currency", "dataType": "string", "values": ["USD", "EUR"], "description": "ISO 4217"},
            ],
        }
    })
    assert "# 3. Enumerations" in md
    assert "| Currency | string | USD, EUR | ISO 4217 |" in md


def test_enumerations_template_emits_empty_fragment_when_enumerations_missing() -> None:
    md = _render_with({"data_models.json": {"dataModels": []}})
    assert "# 3. Enumerations" not in md
```

- [ ] **Step 2: Run — confirm fail.**

- [ ] **Step 3: Implement the templates**

`data_section.md.j2` (already created in Task 3 stub — keep exactly):
```jinja
{{ sections.models }}

{{ sections.enums }}
```

`data_models.md.j2`:
```jinja
# 2. Data Models
{% for model in dataModels %}
## 2.{{ loop.index }} `{{ model.dataModelName }}`

### Properties
| Property             | Value |
| -------------------- | ----- |
| type                 | {{ model.type }} |
| isNew                | {{ model.isNew }} |
| parent               | {{ model.parent or "—" }} |
| primaryKeyStrategy   | {{ (model.dataModelTypeProperties.Entity.primaryKeyStrategy if model.dataModelTypeProperties and model.dataModelTypeProperties.Entity else None) or "—" }} |

### Structure — Schema
| Column Name | Data Type | Mandatory [Y/N] | Default Value | Description |
| ----------- | --------- | ---------------- | ------------- | ----------- |
{% for f in model.fields -%}
| {{ f.name }} | {{ f.dataType }} | {{ f.mandatory }} | {{ f.defaultValue or "—" }} | {{ f.description }} |
{% endfor %}

### Structure — Business Metadata
| Column Name | Business Name | Business Key [Y/N] | Validations |
| ----------- | ------------- | ------------------- | ----------- |
{% for f in model.fields -%}
| {{ f.name }} | {{ f.businessName }} | {{ f.businessKey or "N" }} | {{ f.validations or "—" }} |
{% endfor %}
{% if model.domainExtension and model.domainExtension.fbp %}
### Domain Extensions — FBP
| Property              | Value |
| --------------------- | ----- |
| idGeneratorType       | {{ model.domainExtension.fbp.idGeneratorType }} |
| skipAddIDColumn       | {{ model.domainExtension.fbp.skipAddIDColumn }} |
{% endif %}
{% endfor %}
```

`enumerations.md.j2`:
```jinja
{% if enumerations %}
# 3. Enumerations

| name | dataType | values | description |
| ---- | -------- | ------ | ----------- |
{% for e in enumerations -%}
| {{ e.name }} | {{ e.dataType }} | {{ e.values | join(", ") }} | {{ e.description }} |
{% endfor %}
{% endif %}
```

- [ ] **Step 4: Run all four tests — confirm pass.**

- [ ] **Step 5: Commit**

```bash
git add agent_configs/designer/templates/data_section.md.j2 \
        agent_configs/designer/templates/data_models.md.j2 \
        agent_configs/designer/templates/enumerations.md.j2 \
        tests/unit/domains/designer/services/test_lld_consolidator.py
git commit -m "feat(designer): implement data models and enumerations templates"
```

---

### Task 8: `services.md.j2`

**Files:**
- Modify: `agent_configs/designer/templates/services.md.j2`
- Test: `tests/unit/domains/designer/services/test_lld_consolidator.py`

- [ ] **Step 1: Write the failing test**

```python
def test_services_template_renders_identity_io_fbp_and_async_blocks() -> None:
    md = _render_with({
        "service_definitions.json": {
            "services": [
                {
                    "name": "transfer",
                    "domain": "payments",
                    "operationType": "command",
                    "description": "Move funds",
                    "invocationType": "SYNC",
                    "syncProperties": {
                        "parameters": {"path": ["accountId"], "query": ["amount"]}
                    },
                    "asyncProperties": None,
                    "inputDataModel": "TransferReq",
                    "outputDataModel": "TransferRes",
                    "domainExtension": {"fbp": {"enableAudit": True, "engine": "FBP"}},
                },
                {
                    "name": "notify",
                    "domain": "payments",
                    "operationType": "event",
                    "description": "Notify",
                    "invocationType": "ASYNC",
                    "asyncProperties": {
                        "queue": "notify-q",
                        "direction": "OUT",
                        "messageModel": "NotifyMsg",
                        "condition": None,
                    },
                    "inputDataModel": None,
                    "outputDataModel": "NotifyMsg",
                    "domainExtension": {"fbp": {"enableAudit": False, "engine": "FBP"}},
                },
            ]
        }
    })
    assert "# 4. Service Definitions" in md
    assert "### Service Identity" in md
    assert "| transfer | payments | command | Move funds |" in md
    assert "### Service I/O" in md
    assert "| transfer | SYNC | accountId, amount | TransferReq | TransferRes |" in md
    assert "| notify | ASYNC | notify-q | — | NotifyMsg |" in md
    assert "### Domain Extensions — FBP" in md
    assert "| transfer | Y | FBP |" in md
    assert "| notify | N | FBP |" in md
    assert "### Async Properties" in md
    # Only ASYNC services appear in the async block.
    assert "| notify | OUT | notify-q | NotifyMsg | — |" in md
    assert "| transfer |" not in md.split("### Async Properties", 1)[1]
```

- [ ] **Step 2: Run — confirm fail.**

- [ ] **Step 3: Implement `services.md.j2`**

```jinja
# 4. Service Definitions

### Service Identity
| name | domain | operationType | description |
| ---- | ------ | ------------- | ----------- |
{% for s in services -%}
| {{ s.name }} | {{ s.domain }} | {{ s.operationType }} | {{ s.description }} |
{% endfor %}

### Service I/O
| name | invocationType | Parameters | inputDataModel | outputDataModel |
| ---- | --------------- | ---------- | -------------- | --------------- |
{% for s in services -%}
{% if s.invocationType == "SYNC" -%}
{% set params = (s.syncProperties.parameters.path or []) + (s.syncProperties.parameters.query or []) -%}
| {{ s.name }} | SYNC | {{ params | join(", ") }} | {{ s.inputDataModel or "—" }} | {{ s.outputDataModel or "—" }} |
{% else -%}
| {{ s.name }} | ASYNC | {{ s.asyncProperties.queue }} | {{ s.inputDataModel or "—" }} | {{ s.outputDataModel or "—" }} |
{% endif -%}
{% endfor %}

### Domain Extensions — FBP
| name | enableAudit | engine |
| ---- | ----------- | ------ |
{% for s in services -%}
| {{ s.name }} | {{ "Y" if s.domainExtension.fbp.enableAudit else "N" }} | {{ s.domainExtension.fbp.engine }} |
{% endfor %}
{% set async_services = services | selectattr("invocationType", "equalto", "ASYNC") | list %}
{% if async_services %}
### Async Properties
| name | direction | queue | messageModel | condition |
| ---- | --------- | ----- | ------------ | --------- |
{% for s in async_services -%}
| {{ s.name }} | {{ s.asyncProperties.direction }} | {{ s.asyncProperties.queue }} | {{ s.asyncProperties.messageModel or "—" }} | {{ s.asyncProperties.condition or "—" }} |
{% endfor %}
{% endif %}
```

- [ ] **Step 4: Run — confirm pass.**

- [ ] **Step 5: Commit**

```bash
git add agent_configs/designer/templates/services.md.j2 tests/unit/domains/designer/services/test_lld_consolidator.py
git commit -m "feat(designer): implement service definitions template"
```

---

### Task 9: `lpus.md.j2`

**Files:**
- Modify: `agent_configs/designer/templates/lpus.md.j2`
- Test: `tests/unit/domains/designer/services/test_lld_consolidator.py`

- [ ] **Step 1: Write the failing test**

```python
def test_lpus_template_renders_table_with_business_logic_as_br_separated_list() -> None:
    md = _render_with({
        "logical_processing_units.json": {
            "logicalProcessingUnits": [
                {
                    "name": "ValidateLimit",
                    "type": "Standard",
                    "subType": "Validation",
                    "input": [{"model": "Transfer", "fields": ["amount"]}],
                    "output": [{"model": "Transfer", "fields": ["isValid"]}],
                    "referenced": [{"model": "Account", "fields": ["balance"]}],
                    "businessLogic": ["Check balance", "Reject if exceeds"],
                    "domainExtension": {"fbp": {"behaviourType": "Validation"}},
                }
            ]
        }
    })
    assert "# 5. Logical Processing Units" in md
    assert "| ValidateLimit | Standard | Validation | Transfer: amount | Transfer: isValid | Account: balance | 1. Check balance<br>2. Reject if exceeds |" in md
    assert "### Domain Extensions — FBP (Behaviours)" in md
    assert "**ValidateLimit**" in md
    assert "behaviourType: Validation" in md


def test_lpus_template_omits_fbp_subsection_when_no_unit_has_extension() -> None:
    md = _render_with({
        "logical_processing_units.json": {
            "logicalProcessingUnits": [
                {
                    "name": "X", "type": "Manual", "subType": "Processing",
                    "input": [], "output": [], "referenced": [],
                    "businessLogic": ["Do thing"],
                    "domainExtension": {},
                }
            ]
        }
    })
    assert "### Domain Extensions — FBP (Behaviours)" not in md
```

- [ ] **Step 2: Run — confirm fail.**

- [ ] **Step 3: Implement `lpus.md.j2`**

```jinja
{% macro fmt_models(items) -%}
{% for it in items -%}{{ it.model }}: {{ it.fields | join(", ") }}{% if not loop.last %}; {% endif %}{%- endfor %}
{%- endmacro %}
{% macro fmt_logic(steps) -%}
{% for s in steps -%}{{ loop.index }}. {{ s }}{% if not loop.last %}<br>{% endif %}{%- endfor %}
{%- endmacro %}
# 5. Logical Processing Units

| name | type | subType | input[] | output[] | referenced[] | businessLogic[] |
| ---- | ---- | ------- | ------- | -------- | ------------- | ---------------- |
{% for u in logicalProcessingUnits -%}
| {{ u.name }} | {{ u.type }} | {{ u.subType }} | {{ fmt_models(u.input) }} | {{ fmt_models(u.output) }} | {{ fmt_models(u.referenced) }} | {{ fmt_logic(u.businessLogic) }} |
{% endfor %}

**Type**: Manual / LLM Assisted / Standard / Existing

**Sub-Type**: Enrichment / Validation / External Call / Processing / Persistence / SetDefaults / Transformation / Complete
{% set fbp_units = logicalProcessingUnits | selectattr("domainExtension.fbp") | list %}
{% if fbp_units %}
### Domain Extensions — FBP (Behaviours)
{% for u in fbp_units %}
**{{ u.name }}**
{% for k, v in u.domainExtension.fbp.items() -%}
{{ k }}: {{ v }}
{% endfor %}
{% endfor %}
{% endif %}
```

- [ ] **Step 4: Run — confirm pass.**

- [ ] **Step 5: Commit**

```bash
git add agent_configs/designer/templates/lpus.md.j2 tests/unit/domains/designer/services/test_lld_consolidator.py
git commit -m "feat(designer): implement logical processing units template"
```

---

### Task 10: `data_access.md.j2`

**Files:**
- Modify: `agent_configs/designer/templates/data_access.md.j2`
- Test: `tests/unit/domains/designer/services/test_lld_consolidator.py`

- [ ] **Step 1: Write the failing test**

```python
def test_data_access_template_renders_table_and_optional_fbp_block() -> None:
    md = _render_with({
        "data_accesses.json": {
            "dataAccesses": [
                {
                    "modelName": "Account",
                    "methodName": "findByOwner",
                    "queryFilterLogic": "owner = :owner",
                    "parameters": ["owner"],
                    "returnType": "List<Account>",
                    "domainExtension": {"fbp": {"repository": "AccountRepo"}},
                },
                {
                    "modelName": "Audit",
                    "methodName": "log",
                    "queryFilterLogic": "",
                    "parameters": [],
                    "returnType": "void",
                    "domainExtension": {},
                },
            ]
        }
    })
    assert "# 7. Data Access" in md
    assert "| Account | findByOwner | owner = :owner | owner | List<Account> |" in md
    assert "| Audit | log | — |  | void |" in md
    assert "### Domain Extensions — FBP (Repository Queries)" in md
    assert "Account.findByOwner" in md
    assert "repository: AccountRepo" in md
```

- [ ] **Step 2: Run — confirm fail.**

- [ ] **Step 3: Implement `data_access.md.j2`**

```jinja
# 7. Data Access

| Model Name | Method Name | Query / Filter Logic | Parameters | Return Type |
| ---------- | ----------- | -------------------- | ---------- | ----------- |
{% for d in dataAccesses -%}
| {{ d.modelName }} | {{ d.methodName }} | {{ d.queryFilterLogic or "—" }} | {{ d.parameters | join(", ") }} | {{ d.returnType }} |
{% endfor %}
{% set fbp = dataAccesses | selectattr("domainExtension.fbp") | list %}
{% if fbp %}
### Domain Extensions — FBP (Repository Queries)
{% for d in fbp %}
**{{ d.modelName }}.{{ d.methodName }}**
{% for k, v in d.domainExtension.fbp.items() -%}
{{ k }}: {{ v }}
{% endfor %}
{% endfor %}
{% endif %}
```

- [ ] **Step 4: Run — confirm pass.**

- [ ] **Step 5: Commit**

```bash
git add agent_configs/designer/templates/data_access.md.j2 tests/unit/domains/designer/services/test_lld_consolidator.py
git commit -m "feat(designer): implement data access template"
```

---

### Task 11: `errors.md.j2`

**Files:**
- Modify: `agent_configs/designer/templates/errors.md.j2`
- Test: `tests/unit/domains/designer/services/test_lld_consolidator.py`

- [ ] **Step 1: Write the failing test**

```python
def test_errors_template_renders_section_when_errors_present() -> None:
    md = _render_with({
        "error_definitions.json": {
            "errors": [
                {"code": "E001", "message": "Insufficient funds",
                 "type": "Business", "triggerCondition": "balance < amount",
                 "description": "Reject overdraft"},
            ]
        }
    })
    assert "# 9. Error Definitions" in md
    assert "| E001 | Insufficient funds | Business | balance < amount | Reject overdraft |" in md


def test_errors_template_omits_section_when_errors_empty_or_missing() -> None:
    md = _render_with({"error_definitions.json": {"errors": []}})
    assert "# 9. Error Definitions" not in md
```

- [ ] **Step 2: Run — confirm fail.**

- [ ] **Step 3: Implement `errors.md.j2`**

```jinja
{% if errors %}
# 9. Error Definitions

| Code | Message | Type | Trigger Condition | Description |
| ---- | ------- | ---- | ------------------ | ----------- |
{% for e in errors -%}
| {{ e.code }} | {{ e.message }} | {{ e.type }} | {{ e.triggerCondition }} | {{ e.description }} |
{% endfor %}
{% endif %}
```

- [ ] **Step 4: Run — confirm pass.**

- [ ] **Step 5: Commit**

```bash
git add agent_configs/designer/templates/errors.md.j2 tests/unit/domains/designer/services/test_lld_consolidator.py
git commit -m "feat(designer): implement error definitions template"
```

---

### Task 12: `revision_history.md.j2` + finalize `lld.md.j2`

**Files:**
- Modify: `agent_configs/designer/templates/revision_history.md.j2`
- Modify: `agent_configs/designer/templates/lld.md.j2` (already exists from Task 3 — verify final form)
- Test: `tests/unit/domains/designer/services/test_lld_consolidator.py`

- [ ] **Step 1: Write the failing test**

```python
def test_revision_history_template_renders_single_row_table() -> None:
    md = _render_with({
        "lld_header.json": {
            "ticket": "FBP-1",
            "featureName": "X",
            "repository": "r",
            "domain": "d",
            "version": "1.2",
            "lastUpdated": "2026-05-01",
        }
    })
    assert "# 13. Revision History" in md
    assert "| Version | Date | Author | Changes |" in md
    assert "| 1.2 | 2026-05-01 |  | Initial draft |" in md


def test_lld_top_level_template_emits_sections_in_order() -> None:
    md = _render_with({
        "lld_header.json": {
            "ticket": "T", "featureName": "F", "repository": "r", "domain": "d",
            "version": "1.0", "lastUpdated": "2026-05-01",
        }
    })
    # Ordering: header → background → data → services → lpus → data_access → errors → revision.
    h = md.index("Low-Level Design")
    r = md.index("# 13. Revision History")
    assert h < r
    # Missing sections render as `> _Section pending: lld.<name>_` placeholders in lenient mode.
    for missing in ("lld.background", "lld.data.models", "lld.services", "lld.lpus",
                    "lld.data_access"):
        assert f"_Section pending: {missing}_" in md
```

- [ ] **Step 2: Run — confirm fail.**

- [ ] **Step 3: Implement `revision_history.md.j2`**

```jinja
# 13. Revision History

| Version | Date | Author | Changes |
| ------- | ---- | ------ | ------- |
| {{ version or "1.0" }} | {{ lastUpdated }} | {{ author or "" }} | Initial draft |
```

- [ ] **Step 4: Verify the top-level `lld.md.j2`**

It should already match this from Task 3 — confirm the file contains exactly:

```jinja
{{ sections.header }}

{{ sections.background }}

{{ sections.data }}

{{ sections.services }}

{{ sections.lpus }}

{{ sections.data_access }}

{{ sections.errors }}

{{ sections.revision }}
```

- [ ] **Step 5: Run — confirm pass.**

- [ ] **Step 6: Commit**

```bash
git add agent_configs/designer/templates/revision_history.md.j2 agent_configs/designer/templates/lld.md.j2 tests/unit/domains/designer/services/test_lld_consolidator.py
git commit -m "feat(designer): implement revision history and lld shell templates"
```

---

## Task 13: Wire coordinator — drop the agent, register the tool, update prompt

**Files:**
- Modify: `agent_configs/designer/agents.yaml`
- Modify: `agent_configs/designer/prompts/coordinator.md`
- Delete: `agent_configs/designer/prompts/lld_consolidator.md`
- Test: `tests/unit/domains/designer/services/test_lld_consolidator.py`

- [ ] **Step 1: Write a failing test asserting agents.yaml shape**

```python
def test_agents_yaml_drops_lld_consolidator_and_adds_tool_to_coordinator() -> None:
    import yaml

    raw = (DESIGNER_CONFIG_DIR / "agents.yaml").read_text(encoding="utf-8")
    cfg = yaml.safe_load(raw)
    agents = cfg["agents"]

    assert "lld_consolidator" not in agents
    assert "consolidate_lld_tool" in agents["coordinator"]["tools"]
```

- [ ] **Step 2: Run — confirm fail.**

- [ ] **Step 3: Edit `agents.yaml`**

In `agent_configs/designer/agents.yaml`:

1. Append `consolidate_lld_tool` to the `coordinator.tools` list (immediately after `push_generated_and_raise_pull_request_tool` is fine):

```yaml
  coordinator:
    capabilities:
      - This agent can do this
      - Also this
    prompt: "coordinator"
    tools:
      - get_context_tool
      - set_context_tool
      - update_context_tool
      - create_workspace_tool
      - build_workspace_tool
      - push_generated_and_raise_pull_request_tool
      - consolidate_lld_tool
      - get_agent_list
      - handoff
```

2. Delete the entire `lld_consolidator:` block (the YAML mapping with `prompt: "lld_consolidator"` and its tools list).

- [ ] **Step 4: Update `coordinator.md`**

Append to `agent_configs/designer/prompts/coordinator.md` (under the existing instructions / behaviour section, wherever similar guidance lives — keep one short paragraph):

```markdown
When the user asks to assemble or finalize the LLD, call `consolidate_lld_tool`.
The tool returns `{ "path": <workspace-relative path>, "errors": [...] }`.
After it succeeds, surface the path to the user, list any non-empty `errors` (these
are sections still pending input JSON), and offer to call
`push_generated_and_raise_pull_request_tool` to raise the PR.
```

- [ ] **Step 5: Delete the old prompt file**

```bash
git rm agent_configs/designer/prompts/lld_consolidator.md
```

- [ ] **Step 6: Re-run the test plus the existing unit suite**

```bash
make test-one TEST=tests/unit/domains/designer/services/test_lld_consolidator.py
```
Expected: PASS.

- [ ] **Step 7: Quality gates**

```bash
make format && make lint && make type-check
```

- [ ] **Step 8: Commit**

```bash
git add agent_configs/designer/agents.yaml agent_configs/designer/prompts/coordinator.md
git commit -m "feat(designer): replace lld_consolidator agent with consolidate_lld_tool"
```

---

## Task 14: Golden integration test from a real reference LLD

This task locks in spec §9 — the migration must not silently regress against a real shipped LLD.

**Files:**
- Create: `tests/integration/domains/designer/__init__.py` (if absent)
- Create: `tests/integration/domains/designer/test_lld_consolidator.py`
- Create: `tests/integration/domains/designer/fixtures/lld/<JIRA>/*.json`
- Create: `tests/integration/domains/designer/fixtures/lld/<JIRA>/expected.md`

- [ ] **Step 1: Pick the reference LLD**

Outside of automation: open `docs/FeatureLLD/` in the workspace file server, pick the most recent shipped `<JIRA>-<slug>-LLD.md` whose source JSONs (`lld_header.json`, `background_and_scope.json`, `data_models.json`, `service_definitions.json`, `logical_processing_units.json`, `data_accesses.json`, `error_definitions.json`) are all still present beside it.

Copy that JSON set into `tests/integration/domains/designer/fixtures/lld/<JIRA>/`. Copy the rendered MD into `tests/integration/domains/designer/fixtures/lld/<JIRA>/expected.md`. **Pin `lld_header.lastUpdated` in the JSON fixture** to the same date that appears in the `expected.md` Document Header / Revision History so the date stamp comparison is deterministic.

- [ ] **Step 2: Write the failing golden test**

```python
# ABOUTME: Golden integration test — render dynadoc("lld") against a real LLD fixture.

import datetime as dt
import json
from pathlib import Path
from typing import Any

import pytest

REPO_ROOT = Path(__file__).resolve().parents[5]
DESIGNER_CONFIG_DIR = REPO_ROOT / "agent_configs" / "designer"
FIXTURE_DIR = Path(__file__).parent / "fixtures" / "lld"


def _pick_fixture() -> Path:
    candidates = [p for p in FIXTURE_DIR.iterdir() if p.is_dir()]
    assert candidates, "No fixture directory found under fixtures/lld/"
    return candidates[0]


@pytest.fixture(autouse=True)
def _designer_config_root(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("DYNAGENT_CONFIG_ROOT_DIR", str(DESIGNER_CONFIG_DIR))


def test_golden_lld_renders_byte_identical_to_reference(monkeypatch: pytest.MonkeyPatch) -> None:
    from autobots_agents_mer.domains.designer.services import lld_consolidator as svc

    fixture = _pick_fixture()
    expected_md = (fixture / "expected.md").read_text(encoding="utf-8")
    header = json.loads((fixture / "lld_header.json").read_text(encoding="utf-8"))
    pinned_date = header["lastUpdated"]  # pinned in fixture

    class _PinnedDate(dt.date):
        @classmethod
        def today(cls) -> "_PinnedDate":
            year, month, day = (int(p) for p in pinned_date.split("-"))
            return cls(year, month, day)

    monkeypatch.setattr(svc.dt, "date", _PinnedDate)

    written: dict[str, str] = {}

    def fake_read(file_name: str, state: dict[str, Any]) -> str:
        # Path shape: docs/FeatureLLD/<JIRA>/<file>
        leaf = file_name.rsplit("/", 1)[-1]
        path = fixture / leaf
        if not path.exists():
            raise FileNotFoundError(file_name)
        return path.read_text(encoding="utf-8")

    def fake_write(file_name: str, content: str, state: dict[str, Any]) -> str:
        written[file_name] = content
        return "ok"

    monkeypatch.setattr(svc, "mer_read_file", fake_read)
    monkeypatch.setattr(svc, "mer_write_file", fake_write)

    state = {"user_name": "fixture", "jira_number": fixture.name, "repo_name": "fixture-repo"}
    result = svc.consolidate_lld(state)

    assert result.errors == [], f"Unexpected render errors: {result.errors}"
    assert written[result.path] == expected_md
```

- [ ] **Step 3: Run the test — first run is the validation step**

```bash
make test-one TEST=tests/integration/domains/designer/test_lld_consolidator.py
```
Expected: per spec §9, *every section either matches byte-for-byte, or any divergence is documented and approved in the migration PR review*.

If it fails, inspect the diff:

```bash
diff <(python -c "
import json, datetime as dt
from pathlib import Path
from autobots_agents_mer.domains.designer.services import lld_consolidator as svc
# (call into the test machinery here — or temporarily save result.md from the test)
") tests/integration/domains/designer/fixtures/lld/<JIRA>/expected.md
```

Triage every section. Acceptable resolution paths:
- **Template bug** — fix the template, retest until byte-identical.
- **Reference LLD has a manual edit not reflected in JSON** — record the deviation in the PR description and adjust `expected.md` to match the deterministic render. Spec §9: divergences must be explicitly approved and documented inline.
- **JSON has data the prompt would have ignored** — add the case to the corresponding template task's tests and fix the template.

- [ ] **Step 4: Lock the test in**

Once it passes, the fixture set + `expected.md` are the regression gate going forward. Do not edit them in unrelated PRs.

- [ ] **Step 5: Commit**

```bash
git add tests/integration/domains/designer
git commit -m "test(designer): golden integration test for dynadoc LLD render"
```

---

## Task 15: Final verification

- [ ] **Step 1: Full repo gate**

From `autobots-agents-mer/`:

```bash
make all-checks
```

Expected: PASS for `format-check`, `lint`, `type-check`, `test`.

- [ ] **Step 2: Verify shared-lib hasn't regressed**

From the workspace root:

```bash
cd ..
make lint && make type-check && make test
cd autobots-agents-mer
```

Expected: PASS workspace-wide.

- [ ] **Step 3: Sanity boot the designer server (smoke)**

```bash
DYNAGENT_CONFIG_ROOT_DIR=agent_configs/designer \
  ../.venv/bin/python -c "
from autobots_agents_mer.domains.designer.tools.designer_tools import register_designer_tools
register_designer_tools()
print('designer tools registered')
"
```

Expected: prints `designer tools registered`. No exceptions.

- [ ] **Step 4: Confirm prompt deletion sticks**

```bash
test ! -f agent_configs/designer/prompts/lld_consolidator.md && echo "removed"
```
Expected: prints `removed`.

- [ ] **Step 5: No commit needed for verification.**

If anything failed in Steps 1–3, return to the relevant task above and fix.

---

## Self-Review Notes (already applied while drafting)

- **Spec coverage:** Each section of the spec maps to a task — §5 manifest → Task 2; §6 templates → Tasks 5–12; §7 service & tool → Tasks 3–4; §8 coordinator changes → Task 13; §9 migration & validation → Task 14; §10 file inventory → all tasks; §11 testing → Tasks 3–14.
- **Method-name consistency:** Service is `consolidate_lld`; tool is `consolidate_lld_tool`; result is `ConsolidateResult`; slug helper is `slugify`. All names used identically across tasks.
- **Lenient mode wiring:** Task 3 fixes `strict=False`; placeholder format `_Section pending: <node_path>_` is asserted in Task 12.
- **Path discipline:** All file-server paths are constructed under `docs/FeatureLLD/<JIRA>/` exactly as the existing prompt requires. Output filename is `<JIRA>-<slug>-LLD.md` matching spec §3 row 6.
- **Stub templates:** Task 3 creates stub templates so Tasks 5–12 only ever modify (not create) template files; this keeps each template task's diff minimal and reviewable.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-28-lld-consolidator-dynadoc-migration.md`. Two execution options:

1. **Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
