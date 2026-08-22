# tend.nvim

Neovim plugin for **TEND** (Tasked Editor-Native Delegation) — a local-first,
supervised, editor-native AI work system. `tend.nvim` is the Neovim UX for the
[`tend`](https://github.com/dusto/tend) daemon (`tendd`), talking to it over a
bidirectional JSON-RPC Unix socket.

The daemon owns ACP provider processes, task-scoped sessions, approvals, events,
and editor/pane/LSP tooling. The plugin renders chat, tool-call blocks,
approvals/permissions, and diffs, and forwards editor-local actions.

> Status: early — forked from agentic.nvim and being reshaped into a daemon client.

## Requirements

- **Neovim 0.12+** — installed below with the built-in plugin manager
  (`vim.pack`, added in 0.12). No external plugin manager is needed.
- the TEND daemon (`tendd`): https://github.com/dusto/tend

## Install

Neovim 0.12 ships a built-in plugin manager, `vim.pack`, so `tend.nvim` installs
with no other components. Add this to your `init.lua`:

```lua
vim.pack.add({ "https://github.com/dusto/tend.nvim" })
require("tend").setup({})
```

`vim.pack.add` clones the plugin on first start and adds it to the runtimepath;
`require("tend").setup()` registers the `:Tend*` commands. Update with
`:lua vim.pack.update()`; remove with `:lua vim.pack.del({ "tend.nvim" })`.

Then start the daemon (see the [`tend`](https://github.com/dusto/tend) repo) and
run `:TendConnect`. See `:help tend.txt` for commands and configuration.

## Usage

`require("tend").setup()` registers the `:Tend*` commands. Everything below is
driven by them; `:help tend-daemon` has the full reference.

1. **Connect.** `:TendConnect` — attach to the daemon and open the workspace for
   the current directory. Run this first.
2. **Start a session.** `:TendSessionNew` picks a provider and starts a session,
   then `:TendChat` opens the chat and sends prompts. Replies, thinking, and
   tool-call blocks stream into the one chat widget. A session can converse
   freely; the daemon gates file/command changes until a task is delegated.
3. **Delegate work.** `:TendTaskNew` authors a task; `:TendTaskPick` hands it to
   a new or running session (that becomes the focused session).
4. **Supervise.** File edits and commands surface as **approvals** — a diff or
   command you approve or deny in place (`:TendApprove` re-lists pending ones).
   Review a change set with `:TendDiff` / `:TendOpenChanges`.

Other surfaces: `:TendSessionAttach` (switch focused session),
`:TendSessionInfo` (live token/context usage), `:TendSessionRename`,
`:TendProvider` / `:TendPersona`, `:TendMemory` / `:TendMemoryWrite`, and
`:TendEvents` (the plugin↔daemon protocol log). Attach editor context to the
next turn with `:TendAddSelection` (ranged), `:TendAddFile`,
`:TendAddDiagnostics`, and stop a turn with `:TendStop`.

## Keymaps

Inside Tend's own windows (chat, prompt, approvals) keymaps are set
automatically and are configurable via the `keymaps` option to `setup()` — see
`:help tend-keymaps`.

The **editor-wide** context actions have **no default keymaps** — tend does not
claim keys in your buffers. Bind their `<Plug>` targets to keys you own:

```lua
vim.keymap.set("x", "<leader>as", "<Plug>(tend-add-selection)")
vim.keymap.set("n", "<leader>af", "<Plug>(tend-add-file)")
vim.keymap.set("n", "<leader>ad", "<Plug>(tend-add-buffer-diagnostics)")
vim.keymap.set("n", "<leader>aD", "<Plug>(tend-add-line-diagnostics)")
vim.keymap.set("n", "<leader>ax", "<Plug>(tend-stop)")
```

`<Plug>(tend-add-selection)` is a visual-mode map (it reads the live selection);
the rest are normal-mode.

## Integrations

The plugin plays well with other buffer plugins (Copilot, lualine,
render-markdown, blink.cmp/nvim-cmp) — see `:help tend-integrations` for the
per-plugin setup.

**Editor tools for agents (MCP).** Agents that don't use ACP's client
filesystem calls (e.g. Kiro) still get supervised editor access: the **daemon**
exposes tend's editor operations as MCP tools and its `write`/`edit` tools route
through the same approval-gated diff review. This is entirely daemon-side —
there is nothing to install or configure in the plugin; the buffer edits and
approval floats you already see are how those tools surface. See
`:help tend-mcp-editor-tools` and the [`tend`](https://github.com/dusto/tend)
repo.

## Credits

Derived from [carlos-algms/agentic.nvim](https://github.com/carlos-algms/agentic.nvim)
(MIT). The chat/diff/tool-call UI primitives originate there; ACP transport and
session ownership are being moved into the TEND daemon.

## License

MIT — see [LICENSE.txt](LICENSE.txt).
