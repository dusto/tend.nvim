--- A one-shot detail float for a single turn (48d.36 layer 3): the markdown the
--- turn_inspector renders, shown with native markdown-heading folds so each
--- ## section (Prompt / Context / Tokens / Tools & MCP) collapses independently.
--- Modeled on `session_info` (centered markdown float, q / <Esc> / BufLeave to
--- close) but folds the sections rather than staying live.
local BufHelpers = require("tend.utils.buf_helpers")

--- @class tend.ui.TurnInspectorView
--- @field private buf? integer
--- @field private win? integer
--- @field private tab_page_id? integer
local TurnInspectorView = {}
TurnInspectorView.__index = TurnInspectorView

local M = {}
M.TurnInspectorView = TurnInspectorView

--- Fold level for a line, driving the section folds: a `## ` heading opens a new
--- level-1 fold; every other line continues the current one. Kept as a plain
--- function (not just an inline foldexpr) so the rule is unit-testable.
--- @param line string
--- @return string level a foldexpr verdict (">1" starts a fold, "=" continues)
function M.fold_level(line)
    if line:match("^## ") then
        return ">1"
    end
    return "="
end

--- The foldexpr bound on the float window; reads the current line via v:lnum.
--- @return string
function M.foldexpr()
    return M.fold_level(vim.fn.getline(vim.v.lnum))
end

--- @return tend.ui.TurnInspectorView
function TurnInspectorView.new()
    return setmetatable({}, TurnInspectorView)
end

--- Whether the float is currently open.
--- @return boolean
function TurnInspectorView:is_open()
    return self.win ~= nil and vim.api.nvim_win_is_valid(self.win)
end

--- Open (or relocate) the float showing lines, with section folds. If already
--- open in the current tabpage it re-renders in place; open in another tabpage,
--- it relocates to the current one so the single float follows the user.
--- @param lines string[]
function TurnInspectorView:show(lines)
    if self:is_open() then
        if self.tab_page_id == vim.api.nvim_get_current_tabpage() then
            self:_render(lines)
            return
        end
        self:close()
    end

    local buf = vim.api.nvim_create_buf(false, true)
    self.buf = buf
    vim.bo[buf].filetype = "markdown"
    vim.bo[buf].bufhidden = "wipe"
    self:_render(lines)

    local width = math.floor(vim.o.columns * 0.5)
    local height = math.max(math.min(#lines + 2, vim.o.lines - 4), 6)
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        row = math.floor((vim.o.lines - height) / 2),
        col = math.floor((vim.o.columns - width) / 2),
        style = "minimal",
        border = "rounded",
        title = " Turn detail ",
        title_pos = "center",
        footer = " za fold · q / <Esc> close ",
        footer_pos = "right",
    })
    self.win = win
    self.tab_page_id = vim.api.nvim_win_get_tabpage(win)
    vim.wo[win][0].wrap = true
    vim.wo[win][0].linebreak = true
    -- Section folds: level-1 fold per `## ` heading, all open initially so the
    -- content is visible; the user collapses sections with za.
    vim.wo[win][0].foldmethod = "expr"
    vim.wo[win][0].foldexpr =
        "v:lua.require'tend.ui.turn_inspector_view'.foldexpr()"
    vim.wo[win][0].foldenable = true
    vim.wo[win][0].foldlevel = 99

    local function close()
        self:close()
    end
    BufHelpers.keymap_set(buf, "n", "q", close)
    BufHelpers.keymap_set(buf, "n", "<Esc>", close)
    vim.api.nvim_create_autocmd("BufLeave", {
        buffer = buf,
        once = true,
        callback = function()
            vim.schedule(close)
        end,
    })
end

--- @private
--- @param lines string[]
function TurnInspectorView:_render(lines)
    if not self.buf or not vim.api.nvim_buf_is_valid(self.buf) then
        return
    end
    vim.bo[self.buf].modifiable = true
    vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
    vim.bo[self.buf].modifiable = false
end

--- Close the float and drop its handles. Idempotent.
function TurnInspectorView:close()
    local win = self.win
    self.win = nil
    self.tab_page_id = nil
    self.buf = nil
    if win and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
    end
end

return M
