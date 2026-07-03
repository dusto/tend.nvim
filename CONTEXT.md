# tend.nvim

Domain glossary for tend.nvim. Defines terms that are overloaded, ambiguous,
or unique to this project. Not a spec. Not a design doc. Implementation
details belong in `AGENTS.md` (rules) or `docs/adr/` (decisions).

> **Much of this glossary predates the daemon migration.** Terms for the
> in-plugin ACP + session runtime — **AgentInstance**, **ACPClient**,
> **ACPTransport**, **Subscriber**, **ACP Session**, **AgentConfigOptions**,
> the legacy **SlashCommands**/**Hooks**/**Reconnect**, and the
> **Relationships**/**Example dialogue** built on them — describe code under
> `lua/tend/acp` that is dormant and removed in tend-9ee.9. **SessionManager**
> and **SessionRegistry** are already gone (tend-9ee.10): the daemon owns
> sessions and the plugin drives it via the connection-scoped `commands.Context`
> (`require("tend.commands").current()`).

## Language

### Process and protocol

**Provider**:
External CLI tool spawned as a subprocess (e.g. `claude-agent-acp`, `gemini`,
`codex-acp`). Speaks ACP over stdio.
_Avoid_: backend, server, model, agent (without qualifier).

**ACP (Agent Client Protocol)**:
Newline-delimited JSON-RPC protocol used to talk to a **Provider**.

**AgentInstance**:
The single, shared **ACPClient** held per **Provider** name. One subprocess per
provider, multiplexed across tabpages.
_Avoid_: agent, client (use the precise term).

**ACPClient**:
The Lua object that owns one **Provider** subprocess and one **ACPTransport**.
Routes RPC responses and `session/update` notifications. One per
**AgentInstance**.

**ACPTransport**:
Stdio framing layer below **ACPClient**. Splits JSON-RPC by newlines, preserves
partial trailers.

**Subscriber**:
Per-`session_id` `ClientHandlers` table registered on `ACPClient.subscribers`.
In practice always the **SessionManager** for that **ACP Session**. `ACPClient`
routes notifications via `__with_subscriber(session_id, cb)`.
_Avoid_: "listener", "consumer".

### Session — the overloaded word

`Session` means three different things at three layers. Use the qualified term.

**ACP Session**:
A protocol-level session id, opaque string issued by the **Provider** via
`session/new`. One **AgentInstance** can hold many; this plugin activates one
per **Tabpage**.
_Avoid_: bare "session" when discussing protocol traffic.

**SessionManager** (removed, tend-9ee.10):
Was the per-**Tabpage** Lua orchestrator owning the **ChatWidget** and the
active **ACP Session**. Its role is now the daemon's; the plugin holds a
connection-scoped `commands.Context` that tracks daemon sessions and owns the
one **ChatWidget**.

**SessionRegistry** (removed, tend-9ee.10):
Was the module-level `tab_page_id -> SessionManager` map. Gone with the
in-plugin session runtime; `require("tend.commands").current()` is the single
context now.

### Tabpage scope

**Tabpage**:
The Neovim tab. Buffers, windows, and extmarks are tab/buffer-scoped, so UI
primitives must stay tab-safe; but session ownership is no longer per-tab (the
daemon owns sessions; the **ChatWidget** is a singleton bound to one tab).
_Avoid_: "tab" (ambiguous with terminal tabs and chat-buffer tabs).

### UI surface

**ChatWidget**:
The chat UI container — a singleton bound to one **Tabpage** (created by
`commands.Context`), not one per tab. Owns its buffers (see **ChatWidget
buffers**), panel windows, and autocmds; it renders whichever daemon session is
focused.

**ChatWidget buffers**:
The five buffers held on `ChatWidget.buf_nrs`:

- `chat` — the streaming transcript. Owned by **MessageWriter**.
- `input` — user prompt entry buffer.
- `files` — backs the **FileList** view.
- `code` — backs the **CodeSelection** view.
- `diagnostics` — buffer-diagnostics view attached to the prompt.

When a doc says "chat buffer" it means `buf_nrs.chat` specifically. "Widget
buffer" means any of the five.

**WidgetLayout**:
Geometry/window management for **ChatWidget**. Opens, closes, resizes panels.
Applies `PANEL_WINDOW_OPTS` via `vim.wo[winid][0]`.

**Hidden chat float**:
Internal floating window holding the chat buffer while **ChatWidget** is
hidden. Preserves fold-state snapshots across hide/show. Not user-reachable.
See ADR 0001.

**BufferGuard**:
Redirects foreign buffers out of **ChatWidget** windows, into a non-widget
window in the same **Tabpage**.

**WindowDecoration**:
Winbar text, buffer names, header state stored in `vim.t[tab]`.

**DiffPreview**:
Inline or split diff rendered in the real file buffer, NOT in the chat buffer.
Distinct from **ToolCallDiff** (which is rendered inside the chat buffer).

**MessageWriter**:
Owns the chat buffer content for one **ChatWidget**. Writes message chunks,
**Tool Call Blocks**, status rows. State machine for sender-header dedup,
auto-scroll capture/apply, thinking-block reuse.

**ChatHistory**:
Accumulates messages for persistence. Separate from on-screen buffer state.

**TodoList**:
Per-**ChatWidget** renderer for **Plan** events. Owns its own buffer in the
widget, separate from the chat buffer. Empty until first `plan` update.
_Avoid_: bare "todos" for the protocol event — that is **Plan**.

**FileList**:
Per-**ChatWidget** holder for files the user attached to the prompt. Owns its
own buffer; renders into the header via `on_change`.

**CodeSelection**:
Per-**ChatWidget** holder for code ranges the user attached to the prompt
(`tend.Selection[]`). Sibling of **FileList**.

### Tool calls

**Tool Call**:
A provider-initiated action (file edit, bash, search, etc.) communicated via
`session/update` with `sessionUpdate = "tool_call"`. Goes through 3 phases:
initial, update(s), terminal.

**Tool Call Block**:
The rendered representation of a **Tool Call** in the chat buffer. Header +
top pad + body + bottom pad + status row N. Position tracked by a range
extmark in `NS_TOOL_BLOCKS`.
_Avoid_: "tool call" when discussing rendering — use Tool Call Block.

**ToolCallFold**:
Manual fold over a **Tool Call Block**'s body, anchored by the pad lines. See
ADR 0001.

**ToolCallDiff**:
Diff extracted from a **Tool Call** and rendered inside the chat buffer's
**Tool Call Block**. Immutable once rendered.

**ToolBlockBorder**:
`╭ │ ╰` glyphs drawn via `statuscolumn` to fence each **Tool Call Block**. See
ADR 0002.

**DiffHighlighter**:
Line and word highlighting for diffs rendered in the chat buffer.

### Permissions

**Permission Request**:
A provider-initiated `session/request_permission` event tied to a specific
**Tool Call** id. May carry a diff.

**PermissionManager**:
Per-**Tabpage** owner of pending **Permission Requests**, focus state, per-block
keymaps. Renders buttons inside the focused **Tool Call Block**. See ADR 0003.

### Message chunks

**Agent message chunk**:
Streaming chunk of the **Provider**'s primary response. `sessionUpdate =
"agent_message_chunk"`. Attributed to the `agent` sender.

**Agent thought chunk**:
Streaming chunk of the **Provider**'s internal reasoning. `sessionUpdate =
"agent_thought_chunk"`. Attributed to the `agent` sender. Reuses one extmark
in `NS_THINKING` across chunks.

**User message chunk**:
Echoed user input from the **Provider**. Attributed to the `user` sender.

**Plan**:
Provider-emitted todo list, rendered by `TodoList`. No sender header.

### Provider features (per-tab, keymap-driven)

**AgentConfigOptions**:
Per-**SessionManager** orchestrator for provider-side toggles (mode, model,
thought level). Reads `SessionCreationResponse.configOptions` (new path) or
`response.modes`/`response.models` (legacy path) at session creation. No
public `init.lua` entry — selectors open from configurable keymaps
(`change_mode`, `switch_model`, `change_thought_level`).

**AgentModes** / **AgentModels**:
Legacy-path holders inside `AgentConfigOptions`. Used when a provider sends
`modes`/`models` instead of unified `configOptions`. Same per-tab scope.

**SlashCommands** (legacy `lua/tend/acp/slash_commands.lua`, removed in
tend-9ee.9):
Was per-tab input-buffer completion off `available_commands_update`, injecting
`/new` and intercepting it on submit. On the daemon path this is replaced by
`lua/tend/ui/slash_complete.lua` + `commands.Context`: the daemon supplies the
merged command set (`slash.list`/`slash_commands_updated`), completes arguments
via `slash.complete`, and dispatches submits via `slash.invoke`.

### Hooks

**Hooks**:
User-registerable callbacks under `Config.hooks` (see
`config_default.lua`). All fire via `vim.schedule` + `pcall`. Five hooks
today:

- `on_create_session_response` — fires after `session/new` returns.
- `on_prompt_submit` — fires when user submits a prompt.
- `on_response_complete` — fires when the agent finishes a turn.
- `on_session_update` — fires for every `session/update` notification.
- `on_file_edit` — fires when a file-mutating **Tool Call** completes
  (kinds: `edit`, `create`, `write`, `delete`, `move`). Skipped during
  session restore.

### Reconnect

**Reconnect**:
Per-`ACPProviderConfig.reconnect` flag. Default `false`. Max 3 attempts at
2s backoff. Fires on provider process exit. No provider has it enabled by
default.

## Relationships

The first group described the removed in-plugin runtime (see the banner at the
top); on the daemon path the daemon owns sessions and providers, and the
plugin holds one `commands.Context` that owns the one **ChatWidget**:

- The daemon owns **ACP Session**s and **Provider** processes; the plugin's
  `commands.Context` tracks them and owns the one **ChatWidget** (bound to a
  **Tabpage**), which renders whichever session is focused.

The rendering relationships below are unchanged (kept UI primitives):

- A **ChatWidget** owns one **MessageWriter** which owns many **Tool Call
  Blocks** keyed by tool call id.
- A **Permission Request** belongs to exactly one **Tool Call** (by id).
- **Tool Call Block**, **ToolCallFold**, **ToolCallDiff**, **ToolBlockBorder**
  all describe the same rendered block from different angles
  (content/folding/diff/borders).

## Example dialogue

> **Dev:** "When the user opens a second **Tabpage**, do we spawn another
> **Provider**?"
> **Maintainer:** "No. **AgentInstance** is shared. We create a new **ACP
> Session** on the existing instance, and a new **SessionManager** owns it for
> that **Tabpage**."

> **Dev:** "Where does the diff render — in the chat or in the file?"
> **Maintainer:** "Both, different things. **ToolCallDiff** renders inside the
> chat buffer's **Tool Call Block**. **DiffPreview** renders in the real file
> buffer."

## Flagged ambiguities

- "Session" was used to mean **ACP Session**, **SessionManager**, and
  **SessionRegistry** interchangeably. Resolved: three distinct concepts, use
  the qualified term.
- "Agent" was used to mean **Provider** subprocess, **AgentInstance** Lua
  object, and the LLM behind the provider. Resolved: **Provider** for the
  subprocess, **AgentInstance** for the Lua holder; the LLM is not a domain
  concept here.
- "Tool call" was used to mean both the protocol event and its rendered block.
  Resolved: **Tool Call** for the event, **Tool Call Block** for the rendering.
- "Diff" was used to mean both the in-chat diff and the file-buffer preview.
  Resolved: **ToolCallDiff** (in-chat) vs **DiffPreview** (in-file).
- "Tracker" appears in `MessageWriter` code (`tracker.diff`,
  `tracker.permission`). Local-variable name, not a domain concept. Do not
  introduce it in docs.
- "Focus" was used to mean Neovim window focus and **PermissionManager** focus
  (which **Tool Call Block** has buttons active and digit keymaps bound).
  Resolved: bare "focus" = Neovim's window focus; "permission focus" or
  "focused block" for the **PermissionManager** notion.
- "status row", "status footer" refer to the same line: the last row of a
  **Tool Call Block**, outside the fold range. Canonical: **status row**.
  ("row N" was used pre-refactor and overlapped with the permission rows now
  rendered between `bottom_pad` and the status row; avoid the term.)
- "Functional test" vs "integration test" — `tests/AGENTS.md` once split these
  into separate categories with overlapping definitions. The split was not
  load-bearing. Resolved: treat as one category. Use either folder
  (`tests/functional/`, `tests/integration/`) when a test spans more than one
  module or needs real Neovim state across them; no formal distinction.
