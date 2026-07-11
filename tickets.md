# Tickets: Designer v2 — purpose-built LLD design surface on AG-UI

Builds the Designer Canvas: a Thread that *is* an LLD, showing the document as it is written, with
deterministic Consolidate and Push & Raise PR. Source spec:
`autobots-agents-mer/docs/design/designer-v2/SPEC-designer-v2.md`. Governing decisions: ADR-00XX
(chat UI framework), ADR-0002 (thread-scoped Workspace Context), ADR-0003 (classic engine on the
AG-UI plane).

Tickets 1 and 2 land in `autobots-devtools-shared-lib`; the rest land in `autobots-agents-mer`.

Work the **frontier**: any ticket whose blockers are all done. The critical path is
1 → 3 → 4 → 5 → 6 → 7 → 9, with 2 joining early and 8 running alongside the Canvas work.

## Middleware parameter on the classic agent factory

**What to build:** The AG-UI app builder can compose a domain on the *classic* engine, exactly as it
already composes one on the deep engine. Today the builder passes a middleware list to whatever agent
factory it is given, but the classic factory does not accept one, so only the deep factory can be
used. Give the classic factory a middleware parameter, appended after its existing injected-agent and
summarisation middleware. The app builder itself does not change.

This is the **risk spike** for the whole feature. It answers, before a line of Canvas exists, whether
the CopilotKit middleware — which has only ever run against deep-agent state — tolerates the classic
engine's state schema. If it does not, the fix is a compatibility shim, not a re-litigation of the
engine choice.

**Blocked by:** None — can start immediately.

- [ ] The classic agent factory accepts a middleware list and appends it after its existing middleware
- [ ] The AG-UI composition smoke test gains a case that builds the app with the classic factory
- [ ] That case asserts the streaming endpoint, resource routes, health route and CORS all mount
- [ ] The AG-UI app builder is unchanged
- [ ] The deep-engine composition path still behaves as before

## Shared identity resolver

**What to build:** The trusted-user-header identity resolver (falling back to a development default)
moves out of the AMA web app into a shared location, because the Designer web app is about to become
its second consumer. A pure prefactor: AMA's behaviour does not change.

**Blocked by:** None — can start immediately.

- [ ] Identity resolution lives in a shared location, not inside the AMA domain
- [ ] AMA consumes it from the shared location and behaves exactly as before
- [ ] The trusted-header seam is preserved intact, so GitHub OAuth can drop into it later

## Designer web app holding a real conversation

**What to build:** A designer opens a browser, picks a Thread, and holds a real conversation with the
real Designer agent. Tokens stream as the agent answers. The Active Agent is shown in the chat header
and on the composer — read from agent state, never tracked client-side. Handoffs land as visible
markers in one continuous Transcript, so an answer given in Background is visibly still in play when
Data Models needs it. The agent's tool activity is legible, so a long silent turn is not opaque.
Thread list, name, rename, delete and resume come from the existing threads resource router.

Deliberately **chat-only**: no Canvas, no dynadoc, no lifecycle. This is the slice that proves the
plane before anything is built on it.

The Designer web app is a new domain-level module composing the AG-UI app builder, the existing
Postgres thread and prefs stores, the durable checkpointer, the classic agent factory, and the shared
identity resolver. It runs as a **separate process** from the Chainlit designer, which keeps running
untouched beside it.

The client is React + Vite with headless CopilotKit hooks — no chat component, no license key, no
Node runtime service. The abandoned Next.js scaffold (an artifact of the rejected v1 Copilot-Runtime
path) is deleted rather than revived.

**Blocked by:** Middleware parameter on the classic agent factory; Shared identity resolver.

- [ ] A designer can open a Thread and hold a full conversation with the real Designer agent
- [ ] Tokens stream during a turn
- [ ] The Active Agent is rendered from agent state in the chat header and composer
- [ ] Each Handoff is marked in the Transcript, which stays continuous across Section Agents
- [ ] Tool activity (which Section was read, which was written) is visible during a turn
- [ ] Threads can be listed, named, renamed, deleted, and resumed with full history
- [ ] The abandoned Next.js scaffold is deleted
- [ ] **Air-gap check (manual):** run the stack against the real Designer agent, capture outbound
      traffic from browser and server, confirm zero calls to any CopilotKit or third-party host and
      zero license key in the client bundle. This flips ADR-00XX from *Accepted pending spike* to
      *Accepted*.

