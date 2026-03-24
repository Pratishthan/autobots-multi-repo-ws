---
name: new-agent
description: Scaffold a new agent within an existing domain — adds YAML config entry, prompt file, optional schema, and tool stub. Usage - /new-agent <repo>/<domain> <agent-name>
disable-model-invocation: true
---

# /new-agent — Scaffold a new agent

Add a new agent to an existing domain's configuration and create its supporting files.

## Arguments

`$ARGUMENTS` should contain: `<repo>/<domain> <agent-name>`

Example: `/new-agent autobots-agents-jarvis/concierge weather-expert`

If arguments are missing, ask the user for: repo name, domain name, and agent name.

## Steps

1. **Locate the domain's agent config** at `<repo>/agent_configs/<domain>/agents.yaml`. Read it to understand existing agents and patterns.

2. **Ask the user:**
   - What does this agent do? (one sentence for the prompt)
   - Does it need an output schema? (structured JSON output)
   - Should it be batch-enabled?
   - What tools should it use? (besides handoff and get_agent_list)

3. **Add agent entry** to `agents.yaml`:
   ```yaml
   <agent_name>:
     prompt: "<agent-name>"
     output_schema: "<agent-name>.json"  # only if user wants structured output
     batch_enabled: false                 # or true if user requested
     tools:
       - "handoff"
       - "get_agent_list"
       # + user-specified tools
   ```

4. **Create prompt file** at `<repo>/agent_configs/<domain>/prompts/<agent-name>.md`:
   - Include role description based on user's answer
   - Use XML tags for sections (`<role>`, `<inputs>`, `<workflow>`)
   - Follow the agent prompt guidelines from `autobots-agents-mer/docs/design/agent-prompt-guidelines.md` if it exists

5. **Create output schema** (if requested) at `<repo>/agent_configs/<domain>/schemas/<agent-name>.json` with a basic JSON Schema structure.

6. **Add tool stubs** in the domain's `tools.py` for any new tools the user mentioned. Each tool follows the pattern:
   ```python
   @tool
   def new_tool(runtime: ToolRuntime[None, Dynagent], param: str) -> str:
       """Tool description."""
       # TODO: Implement
       return "Not yet implemented"
   ```
   Register them in the domain's `register_<domain>_tools()` function.

7. **Report** what was created and remind the user to implement the tool logic and flesh out the prompt.
