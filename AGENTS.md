# Agents Guide

**tend.nvim** is the Neovim client for **TEND** (Tasked Editor-Native Delegation).
It is the editor UX for the `tend` daemon (`tendd`): it renders chat, tool-call
blocks, approvals/permissions, and diffs, and forwards editor-local actions. The
**daemon** — not this plugin — owns ACP provider processes, task-scoped sessions,
the event bus, and approvals, over a bidirectional JSON-RPC 2.0 Unix socket. The
daemon and the wire contract live in [dusto/tend](https://github.com/dusto/tend).

> **Architecture in transition.** The daemon now owns sessions: the in-plugin
> session runtime (`session_manager`/`session_registry`/`session_restore`) has
> been removed and the plugin drives the daemon over JSON-RPC (`lua/tend/commands.lua`,
> the connection-scoped `Context`, is the client). The chat/diff/tool-call **UI
> primitives are kept** and are re-pointed at the daemon. One legacy piece
> remains: the in-plugin ACP transport/provider layer under `lua/tend/acp` (plus
> its `CONTEXT.md`/`lua/tend/acp/AGENTS.md`, which still describe the old
> `SessionManager` coupling); it is dormant (nothing spawns it) and is removed in
> tend-9ee.9.

## Nested instructions

Read these before touching the matching area:

- `lua/tend/acp/AGENTS.md` - ACP client, tool calls, permissions, providers
- `lua/tend/ui/AGENTS.md` - chat UI: topology, lifecycle contracts
  (open/close/destroy), MessageWriter state machines, tool-call block layout,
  folding, auto-scroll, permission reanchor, traps
- `tests/AGENTS.md` - test framework, TDD workflow, assertions, helpers

## Domain glossary — lazy read

`CONTEXT.md` (repo root) defines overloaded terms (Session, Agent, Provider,
Tool Call, Diff, etc.). Do NOT pre-read. Grep it for the ambiguous keyword
first; only Read the file if the grep matches. If no match, the term is not
in the glossary — proceed without loading.

## Architectural decisions (ADRs) — optional read

`docs/adr/` stores Architecture Decision Records (ADRs). One file per subject.
Filename convention: `NNNN-short-slug.md` (4-digit, zero-padded). "ADR 2" means
`docs/adr/0002-*.md`.

Each ADR records why a current rule exists: option taken, alternatives rejected,
changelog of how it evolved. The full template lives in `docs/adr/README.md`
and MUST be used verbatim for new ADRs.

Do NOT pre-read ADRs. Trigger to load:

- A rule in `AGENTS.md` is unclear, contested, or looks arbitrary.
- You are about to propose rewriting a subsystem an ADR covers.
- A reviewer asks "why didn't we do X?".

Discovery (no prior pointer): Grep `docs/adr/` for the topic keyword. Read
only on match. No match means no ADR exists for the topic — proceed without
loading. Do NOT `ls` or read the whole folder.

Direct citation (`ADR NNNN` in a nested `AGENTS.md` or `CONTEXT.md`) is an
implicit match, NOT an auto-load. Read the cited path only when the trigger
above fires — rule is unclear, you are about to change that subsystem, or a
reviewer asks why. A citation seen in passing is not a trigger.

Citation format: `ADR NNNN` (4-digit, zero-padded, no brackets, no dash).

### grill-with-docs override

The `grill-with-docs` skill ships a minimal 1-3 sentence ADR template and uses
`docs/adr/` with 4-digit numbering. Path + numbering match this repo. Template
does NOT — use the repo template in `docs/adr/README.md` verbatim. Do NOT
substitute the skill's minimal template. Do NOT skip the `Rejected /
superseded alternatives` table or `Changelog` sections.

For `CONTEXT.md`: skill expects a domain glossary at repo root, devoid of
implementation. Populate it incrementally as overloaded terms surface. Do NOT
turn it into a spec, scratchpad, or design doc.

## Anti-staleness rules for AGENTS.md files

- Cite **module + symbol**, never line numbers.
- Don't paste real implementation. Code blocks are for teaching examples (right
  vs. wrong patterns), signatures, and diagrams. Implementation drifts; teaching
  examples don't.
- Every "why" must reference an observable failure (flicker, crash, lost fold).
  If the failure is gone, delete the rule.
- New "FORBIDDEN" / "MUST" rule about runtime behavior = new test that fails
  without the rule. Reference the test by name in the rule body. Pure-style
  rules (formatting, naming, docs) are exempt.
- Fenced code blocks MUST have a language hint. Use `text` for free-form ASCII
  (trees, byte layouts, pseudocode), `mermaid` for diagrams, and the actual
  language otherwise (`lua`, `bash`, `markdown`, etc.). markdownlint flags bare
  fences (MD040).

## CRITICAL: No Assumptions - Gather Context First

**NEVER make assumptions. ALWAYS gather context before decisions or
suggestions.** Read relevant files, search for existing patterns, verify types.
If you haven't read the relevant code, you don't have enough context.

Forbidden phrases: "this probably...", "I assume...", "it should...", "you might
need to...", "based on similar projects...". Never suggest partial
implementations expecting the user to fill gaps.

## CRITICAL: Multi-Tabpage Architecture

**EVERY FEATURE MUST BE MULTI-TAB SAFE.** The plugin's UI primitives run in
buffers, windows, and tabpages, so they must isolate their state per scope even
though the daemon owns sessions.

### Architecture overview

- The daemon owns sessions; the plugin holds one connection-scoped command
  `Context` (`lua/tend/commands.lua`, `require("tend.commands").current()`) — a
  singleton, not per-tab, since the editor is one client of the daemon.
- One `ChatWidget`, created lazily and bound to the tabpage where it is first
  shown (`self.tab_page_id`). It renders whichever daemon session is focused; a
  per-session chat buffer is swapped into its chat window on switch.
- The daemon (not this plugin) owns ACP provider processes and session ids.

Even with a single widget, features must respect scope: buffers/windows/extmarks
are buffer- or window-scoped and a user can move the widget or open editor
windows across tabpages, so the rules below still apply to every UI primitive.

### Implementation requirements

- **NEVER use module-level shared state** for per-tabpage runtime data
  - WRONG: `local current_session = nil` (single for all tabs)
  - RIGHT: Store in tabpage-scoped instances
  - Module-level constants OK for truly global config: `local CONFIG = {}`

- **Namespaces are GLOBAL, extmarks are BUFFER-SCOPED**
  - Module-level namespace constants are fine. `nvim_create_namespace()` is
    idempotent (same name = same ID globally). Isolation comes from buffer
    separation.
  - Clear with
    `vim.api.nvim_buf_clear_namespace(bufnr, ns_id, start_line, end_line)`

  ```lua
  -- Module level (shared namespace ID is OK)
  local NS_ANIMATION = vim.api.nvim_create_namespace("tend_animation")

  function Animation:new(bufnr)
      return { bufnr = bufnr }
  end

  vim.api.nvim_buf_set_extmark(self.bufnr, NS_ANIMATION, ...)
  vim.api.nvim_buf_clear_namespace(self.bufnr, NS_ANIMATION, 0, -1)
  ```

- **Highlight groups are GLOBAL** (shared across all tabpages). Defined once in
  `lua/tend/theme.lua`. Use namespaces to control WHERE highlights appear,
  not to isolate definitions.

- **Scoped storage:** use the correct accessor

  | Scope   | Accessor         | Purpose          | Example                          |
  | ------- | ---------------- | ---------------- | -------------------------------- |
  | Buffer  | `vim.b[bufnr]`   | Custom variables | `vim.b[bufnr].my_state = {}`     |
  | Buffer  | `vim.bo[bufnr]`  | Built-in options | `vim.bo[bufnr].filetype = "lua"` |
  | Window  | `vim.w[winid]`   | Custom variables | `vim.w[winid].my_state = {}`     |
  | Window  | `vim.wo[winid]`  | Built-in options | `vim.wo[winid].number = true`    |
  | Tabpage | `vim.t[tabpage]` | Custom variables | `vim.t[tabpage].my_state = {}`   |

  `vim.b`/`vim.w`/`vim.t` are custom variables (Vimscript `b:`/`w:`/`t:`).
  `vim.bo`/`vim.wo` are built-in options (`:setlocal`). State is auto-cleaned
  when scope is deleted. Invalid option names in `vim.bo`/`vim.wo` throw.

- **Get tabpage ID:** `self.tab_page_id` in instance methods; from buffer:
  `vim.api.nvim_win_get_tabpage(vim.fn.bufwinid(bufnr))`; current:
  `vim.api.nvim_get_current_tabpage()`.

- **Buffers/windows are tabpage-specific.** Never assume global existence. Use
  `vim.api.nvim_tabpage_*` when needed.

- **Window creation and validation must be tab-scoped.** When checking if a
  window exists or creating a new one, scope the lookup to the session's
  tabpage. Never query windows globally (e.g. `vim.api.nvim_list_wins()`) and
  assume a hit belongs to the current session. Use
  `vim.api.nvim_tabpage_list_wins(self.tab_page_id)` and validate that the
  window's tabpage matches before using it.

- **Autocommands must be tabpage-aware.** Prefer buffer-local:
  `vim.api.nvim_create_autocmd(..., { buffer = bufnr })`. Filter by tabpage in
  global autocommands.

- **Keymaps must be buffer-local.** Use
  `BufHelpers.keymap_set(bufnr, "n", "key", fn)` and
  `BufHelpers.keymap_del(bufnr, "n", "key")`. NEVER use global keymaps.
  NEVER call `vim.keymap.set` / `vim.keymap.del` directly with
  `{ buffer = bufnr }`: the option was renamed to `buf` in Neovim 0.12.1
  (`neovim#38360`) and removed
  in 0.15; the wrappers gate on `has('nvim-0.12.1')`. Regression tests:
  ``lua/tend/utils/buf_helpers.test.lua::"uses `buffer`/`buf` opt on Neovim"``.

## Public API and call chain

There are two entry surfaces:

- **`:Tend*` user commands** — the primary interface, registered by
  `lua/tend/commands.lua` on `setup`. These drive the daemon: connect,
  workspace/task/session/provider, chat/prompt, approvals, and diff review. See
  |tend-daemon| in `doc/tend.txt` and the `Context` methods in `commands.lua`.
- **`lua/tend/init.lua`** — a thin Lua surface for the chat widget lifecycle
  (`open`/`close`/`toggle`/`rotate_layout`) plus `setup`. Each lifecycle entry
  delegates to the connection-scoped command `Context`:

```lua
local function with_context(fn)
    local ctx = require("tend.commands").current()
    if not ctx then -- setup() has not run
        Logger.notify("tend: not set up; call require('tend').setup() first")
        return
    end
    fn(ctx)
end
-- Tend.toggle -> with_context(function(ctx) ctx:toggle_widget(opts) end)
```

The `Context` (a single `current` per Neovim instance) owns the connection, the
tracked sessions, and the one `ChatWidget`. Widget-lifecycle methods act on the
daemon's *focused* session; they report (they do **not** auto-create a session)
when none is focused — sessions start via `:TendSessionNew`.

Guarantees:

- Daemon requests go through `Context:call`, which reports RPC errors via the
  Logger rather than raising; successes reach the callback.
- No session is created implicitly. `require("tend").open/toggle` with no
  focused session report and return.

### init.lua public entries

Source of truth: `lua/tend/init.lua` exports.

- **Widget lifecycle** — `open`/`close`/`toggle`/`rotate_layout`, delegating to
  `Context:open_widget`/`close_widget`/`toggle_widget`/`rotate_layout`.
- **Config entry** — `setup` (merges config, calls `require("tend.commands").setup`,
  installs the `FileChangedShell` reload autocmd and theme once).

Legacy in-plugin session ops (context adders, `new_session`, `switch_provider`,
`stop_generation`, `restore_session`) were removed with the session runtime; the
daemon-backed replacements land in tend-9ee.10.2 / tend-9ee.10.3.

Cleanup: the daemon owns session lifecycles, so there is no per-tab session
teardown. Re-running `setup` stops the previous `Context`'s connection
(`Context:dispose`) before building the new one.

### Logger

- **FORBIDDEN: `vim.notify` directly.** Use `Logger.notify`. Direct calls raise
  fast-context errors when fired from libuv callbacks or `vim.schedule`
  boundaries.
- Logger only has `debug()`, `debug_to_file()`, and `notify()`. No `warn()`,
  `error()`, or `info()`. `debug()`/`debug_to_file()` output depends on
  `Config.debug`.

### Common traps (project-wide)

Subsystem-specific traps live in nested `AGENTS.md`. These apply everywhere:

- **FORBIDDEN: `vim.notify`** -> use `Logger.notify` (fast-context errors).
- **FORBIDDEN: `goto` / `::label::`** -> Selene parser does not parse it. Use
  inverted conditions or `elseif` chains. See "Lua restrictions" below for
  example.
- **FORBIDDEN: module-level mutable state for per-tab data** -> store on per-tab
  instances. See "Multi-Tabpage Architecture" below.
- **FORBIDDEN: global keymaps, and direct `vim.keymap.set`/`vim.keymap.del`
  with `{ buffer = bufnr }`** -> use `BufHelpers.keymap_set` /
  `BufHelpers.keymap_del`. See "Keymaps must be buffer-local" above for the
  `buffer` -> `buf` rename rationale and regression tests.
- **FORBIDDEN: `vim.api.nvim_list_wins()` for tab-scoped lookups** -> use
  `vim.api.nvim_tabpage_list_wins(self.tab_page_id)`.
- **FORBIDDEN: `:set`-style writes for window-local options** -> use
  `vim.wo[winid][0].opt = val`, never `vim.wo[winid].opt = val` or
  `nvim_set_option_value(opt, val, { win = winid })`. Per `:h local-options`,
  window-local options are remembered per `(buffer, window)`. `:set` writes
  imprint the value in any buffer that briefly cohabits the window and the
  buffer carries it to its next host. `[0]` is the `:setlocal` sentinel (only
  `[0]` is supported by `vim.wo`, see `:h vim.wo`); without it, panel styling
  leaks to redirected buffers.
  - Applies to ALL `vim.wo` writes, not just panels. No `vim.bo` equivalent is
    needed: buffer options have no per-window memory.
  - Reads (`local x = vim.wo[winid].opt`) are unaffected; `[0]` is write-only.
  - Regression:
    `lua/tend/ui/buffer_guard.test.lua::"does not leak widget window options to the editor window after redirect"`.
- **AVOID: `nvim_set_option_value` / `nvim_get_option_value`** for buffer or
  window options when an idiomatic accessor exists. Use `vim.bo[bufnr].opt` for
  buffer options and `vim.wo[winid][0].opt` for window options. The
  `nvim_*_option_value` API is reserved for cases that need a dynamic option
  name or a non-default scope (e.g. `scope = "global"`). Reading is symmetric:
  `vim.bo[bufnr].opt` / `vim.wo[winid].opt` (no `[0]` on reads).

## Code Style

### LuaCATS annotations

Use a space after `---` for both descriptions and annotations. Use `@private` or
`@protected` for internal details. Do NOT write meaningful parameter/ return
descriptions unless requested. Group related annotations together.

```lua
--- Brief description of the class
--- @class MyClass
--- @field public_field string Public API field
--- @field _private_field number Private implementation detail
local MyClass = {}
MyClass.__index = MyClass

--- Creates a new instance of MyClass
--- @param name string
--- @param options table|nil
--- @return MyClass instance
function MyClass:new(name, options)
    return setmetatable({ public_field = name }, self)
end
```

#### Return format

`@return {type} return_name description` (type first, then name).

- RIGHT: `@return boolean success Whether the operation succeeded`
- WRONG: `@return boolean Whether the operation succeeded` (missing name)
- WRONG: `@return success boolean` (wrong order)

#### Optional types

Format depends on annotation type. See
[LuaLS issue #2385](https://github.com/LuaLS/lua-language-server/issues/2385)
for the underlying validator limitation.

**`@param` and `fun()` type declarations - MUST use `type|nil`:**

- RIGHT: `@param winid number|nil`
- RIGHT: `@param callback fun(result: table|nil)`
- WRONG: `@param winid? number` (LuaLS does not validate optional syntax)
- WRONG: `fun(result?: table)` (optional syntax ignored)

**`@field` annotations - Use `variable? type`:**

- RIGHT: `@field _state? string`
- RIGHT: `@field diff? { all?: boolean }` (inline tables also use `?`)
- WRONG: `@field _state string|nil` (use `?` here instead)
- WRONG: `@field _state string?` (`?` goes after variable name, not type)

For a partial variant of an existing class, use `@class (partial)` extending the
source type instead of re-declaring every field as optional.

- RIGHT:
  `@class (partial) MyOptsOverride: MyOpts`
- WRONG: re-listing `@field field? type` for every field from `MyOpts`

**`@return`, `@type`, `@alias` - Use explicit `type|nil`:**

- RIGHT: `@return string|nil result`, `@type table<string, number|nil>`,
  `@alias MyType string|nil`
- WRONG: trailing `?` on the type (e.g. `string?`, `number?`)

#### Typed variables before return

LuaLS cannot infer types from inline returns of complex types. Use a typed
intermediate variable:

```lua
-- Bad: LuaLS cannot infer the return type
function M.create_block(lines)
    return {
        start_line = 1,
        end_line = #lines,
        content = lines,
    }
end

-- Good: Type annotation enables proper type checking
--- @return MyModule.Block block
function M.create_block(lines)
    --- @type MyModule.Block
    local block = {
        start_line = 1,
        end_line = #lines,
        content = lines,
    }
    return block
end
```

## Development, Testing and Linting

### Plugin requirements

- Neovim v0.11.5+ (verify APIs match this version or newer)
- LuaJIT 2.1 (bundled, based on Lua 5.1)
- Optional on Linux: `wl-clipboard` (Wayland) or `xclip` (X11) for clipboard
  image paste. macOS and Windows use native OS tooling and need no extra
  install. Drag-and-drop is unchanged — it is a terminal feature.

### Lua restrictions

**FORBIDDEN: `goto`/`::label::` syntax** - Selene parser does not support it.
Use inverted conditions, `elseif` chains, or extracted functions for early
returns.

```lua
-- Bad: Uses goto (Selene parse error)
for _, item in ipairs(items) do
    if should_skip(item) then
        goto continue
    end
    -- ... process item ...
    ::continue::
end

-- Good: Inverted condition
for _, item in ipairs(items) do
    if not should_skip(item) then
        -- ... process item ...
    end
end
```

### Testing

#### MANDATORY: TDD Red/Green

For bug fixes and behavioral changes, write the failing test BEFORE the fix:

1. **Red** - Write a failing test. If the code under test does not exist, first
   scaffold the module/class/method with stubbed bodies so the test fails on
   wrong behavior, not on `attempt to call a nil value`.
2. **Green** - Minimal change to turn the test green.
3. For Lua/test code changes, run `make validate` to confirm nothing else
   broke. Docs-only changes do not require full validation.

A test written after the fix is already green proves nothing. Non-negotiable.
Only exception: pure refactors, formatting, docs - call out explicitly in the
PR.

**Full workflow, helpers, conventions:** `@tests/AGENTS.md`. ALWAYS read it
before creating, editing, or reviewing tests. Do not guess conventions from
other projects (e.g. `assert` is a custom helper, not `luassert`; spies have no
`:call(n)`; async assertions inside `vim.schedule` are silently dropped).

### MANDATORY: Post-change validation for Lua files

Run `make validate` ONLY when `.lua` files changed.

Skip `make validate` for docs-only changes, including `.md`, `.txt`,
`README.md`, `AGENTS.md`, `doc/tend.txt`, and
`docs/adr/`.

Run the narrow doc-specific check instead. For vimdoc changes, run:

```bash
timeout 5 nvim --headless -c "helptags doc/" -c "quit"
```

```bash
make validate
```

Runs `format`, `luals`, `selene`, `test` in sequence. Fast (< 5s combined),
single permission prompt, output redirected to log files automatically.

Output is 5-6 short lines on success. Example:

```bash
format: 0 (took 1s) - log: .local/tend_format_output.log
luals: 0 (took 2s) - log: .local/tend_luals_output.log
selene: 0 (took 0s) - log: .local/tend_selene_output.log
test: 0 (took 1s) - log: .local/tend_test_output.log
Total: 4s
```

Each line: `{task}: {exit_code} (took {seconds}s) - log: {log_path}`. Exit code
`0` = success.

#### FORBIDDEN: Output redirection

NEVER redirect `make validate` output - it is already minimal. No `> file`,
`>> file`, `2>&1`, `| tee`, `| head`, `| tail`. The command handles its own log
redirection.

```bash
# FORBIDDEN
make validate > my_output.log
make validate 2>&1 | tee output.log
make validate | head -20

# CORRECT
make validate
```

#### Log files (defined by Makefile)

Exact paths in project root (NEVER write to different paths):

- `.local/tend_format_output.log`
- `.local/tend_luals_output.log`
- `.local/tend_selene_output.log`
- `.local/tend_test_output.log`

Only read exit codes from `make validate` output. On failure, read the
corresponding log file.

**Reading log files (on failure only):**

- NEVER use the Read tool (floods context with entire file)
- Use targeted commands:
  - `tail -n 10 .local/tend_luals_output.log` (errors usually at end)
  - `rg "error|warning|fail" .local/tend_test_output.log` (smart-case)
  - `grep -i "error" .local/tend_selene_output.log`
- If multiple reads needed: `cat .local/tend_*_output.log` once instead of
  chunked reads

### Make targets

- `make luals` - Lua Language Server headless diagnosis (full project type
  check)
- `make selene` - Selene linter
- `make format` - StyLua format all Lua files
- `make format-file FILE=path/to/file.lua` - Format one file

More targets: read `Makefile` at project root.

### Configuration and user-facing docs

- `lua/tend/config_default.lua` - user-configurable options
- `lua/tend/theme.lua` - custom highlight groups

When adding a new highlight group:

1. Add name to `Theme.HL_GROUPS` constant
2. Define default in `Theme.setup()`
3. Update README.md "Customization (Ricing)" section (code example + table row)

#### Vimdoc (`doc/tend.txt`)

Manually written, NOT auto-generated. When changing these files, vimdoc MUST be
updated:

| Source file                      | Vimdoc section to update            |
| -------------------------------- | ----------------------------------- |
| `lua/tend/init.lua`           | Usage (public API functions)        |
| `lua/tend/config_default.lua` | Configuration, Customization        |
| `lua/tend/theme.lua`          | Customization (highlight groups)    |
| `README.md` (install/keymaps)    | Installation, Keymaps, Integrations |

**Format rules:** 78-char width, right-aligned tags `*tend-section*`, code
blocks `>lua` / `<`, function tags `*tend.function_name()*`, cross-refs
`|tend-section|`, modeline `vim:tw=78:ts=8:ft=help:norl:`. After editing:
`timeout 5 nvim --headless -c "helptags doc/" -c "quit"`.

### Git workflow

- **NEVER commit to `main` directly.** Use a feature branch.
- Branch names: `feat/`, `fix/`, `chore/`, `docs/`, `refactor/` + kebab-case
  description.
- For isolation, use a worktree under `./.worktrees/` (gitignored).
- Never use `--no-verify`, `--no-gpg-sign`, or force-push to `main`.

#### Pull requests

- `main` is protected by a repository ruleset: **PRs required**, force-push and
  branch deletion blocked, with **required status checks** — `format`, `lint`,
  `test`/`typecheck` on stable Neovim (v0.11.5 + v0.12.1), and the conventional
  PR title — that must pass to merge. (`nightly` runs but is not required.)
  CI (`pr-check.yml`) runs on every PR.
- Self-review and run `make validate` before opening / marking a PR ready.
- PR title must follow Conventional Commits (squash-merge uses the title as the
  commit subject). Branch names: `feat/`, `fix/`, `chore/`, `docs/`, `refactor/`
  + kebab-case — never prefix with task keys.

### Local-only artifacts

MUST NOT be committed:

- `docs/superpowers/` - per-developer plans, notes, scratch work

If you stage files in these paths, stop and unstage.
