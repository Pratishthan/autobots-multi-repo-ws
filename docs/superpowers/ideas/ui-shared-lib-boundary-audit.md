# UI Shared-Lib Boundary Audit

**Date:** 2026-07-05
**Scope:** `autobots-devtools-shared-lib/src/autobots_devtools_shared_lib/dynagent/ui/`
**Purpose:** Audit UI layer against shared-lib boundary policies. Resume from Recommendations.

## Policies (lenses)

1. Shared lib should host all common functionality.
2. Shared lib shouldn't be burdened with use-case-specific functionality (e.g. AMA, Designer).
3. No servers in shared lib — use cases own the servers (using shared lib functions).
4. CopilotKit UI is specifically designed on `create_base_deepagent`.

---

## Part 1 — `ui_utils.py`

### Lens 1 (common functionality) — PASS, with cohesion concern
- Pure formatting helpers are genuinely generic and reusable: `structured_to_markdown` (L36), `format_dict_item` (L76), `_extract_output_type` (L94). No runtime/framework deps.
- **Concern:** module bundles three unrelated concerns behind top-level `import chainlit`/`import requests`:
  - pure formatting (L36–98)
  - file-server upload plumbing (L106–238)
  - Chainlit event streaming (L246–469)
- A consumer wanting only `structured_to_markdown` still drags in `chainlit` + `requests`.

### Lens 2 (no use-case leakage) — PASS
- No imports from `jarvis`/`mer`/`pay`/`designer`/`bro_chat`. All imports resolve to `...shared_lib.common.*` (L20–26, L123). Header comment (L1–2) asserts this and it holds.
- `move_file_tool` references in docstrings (L154, L265) are a convention assumption, not a code dep — acceptable.

### Lens 3 (no servers) — CONCERN (file passes; directory does not)
- File is not a server, but hard-couples UI streaming to a specific file transport:
  ```python
  from ...common.servers.fileserver.config import FileServerConfig  # L123
  file_server_url = f"http://{FileServerConfig.host}:{FileServerConfig.port}"  # L125
  ```
- `common/servers/fileserver/` exists in shared lib — audit separately for a runnable server.
- Upload path (base64 `POST /writeFile`, `temp/` staging, L129–141) is baked in; a use case with different staging (S3/local) can't reuse `stream_agent_events` without adopting this file server.

### Lens 4 (CopilotKit/deepagent) — N/A
- `ui_utils.py` targets Chainlit and takes a generic `CompiledStateGraph` (L247) — agent-construction agnostic. Doesn't touch the deepagent path.
- Reveals a tension: two parallel UI stacks in one `ui/` package — Chainlit (`ui_utils.py`, `default_ui.py`, `rail_stream.py`) vs CopilotKit (`copilotkit_server.py`) — with different agent assumptions.

### Decision (user, 2026-07-05)
- **Lens 1 split + Lens 2 dependency inversion: WILL LIVE WITH for now** (deferred, not rejected).
- Deferred recommendations retained below for later:
  1. Split into `formatting.py` (pure, zero framework deps) / `chainlit_streaming.py` / `file_upload.py`.
  2. Invert file-upload dependency: `stream_agent_events` takes an `upload_handler` callback instead of importing `FileServerConfig` + hard-coding `POST /writeFile`.

---

## Part 2 — `copilotkit_server.py` (audited in depth)

### Context signals (from grep)
- **No use case imports `create_copilotkit_app`** anywhere in `jarvis`/`mer`/`pay`. Only consumer is this file's own `__main__`. → Today, shared lib *is* the server.
- Only other CopilotKit usage is a throwaway spike fixture: `autobots-agents-mer/docs/superpowers/specs/evidence/2026-07-04-ama-agui-spike/`.
- `ATLAS` appears only here (L29) and in `docs/.../2026-07-03-deepagent-engine-parity-design.md` — nowhere else in code.

### Lens 3 (no servers) — VIOLATION
- Runnable server in shared lib:
  ```python
  if __name__ == "__main__":
      import uvicorn
      uvicorn.run(create_copilotkit_app(), host="0.0.0.0", port=8000)  # L82–85
  ```
  Because no use case imports the factory, this `__main__` is the actual entrypoint today — strongest form of the violation.
- Factory itself makes server-ownership decisions that belong to the use case:
  - CORS policy baked into app (L65–72)
  - allowed-origins list + env var (L21–31)
  - host/port (L85), app title (L64)

### Lens 4 (CopilotKit/deepagent) — CONSISTENT (confirms policy)
- L43 `create_base_deepagent(...)`; header L1–2. File correctly embodies lens 4. No violation.

### Lens 2 (use-case leak) — MINOR VIOLATION
- `os.getenv("ATLAS_UI_ORIGINS", ...)` (L29). `ATLAS` is the React frontend product name, present nowhere else in code. Shared lib shouldn't know the frontend is "Atlas."

---

## Recommendations — RESUME HERE

Push server ownership down to the use case. Concretely:

1. **Delete the `__main__`/uvicorn block** (`copilotkit_server.py` L82–85). Shared lib is not an entrypoint.
2. **Demote the factory to a builder.** Either:
   - shared-lib graph builder — `build_deepagent_agui_graph(agent_name, middleware=...)` returning the configured graph + `RailAGUIAgent`; or
   - keep `create_copilotkit_app` but make `allowed_origins`, `path`, `checkpointer` **parameters** — no `os.getenv`, no hard-wired CORS defaults, no `ATLAS_*`.
3. **Use case owns**: FastAPI instantiation, CORS config, the `ATLAS_UI_ORIGINS` env name, port/host, and `uvicorn.run` (e.g. a `jarvis`/`mer` `server.py`).

Net: shared lib exports the deepagent→AG-UI wiring (reusable, deepagent-specific — satisfies lens 4); use case assembles and runs the server (satisfies lens 3).

### Follow-up audit (not yet done)
- `common/servers/fileserver/` — confirm whether it hosts a *runnable* server (lens 3 violation one level up from `ui_utils.py`).
- `default_ui.py`, `rail_stream.py`, `activity_projection.py`, `collapse_system_messages.py` — not yet audited against the four lenses.

### Open offer
- Draft the split: a builder in shared lib + an example `server.py` for the owning use case.