## Thread-scoped Workspace Context

**What to build:** A Thread is exactly one ticket's LLD. Starting a new LLD requires naming its
repository, Jira ticket, Confluence page and GitHub token up front, and those seed the Thread's
Workspace Context from its first turn. A Thread cannot be created without them — no conversation may
exist without a Workspace to write into.

The Designer web process registers a **thread-scoped** context-key resolver in place of the
user-scoped one. A designer can now open two tickets in two tabs and have both work correctly.

This fixes a defect that is **live in the current code**, independent of this feature: Workspace
Context is keyed by user, so anyone running two Chainlit designer sessions is already having one
LLD's Section writes silently redirected into the other's Workspace. The two resolvers are
process-global, which is why the Chainlit designer and the web designer must remain separate
processes.

**Blocked by:** Designer web app holding a real conversation.

- [ ] Thread creation takes repository, Jira number, Confluence page and GitHub token, and seeds the
      Workspace Context from them
- [ ] Creating a Thread without ticket details is rejected
- [ ] Two Threads on two tickets resolve to two different Workspaces — the regression test for the
      cross-write bug
- [ ] The Chainlit designer keeps its user-scoped resolver and is untouched

## Manifest, templates and the Sections route

**What to build:** The LLD's structure is declared in **one place**. A dynadoc Manifest for the
designer domain declares the seven Sections — which JSON backs each, and which template renders it —
with the templates ported from the structure currently hand-mirrored inside the consolidator agent's
prompt.

A Sections route returns one entry per Manifest node: Section id, title, status, and rendered
Markdown. Status is derived from **file existence** — the Section JSON is present, or it is not. A
missing Section renders a "Section pending" placeholder plus a structured error, so an empty Section
can never be mistaken for a finished one. A malformed-but-present Section surfaces a visible render
error rather than blank Markdown, so a broken write cannot silently reach the pull request. Both
render in non-strict mode.

Verified through the HTTP boundary, with fakes placed only at the genuinely external boundary (the
file server). Template correctness is tested here, not as a separate golden-file suite: a template
regression shows up as wrong Markdown in the Sections response, which is exactly where the UI would
experience it.

**Blocked by:** Thread-scoped Workspace Context.

- [ ] A Manifest declares all seven Sections with their backing JSON and template
- [ ] Templates are ported from the consolidator prompt's hand-mirrored structure
- [ ] The Sections route renders every Manifest node with id, title, status and Markdown
- [ ] Complete / not-started status is derived from file presence
- [ ] A missing Section yields a placeholder plus a structured render error
- [ ] A malformed Section surfaces an error rather than blank Markdown

## The Canvas

**What to build:** The designer watches the LLD fill in as they talk. The Canvas renders the document
as it stands right now, section by section, as the agent commits each one — so a wrong answer is
caught in the turn it was made rather than at the end.

The layout is the prototype's **hybrid**: a stepper across the top showing all seven Sections and
their status, the Canvas centre stage with a this-Section / full-document toggle, and the chat docked
right. The Canvas refetches a Section when the agent's file-write tool call completes, reading the
Section id from the tool arguments, with a full refetch on run completion as a safety net. It
survives a page reload.

Clicking a Section in the stepper **sends that Section's existing agentic-command prompt** and lets
the agent perform the Handoff. The stepper highlights where the agent *actually* is — never
optimistically — so a Handoff that did not happen is visible immediately, instead of the designer
typing into the wrong Section.

The Canvas is **read-only and server-authoritative**. It changes because an agent wrote a Section,
and for no other reason.

A hard internal boundary holds from here on: the **chat layer** (agent connection, message list,
composer, activity, thread list) imports nothing from the **LLD layer** (Canvas, stepper, lifecycle
bar, PR dialog), so Navigator and PAY can adopt the chat layer without forking it. It is extracted
into a shared package when a second consumer exists, and not before.

**Blocked by:** Manifest, templates and the Sections route.

- [ ] The Canvas renders the LLD as a document and fills in section by section as the agent commits
- [ ] The stepper shows all seven Sections as complete / drafting / not started
- [ ] A this-Section / full-document toggle works
- [ ] A Section refetches when the agent's file-write tool call completes; a full refetch runs on run
      completion
