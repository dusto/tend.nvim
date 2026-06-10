--- Floating-window view over the pending-approval model.
---
--- Owns one scratch buffer and one float: the buffer renders the focused
--- approval (decision context + diff preview straight from the payload) with a
--- footer of buffer-local keymaps — approve/deny respond through the injected
--- callback, next/prev move the model's focus, hide closes the float while the
--- approval stays pending. show() opens (or moves) the float in the current
--- tabpage; refresh() repaints in place and closes the float once nothing is
--- pending. All state is instance-owned.
local BufHelpers = require("tend.utils.buf_helpers")
local Render = require("tend.approval.render")

local NS = vim.api.nvim_create_namespace("tend_approval")

local M = {}

--- @class tend.approval.ViewKeys
--- @field approve string
--- @field deny string
--- @field next string
--- @field prev string
--- @field hide string

--- @type tend.approval.ViewKeys
M.DEFAULT_KEYS = {
    approve = "a",
    deny = "d",
    next = "n",
    prev = "p",
    hide = "q",
}

--- @class tend.approval.View
--- @field private model tend.approval.Model
--- @field private respond fun(approval_id: string, approved: boolean)
--- @field private keys tend.approval.ViewKeys
--- @field private buf integer|nil scratch buffer, created on first show
--- @field private win integer|nil float window, nil while hidden
local View = {}
View.__index = View
M.View = View

--- @class tend.approval.ViewOpts
--- @field respond fun(approval_id: string, approved: boolean)
--- @field keys? tend.approval.ViewKeys

--- @param model tend.approval.Model
--- @param opts tend.approval.ViewOpts
--- @return tend.approval.View
function View.new(model, opts)
    return setmetatable({
        model = model,
        respond = opts.respond,
        keys = vim.tbl_extend("force", M.DEFAULT_KEYS, opts.keys or {}),
        buf = nil,
        win = nil,
    }, View)
end

--- Open (or move to the current tabpage) the float and render the focused
--- approval. A no-op when nothing is pending.
function View:show()
    if self.model:count() == 0 then
        return
    end
    self:render()
    self:open_win()
end

--- Repaint the focused approval in place; closes the float when the model is
--- empty. Never opens a hidden float.
function View:refresh()
    if self.model:count() == 0 then
        self:hide()
        return
    end
    if self:is_open() then
        self:render()
    end
end

--- Close the float; pending approvals are untouched.
function View:hide()
    if self.win and vim.api.nvim_win_is_valid(self.win) then
        vim.api.nvim_win_close(self.win, true)
    end
    self.win = nil
end

--- @return boolean
function View:is_open()
    return self.win ~= nil and vim.api.nvim_win_is_valid(self.win)
end

--- @return integer|nil
function View:bufnr()
    return self.buf
end

--- @return integer|nil
function View:winid()
    return self.win
end

--- @private
--- The footer of available keys, with the queue position when several
--- approvals are pending.
--- @return string
function View:footer()
    local k = self.keys
    local footer = k.approve
        .. " approve · "
        .. k.deny
        .. " deny · "
        .. k.next
        .. "/"
        .. k.prev
        .. " next/prev · "
        .. k.hide
        .. " hide"
    if self.model:count() > 1 then
        footer = self.model:focused_index()
            .. "/"
            .. self.model:count()
            .. " · "
            .. footer
    end
    return footer
end

--- @private
--- Render the focused approval into the scratch buffer (creating it on first
--- use) and paint the highlight marks.
function View:render()
    local approval = self.model:focused()
    if not approval then
        return
    end
    local buf = self:ensure_buf()
    local lines, marks = Render.render(approval)
    table.insert(lines, "")
    table.insert(lines, self:footer())

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false

    vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
    table.insert(marks, { row = #lines - 1, group = "Comment" })
    for _, mark in ipairs(marks) do
        vim.api.nvim_buf_set_extmark(buf, NS, mark.row, 0, {
            end_row = mark.row + 1,
            end_col = 0,
            hl_group = mark.group,
        })
    end
end

--- @private
--- @return integer bufnr
function View:ensure_buf()
    if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
        return self.buf
    end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].filetype = "tend-approval"
    self.buf = buf

    local k = self.keys
    BufHelpers.keymap_set(buf, "n", k.approve, function()
        self:decide(true)
    end, { desc = "Approval: approve" })
    BufHelpers.keymap_set(buf, "n", k.deny, function()
        self:decide(false)
    end, { desc = "Approval: deny" })
    BufHelpers.keymap_set(buf, "n", k.next, function()
        self.model:cycle(1)
        self:render()
    end, { desc = "Approval: focus next" })
    BufHelpers.keymap_set(buf, "n", k.prev, function()
        self.model:cycle(-1)
        self:render()
    end, { desc = "Approval: focus previous" })
    BufHelpers.keymap_set(buf, "n", k.hide, function()
        self:hide()
    end, { desc = "Approval: hide (stays pending)" })
    return buf
end

--- @private
--- @param approved boolean
function View:decide(approved)
    local approval = self.model:focused()
    if approval then
        self.respond(approval.approval_id, approved)
    end
end

--- @private
--- Open the float in the current tabpage, or move it there when it is open in
--- another one (the user must see the prompt where they are).
function View:open_win()
    local tab = vim.api.nvim_get_current_tabpage()
    if self:is_open() then
        if vim.api.nvim_win_get_tabpage(self.win) == tab then
            return
        end
        self:hide()
    end
    local lines = vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
    local width = 60
    for _, line in ipairs(lines) do
        width = math.max(width, vim.fn.strdisplaywidth(line))
    end
    width = math.min(width, math.max(20, vim.o.columns - 8))
    local height = math.min(#lines, math.max(4, vim.o.lines - 8))
    self.win = vim.api.nvim_open_win(self.buf, true, {
        relative = "editor",
        width = width,
        height = height,
        row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
        col = math.max(0, math.floor((vim.o.columns - width) / 2)),
        style = "minimal",
        border = "rounded",
        title = " approval ",
        title_pos = "center",
    })
end

return M
