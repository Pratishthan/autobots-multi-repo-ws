---
name: new-domain
description: Scaffold a new domain in a repo — creates directory structure, boilerplate server/tools/services, agent config, run script, and Makefile target. Usage - /new-domain <repo-name> <domain-name>
disable-model-invocation: true
---

# /new-domain — Scaffold a new domain

Create all the files needed for a new domain in an existing repo.

## Arguments

`$ARGUMENTS` should contain: `<repo-name> <domain-name>`

Example: `/new-domain autobots-agents-jarvis hr`

If arguments are missing, ask the user for the repo name and domain name.

## Steps

1. **Validate** the repo exists in the workspace (one of: autobots-agents-jarvis, autobots-agents-mer, autobots-agents-pay).

2. **Read an existing domain** in that repo to understand the patterns (read one `server.py`, `tools.py`, `services.py` from an existing domain in `src/<package>/domains/`).

3. **Create agent config directory:**
   ```
   <repo>/agent_configs/<domain-name>/
   ├── agents.yaml
   ├── prompts/
   │   └── coordinator.md
   └── schemas/
   ```

   The `agents.yaml` should define a default coordinator agent with `is_default: true`, `handoff`, and `get_agent_list` tools.

4. **Create domain source directory:**
   ```
   <repo>/src/<package>/domains/<domain_name>/
   ├── __init__.py
   ├── server.py      # Chainlit server (copy pattern from existing domain)
   ├── tools.py       # register_<domain>_tools() function with placeholder tool
   └── services.py    # Empty service module
   ```

   - `server.py`: Copy the pattern from an existing domain's server.py, update APP_NAME, port, config root dir, and tool registration call.
   - `tools.py`: Create a `register_<domain>_tools()` function that calls `register_usecase_tools()`.
   - Pick the next available port (check existing `sbin/run_*.sh` scripts for used ports).

5. **Create run script** at `<repo>/sbin/run_<domain_name>.sh` (chmod +x):
   ```bash
   #!/bin/bash
   chainlit run src/<package>/domains/<domain_name>/server.py --port <next-port>
   ```

6. **Add Makefile target** in `<repo>/Makefile`:
   ```makefile
   chainlit-<domain-name>:
   	./sbin/run_<domain_name>.sh
   ```

7. **Report** what was created and what the user needs to do next (set DYNAGENT_CONFIG_ROOT_DIR, implement tools, write prompts).
