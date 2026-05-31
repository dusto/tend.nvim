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

- Neovim (recent)
- the TEND daemon: https://github.com/dusto/tend

## Install (lazy.nvim)

```lua
{
  "dusto/tend.nvim",
  opts = {},
}
```

## Credits

Derived from [carlos-algms/agentic.nvim](https://github.com/carlos-algms/agentic.nvim)
(MIT). The chat/diff/tool-call UI primitives originate there; ACP transport and
session ownership are being moved into the TEND daemon.

## License

MIT — see [LICENSE.txt](LICENSE.txt).
