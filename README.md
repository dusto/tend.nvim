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

## Credits

Derived from [carlos-algms/agentic.nvim](https://github.com/carlos-algms/agentic.nvim)
(MIT). The chat/diff/tool-call UI primitives originate there; ACP transport and
session ownership are being moved into the TEND daemon.

## License

MIT — see [LICENSE.txt](LICENSE.txt).
