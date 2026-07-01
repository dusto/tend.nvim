--- Native slash-command completion for the chat prompt on the daemon path.
---
--- The daemon owns the command set: it merges the agent's advertised commands
--- with the daemon/harness commands and pushes them as a session event; the
--- editor completes command *names* locally from that cached set and command
--- *arguments* (task ids, statuses) via the daemon completion RPC. This is a
--- client-side completion source, not an LSP (see tend-e7p.14).
---
--- The buffer's `completefunc` is a stable v:lua reference into this module;
--- `attach` wires a TextChangedI trigger that, per keystroke on the command
--- line, decides whether the user is typing a command name (synchronous, from
--- the cached list) or an argument (asynchronous, via the source RPC), stores
--- the resulting items on the buffer, and feeds <C-x><C-u> to open the menu.
--- State lives in buffer-locals (`vim.b`), never module globals, so each input
--- buffer completes independently.
local M = {}

--- One entry in the merged slash-command set (the daemon's SlashCommand).
--- @class tend.slash.Command
--- @field name string
--- @field description? string
--- @field arg_hint? string

--- One argument completion candidate (the daemon's SlashCandidate).
--- @class tend.slash.Candidate
--- @field value string
--- @field detail? string

--- The daemon-backed data the completion source needs, injected so this module
--- (and the widget) stay decoupled from the daemon connection.
--- @class tend.ui.SlashSource
--- @field list fun(): tend.slash.Command[] active session's merged commands (cached)
--- @field complete fun(command: string, prefix: string, cb: fun(candidates: tend.slash.Candidate[]))

--- A parsed completion context for the command line before the cursor.
--- @class tend.ui.SlashComplete.Context
--- @field kind "name"|"arg"
--- @field command? string the command name (arg contexts only)
--- @field prefix string the token typed so far
--- @field start integer 0-based byte column where the completed token begins

--- Classify the command line before the cursor. Returns nil unless the line is a
--- slash command being typed: a bare command name (no space yet) or the first
--- argument token after the command and a single run of spaces. Free-form text
--- past the first argument token is not completed.
--- @param line string the text from column 0 up to the cursor
--- @return tend.ui.SlashComplete.Context|nil
function M.parse(line)
    local name = line:match("^/([^%s]*)$")
    if name then
        return { kind = "name", prefix = name, start = 1 }
    end
    local command, arg = line:match("^/([^%s]+)%s+([^%s]*)$")
    if command then
        return {
            kind = "arg",
            command = command,
            prefix = arg,
            start = #line - #arg,
        }
    end
    return nil
end

--- Build complete-items for the command names. The leading "/" is already typed
--- (start = 1), so `word` is the bare name; `abbr` shows it with the slash and
--- `menu` shows the argument hint.
--- @param commands tend.slash.Command[]
--- @return table[] items complete-items dictionaries
function M.name_items(commands)
    local items = {}
    for _, cmd in ipairs(commands) do
        if type(cmd.name) == "string" and not cmd.name:match("%s") then
            table.insert(items, {
                word = cmd.name,
                abbr = "/" .. cmd.name,
                menu = cmd.arg_hint or "",
                info = cmd.description or "",
                kind = "/",
                icase = 1,
            })
        end
    end
    return items
end

--- Build complete-items for an argument's candidates, with the candidate detail
--- (e.g. a task title) shown in the menu.
--- @param candidates tend.slash.Candidate[]
--- @return table[] items complete-items dictionaries
function M.arg_items(candidates)
    local items = {}
    for _, candidate in ipairs(candidates) do
        table.insert(items, {
            word = candidate.value,
            menu = candidate.detail or "",
            info = candidate.detail or "",
            icase = 1,
        })
    end
    return items
end

--- The buffer's `completefunc`. Reads the items and start column stashed by the
--- last trigger; with no state it cancels (findstart -3) rather than completing.
--- @param findstart integer 1 to report the start column, 0 to return items
--- @param _base string the text being matched (Neovim fuzzy-filters for us)
--- @return integer|table
function M.complete_func(findstart, _base)
    local bufnr = vim.api.nvim_get_current_buf()
    local start = vim.b[bufnr].tend_slash_start
    if start == nil then
        return findstart == 1 and -3 or {}
    end
    if findstart == 1 then
        return start
    end
    return vim.b[bufnr].tend_slash_items or {}
end

--- @private
--- Stash the items and start column on the buffer and open the completion menu.
--- No-op when there is nothing to show or the buffer left insert mode (the arg
--- path resolves asynchronously, so the user may have moved on).
--- @param bufnr integer
--- @param start integer
--- @param items table[]
function M._show(bufnr, start, items)
    if #items == 0 or vim.fn.mode() ~= "i" then
        return
    end
    vim.b[bufnr].tend_slash_start = start
    vim.b[bufnr].tend_slash_items = items
    vim.api.nvim_feedkeys(
        vim.api.nvim_replace_termcodes("<C-x><C-u>", true, false, true),
        "n",
        false
    )
end

--- @private
--- Decide what to complete for the current command line and open the menu.
--- @param bufnr integer
--- @param source tend.ui.SlashSource
function M._trigger(bufnr, source)
    -- Only the first line of the prompt is a command line.
    local cursor = vim.api.nvim_win_get_cursor(0)
    if cursor[1] ~= 1 then
        return
    end
    local before = vim.api.nvim_get_current_line():sub(1, cursor[2])
    local ctx = M.parse(before)
    if not ctx then
        return
    end
    if ctx.kind == "name" then
        M._show(bufnr, ctx.start, M.name_items(source.list()))
        return
    end
    source.complete(ctx.command, ctx.prefix, function(candidates)
        if vim.api.nvim_get_current_buf() ~= bufnr then
            return
        end
        M._show(bufnr, ctx.start, M.arg_items(candidates or {}))
    end)
end

--- Attach slash-command completion to a prompt input buffer, driven by `source`.
--- Sets the completefunc and a TextChangedI trigger; fuzzy in-menu filtering is
--- on and the menu never auto-inserts, so typing stays unaffected until the user
--- picks an item.
--- @param bufnr integer the input buffer
--- @param source tend.ui.SlashSource
function M.attach(bufnr, source)
    vim.bo[bufnr].completefunc =
        "v:lua.require'tend.ui.slash_complete'.complete_func"
    vim.bo[bufnr].completeopt = "menu,menuone,noinsert,noselect,fuzzy"
    -- Keep '-' a keyword char so task ids like t-1 do not close the menu.
    if not vim.bo[bufnr].iskeyword:find("-", 1, true) then
        vim.bo[bufnr].iskeyword = vim.bo[bufnr].iskeyword .. ",-"
    end
    vim.api.nvim_create_autocmd("TextChangedI", {
        buffer = bufnr,
        desc = "tend slash-command completion",
        callback = function()
            M._trigger(bufnr, source)
        end,
    })
end

return M
