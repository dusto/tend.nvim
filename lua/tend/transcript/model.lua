--- Range-addressable transcript model.
---
--- A session's events arrive in seq order; each is rendered into a block of
--- lines kept as one entry keyed by its seq. The model is range-addressable, not
--- append-only: a compaction summary record for `[from_seq, to_seq]` replaces
--- the entries (and the lines) of every event in that range with a single
--- summary block, rather than appending at from_seq. See the events spec,
--- "Client renders a summary as a range replacement, not an append."
---
--- apply() returns the buffer edit it made — a 0-based [start_row, end_row) row
--- range and the replacement lines — so a view can update just the affected
--- region instead of re-rendering the whole transcript.
local Render = require("tend.transcript.render")

--- @class tend.transcript.Entry
--- @field seq integer first seq the entry represents
--- @field to_seq integer last seq subsumed (== seq for a normal event)
--- @field kind string "event" | "summary"
--- @field lines string[] rendered display lines

--- @class tend.transcript.Change
--- @field start_row integer 0-based first row replaced
--- @field end_row integer 0-based exclusive end of the replaced (old) extent
--- @field lines string[] replacement lines

--- @class tend.transcript.Model
--- @field private entries tend.transcript.Entry[] ordered by seq
--- @field private render fun(event: table): string[]
local Model = {}
Model.__index = Model

--- @class tend.transcript.ModelOpts
--- @field render? fun(event: table): string[] Override the default renderer.

--- @param opts? tend.transcript.ModelOpts
--- @return tend.transcript.Model
function Model.new(opts)
    opts = opts or {}
    return setmetatable({
        entries = {},
        render = opts.render or Render.render,
    }, Model)
end

--- @private
--- Number of lines before entry index idx (1-based).
--- @param idx integer
--- @return integer
function Model:offset(idx)
    local n = 0
    for i = 1, idx - 1 do
        n = n + #self.entries[i].lines
    end
    return n
end

--- Apply an event envelope, returning the buffer edit it produced, or nil if the
--- record was a duplicate or already subsumed by a summary.
--- @param event table
--- @return tend.transcript.Change?
function Model:apply(event)
    if event.kind == "summary" then
        return self:apply_summary(event)
    end
    return self:apply_event(event)
end

--- @private
--- @param event table
--- @return tend.transcript.Change?
function Model:apply_event(event)
    local seq = event.seq
    local pos = #self.entries + 1
    for i, e in ipairs(self.entries) do
        if e.kind == "summary" and seq >= e.seq and seq <= e.to_seq then
            return nil -- already represented by a summary range
        end
        if e.seq == seq and e.kind == "event" then
            return nil -- duplicate
        end
        if e.seq > seq then
            pos = i
            break
        end
    end
    local lines = self.render(event)
    local start_row = self:offset(pos)
    table.insert(self.entries, pos, {
        seq = seq,
        to_seq = seq,
        kind = "event",
        lines = lines,
    })
    return { start_row = start_row, end_row = start_row, lines = lines }
end

--- @private
--- @param event table
--- @return tend.transcript.Change?
function Model:apply_summary(event)
    local info = event.summary or {}
    local from = info.from_seq or event.seq
    local to = info.to_seq or from
    for _, e in ipairs(self.entries) do
        if e.kind == "summary" and e.seq == from and e.to_seq == to then
            return nil -- this summary range is already applied
        end
    end

    local lines = self.render(event)
    -- The contiguous block of entries whose seqs fall in [from, to].
    local first, last
    for i, e in ipairs(self.entries) do
        if e.seq >= from and e.seq <= to then
            first = first or i
            last = i
        end
    end

    local pos, start_row, end_row
    if first then
        pos = first
        start_row = self:offset(first)
        end_row = start_row
        for i = first, last do
            end_row = end_row + #self.entries[i].lines
        end
        for _ = first, last do
            table.remove(self.entries, first)
        end
    else
        -- Nothing was rendered for the range; insert at its sorted position.
        pos = #self.entries + 1
        for i, e in ipairs(self.entries) do
            if e.seq > to then
                pos = i
                break
            end
        end
        start_row = self:offset(pos)
        end_row = start_row
    end

    table.insert(self.entries, pos, {
        seq = from,
        to_seq = to,
        kind = "summary",
        lines = lines,
    })
    return { start_row = start_row, end_row = end_row, lines = lines }
end

--- The full transcript as a flat list of display lines.
--- @return string[]
function Model:lines()
    local out = {}
    for _, e in ipairs(self.entries) do
        for _, l in ipairs(e.lines) do
            out[#out + 1] = l
        end
    end
    return out
end

--- The seq of each entry, in order (for tests/inspection).
--- @return integer[]
function Model:entry_seqs()
    local out = {}
    for i, e in ipairs(self.entries) do
        out[i] = e.seq
    end
    return out
end

return Model
