local assert = require("tests.helpers.assert")
local Model = require("tend.transcript.model")

-- A deterministic renderer: each event becomes one line "<seq>:<text>", each
-- summary one line "S<from>-<to>". Keeps assertions about ranges precise.
local function render(event)
    if event.kind == "summary" then
        local info = event.summary
        return { "S" .. info.from_seq .. "-" .. info.to_seq }
    end
    return { event.seq .. ":" .. (event.payload.text or "") }
end

local function ev(seq, text)
    return {
        kind = "event",
        type = "agent_message_chunk",
        seq = seq,
        cursor_seq = seq,
        payload = { text = text or "x" },
    }
end

local function summary(from, to)
    return {
        kind = "summary",
        type = "summary",
        seq = from,
        cursor_seq = to,
        summary = { from_seq = from, to_seq = to },
        payload = {},
    }
end

local function new()
    return Model.new({ render = render })
end

describe("tend.transcript.model append", function()
    it("appends events as line blocks in order", function()
        local m = new()
        m:apply(ev(1, "a"))
        m:apply(ev(2, "b"))
        assert.same(m:lines(), { "1:a", "2:b" })
        assert.same(m:entry_seqs(), { 1, 2 })
    end)

    it("returns the inserted row range for an append", function()
        local m = new()
        assert.same(m:apply(ev(1)), {
            start_row = 0,
            end_row = 0,
            lines = { "1:x" },
        })
        assert.same(m:apply(ev(2)), {
            start_row = 1,
            end_row = 1,
            lines = { "2:x" },
        })
    end)

    it("inserts an out-of-order seq at its sorted position", function()
        local m = new()
        m:apply(ev(1))
        m:apply(ev(3))
        local change = m:apply(ev(2))
        assert.same(m:entry_seqs(), { 1, 2, 3 })
        assert.same(change, { start_row = 1, end_row = 1, lines = { "2:x" } })
    end)

    it("ignores a duplicate event seq", function()
        local m = new()
        m:apply(ev(1))
        assert.is_nil(m:apply(ev(1)))
        assert.same(m:entry_seqs(), { 1 })
    end)

    it("renders multi-line blocks and offsets correctly", function()
        local m = Model.new({
            render = function(e)
                return vim.split(e.payload.text, "\n", { plain = true })
            end,
        })
        m:apply(ev(1, "a\nb"))
        local change = m:apply(ev(2, "c"))
        -- The second block starts after the two lines of the first.
        assert.same(change, { start_row = 2, end_row = 2, lines = { "c" } })
        assert.same(m:lines(), { "a", "b", "c" })
    end)
end)

describe("tend.transcript.model summary range-replacement", function()
    it("replaces the events in [from,to] with one summary block", function()
        local m = new()
        m:apply(ev(1))
        m:apply(ev(2))
        m:apply(ev(3))
        m:apply(ev(4))
        local change = m:apply(summary(2, 3))
        -- Entries 2 and 3 (rows 1..2) collapse into the summary at row 1.
        assert.same(change, { start_row = 1, end_row = 3, lines = { "S2-3" } })
        assert.same(m:entry_seqs(), { 1, 2, 4 })
        assert.same(m:lines(), { "1:x", "S2-3", "4:x" })
    end)

    it("collapses leading events and keeps later ones exact", function()
        local m = new()
        for s = 1, 5 do
            m:apply(ev(s))
        end
        m:apply(summary(1, 3))
        assert.same(m:lines(), { "S1-3", "4:x", "5:x" })
        -- A later event continues after the range.
        m:apply(ev(6))
        assert.same(m:lines(), { "S1-3", "4:x", "5:x", "6:x" })
    end)

    it("drops raw events already subsumed by a summary", function()
        local m = new()
        m:apply(ev(1))
        m:apply(summary(1, 3))
        -- A redelivered raw event inside the range must not reappear.
        assert.is_nil(m:apply(ev(2)))
        assert.same(m:lines(), { "S1-3" })
    end)

    it("applies a summary even when no raw events were rendered", function()
        local m = new()
        m:apply(ev(5))
        local change = m:apply(summary(1, 3))
        -- Inserted before seq 5 (at row 0), replacing nothing.
        assert.same(change, { start_row = 0, end_row = 0, lines = { "S1-3" } })
        assert.same(m:entry_seqs(), { 1, 5 })
        assert.same(m:lines(), { "S1-3", "5:x" })
    end)

    it("ignores a duplicate summary for the same range", function()
        local m = new()
        m:apply(ev(1))
        m:apply(ev(2))
        m:apply(summary(1, 2))
        assert.is_nil(m:apply(summary(1, 2)))
        assert.same(m:lines(), { "S1-2" })
    end)
end)
