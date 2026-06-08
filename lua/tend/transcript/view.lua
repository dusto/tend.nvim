--- Buffer-backed transcript view.
---
--- Owns a range-addressable transcript model and keeps a buffer in sync with it:
--- each applied event updates only the buffer rows the model reports as changed,
--- so a compaction summary collapses its range in place (rather than re-rendering
--- the whole transcript) and live appends touch only the tail. The buffer is
--- kept exactly equal to the model's lines.
local Model = require("tend.transcript.model")

--- @class tend.transcript.View
--- @field private model tend.transcript.Model
--- @field private bufnr integer
--- @field private initialized boolean buffer normalized past its initial line
local View = {}
View.__index = View

--- @class tend.transcript.ViewOpts : tend.transcript.ModelOpts

--- @param bufnr integer
--- @param opts? tend.transcript.ViewOpts
--- @return tend.transcript.View
function View.new(bufnr, opts)
    return setmetatable({
        model = Model.new(opts),
        bufnr = bufnr,
        initialized = false,
    }, View)
end

--- Apply an event envelope: update the model and the buffer region it changed.
--- @param event table
function View:apply(event)
    local change = self.model:apply(event)
    if not change then
        return
    end
    if not self.initialized then
        -- Replace the buffer's initial empty line with the full render, so from
        -- here on the buffer's rows line up with the model's line offsets.
        self:set_lines(0, -1, self.model:lines())
        self.initialized = true
        return
    end
    self:set_lines(change.start_row, change.end_row, change.lines)
end

--- @private
--- @param start_row integer
--- @param end_row integer -1 for "to end of buffer"
--- @param lines string[]
function View:set_lines(start_row, end_row, lines)
    if not vim.api.nvim_buf_is_valid(self.bufnr) then
        return
    end
    local modifiable = vim.bo[self.bufnr].modifiable
    if not modifiable then
        vim.bo[self.bufnr].modifiable = true
    end
    vim.api.nvim_buf_set_lines(self.bufnr, start_row, end_row, false, lines)
    if not modifiable then
        vim.bo[self.bufnr].modifiable = false
    end
end

--- Track this view's stream on a subscriber so each event updates the buffer.
--- @param subscriber tend.rpc.StreamSubscriber
--- @param spec { workspace_id: string, stream_id: string }
function View:attach(subscriber, spec)
    subscriber:track({
        workspace_id = spec.workspace_id,
        stream_id = spec.stream_id,
        on_event = function(event)
            self:apply(event)
        end,
    })
end

return View