- [ ] Clicking a Section sends its agentic-command prompt; the stepper highlights only where the
      agent actually is
- [ ] The Canvas survives a page reload, and reopening an old LLD shows the whole document
- [ ] The chat layer imports nothing from the LLD layer

## Deterministic Consolidate, and the consolidator agent deleted

**What to build:** When every Section exists, **Consolidate** renders the finished document — from
the same Manifest and templates the Canvas has been showing all along — and writes the Consolidated
Document to the Workspace. What the designer approved on the Canvas is byte-for-byte what the pull
request will carry. It refuses while any Section is missing, so a half-written LLD cannot ship.

Because the Canvas and the Consolidated Document render from one Manifest, they **cannot** diverge.
The test that proves it is the drift guard: the Markdown Consolidate produces matches what the
Sections route produced for the same inputs. That guard is what makes the Canvas trustworthy.

**The consolidator agent is deleted** — its prompt, its roster entry, and the standing maintenance
note instructing future authors to update the LLD template in two places whenever it changes. That
instruction was a standing invitation to drift; the Manifest removes the second place entirely.

**Blocked by:** The Canvas.

- [ ] Consolidate renders the whole document from the Manifest and writes it to the Workspace
- [ ] Consolidate refuses when any Section is missing
- [ ] Consolidate's Markdown matches the Sections route's Markdown for the same inputs (drift guard)
- [ ] Render errors are returned alongside the Markdown
- [ ] The consolidator agent's prompt, roster entry and maintenance note are gone

## Deterministic Ops as async jobs

**What to build:** Workspace provisioning and build are long-running Jenkins pipelines — the build's
configured maximum wait is 600 seconds. Expose them as **async jobs**: the request returns a job
identifier immediately, the pipeline runs in the background, and a status route is polled for
queued / running / success / failure plus the pipeline result.

This is what lets a designer provision a Workspace so the Section Agents have somewhere to write, and
build it to verify the generated code compiles, without the request dying to a proxy idle timeout or
an accidental page refresh. Provisioning an existing Workspace **says so rather than recreating it**,
so resuming an LLD is safe. A failed job reports that it failed and why, so the designer can fix the
input rather than guess — it does not raise.

The Jenkins functions themselves are already free of presentation concerns and are called directly.
The existing Chainlit command handlers are left untouched. Job state is in-memory for this slice and
moves to Postgres when it needs to survive a restart.

This ticket ships the Build *job*; the Build *button's* gate lands with the lifecycle gates, so Build
is not yet reachable from the UI.

**Blocked by:** Thread-scoped Workspace Context. *(Runs in parallel with the Canvas work.)*

- [ ] A Deterministic Op returns a job identifier immediately
- [ ] The status route reports running, then success, and carries the pipeline result
- [ ] A failing pipeline reports failure with its error and does not raise
- [ ] Provisioning an existing Workspace reports that rather than recreating it
- [ ] Long-running provisioning reports progress rather than hanging
- [ ] A job keeps running across a page reload

## Push & Raise PR, and the lifecycle gates

**What to build:** **Push & Raise PR** ships the Consolidated Document. Before it does, the designer
reviews the pull request title, target branch and the list of artifacts, and explicitly confirms they
have reviewed the Consolidated Document — so shipping is a decision and not a reflex. Once the pull
request is open, its identifier is shown so the designer can go and find it.

This closes the lifecycle gating, computed from **server state, not client state**. From the
prototype, which pinned the gates more precisely than prose does:

```
sectionsDone = every Section status == complete
consolidated = Consolidate has succeeded for this LLD
prUnlocked   = sectionsDone && consolidated

Consolidate   enabled when sectionsDone && !consolidated
Push & PR     enabled when prUnlocked
Build         enabled when prUnlocked
```

**Blocked by:** Deterministic Consolidate, and the consolidator agent deleted; Deterministic Ops as
async jobs.

- [ ] Push & Raise PR shows title, target branch and artifact list for review before raising
- [ ] Raising requires an explicit confirmation that the Consolidated Document was reviewed
- [ ] The pull request identifier is surfaced once it is open
- [ ] Consolidate is unavailable until every Section exists
- [ ] Push & Raise PR and Build are unavailable until the LLD has been consolidated
- [ ] Every gate is computed from server state
