--- A live, single-instance detail float for one session's info + token/context
--- usage. Unlike `floating_message` (one-shot, closes on leave), this stays open
--- and re-renders in place as new usage events arrive, so the numbers update
--- live while the user is reading. Bound to the tabpage it opens in and closed on
--- q / <Esc> / BufLeave.
local BufHelpers = require("tend.utils.buf_helpers")

--- @class tend.ui.SessionInfoView
--- @field private buf? integer
--- @field private win? integer
--- @field private tab_page_id? integer
local SessionInfoView = {}
SessionInfoView.__index = SessionInfoView

local M = {}
M.SessionInfoView = SessionInfoView

--- @return tend.ui.SessionInfoView
function SessionInfoView.new()
    return setmetatable({}, SessionInfoView)
end

--- Whether the float is currently open (valid window in the bound tabpage).
--- @return boolean
function SessionInfoView:is_open()
    return self.win ~= nil and vim.api.nvim_win_is_valid(self.win)
end

--- Write lines into the (modifiable-guarded) buffer.
--- @private
--- @param lines string[]
function SessionInfoView:_render(lines)
    if not self.buf or not vim.api.nvim_buf_is_valid(self.buf) then
        return
    end
    vim.bo[self.buf].modifiable = true
    vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
    vim.bo[self.buf].modifiable = false
end

--- Open the float (or re-render if already open) with the given lines.
--- @param lines string[]
function SessionInfoView:show(lines)
    if self:is_open() then
        self:_render(lines)
        return
    end

    local buf = vim.api.nvim_create_buf(false, true)
    self.buf = buf
    vim.bo[buf].filetype = "markdown"
    vim.bo[buf].bufhidden = "wipe"
    self:_render(lines)

    local width = math.floor(vim.o.columns * 0.5)
    local height = math.max(#lines + 2, 6)
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        row = math.floor((vim.o.lines - height) / 2),
        col = math.floor((vim.o.columns - width) / 2),
        style = "minimal",
        border = "rounded",
        title = " Session usage ",
        title_pos = "center",
        footer = " q or <Esc> to close ",
        footer_pos = "right",
    })
    self.win = win
    self.tab_page_id = vim.api.nvim_win_get_tabpage(win)
    vim.wo[win][0].wrap = true
    vim.wo[win][0].linebreak = true

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

--- Re-render the float in place if it is open; a no-op otherwise.
--- @param lines string[]
function SessionInfoView:refresh(lines)
    if self:is_open() then
        self:_render(lines)
    end
end

--- Close the float and drop its handles. Idempotent.
function SessionInfoView:close()
    local win = self.win
    self.win = nil
    self.tab_page_id = nil
    self.buf = nil
    if win and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
    end
end

return M
