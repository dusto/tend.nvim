local assert = require("tests.helpers.assert")
local ProtocolLog = require("tend.daemon.protocol_log")

describe("tend.daemon.protocol_log", function()
    it("retains recorded entries oldest-first with climbing seq", function()
        local log = ProtocolLog.new()
        log:record({ kind = "request", dir = "out", method = "a", id = 1 })
        log:record({ kind = "notification", dir = "in", method = "b" })

        local entries = log:entries()
        assert.equal(2, #entries)
        assert.equal("a", entries[1].method)
        assert.equal(1, entries[1].seq)
        assert.equal("b", entries[2].method)
        assert.equal(2, entries[2].seq)
        -- Each entry is stamped with a wall-clock time string.
        assert.is_not_nil(entries[1].ts:match("%d%d:%d%d:%d%d"))
    end)

    it("evicts the oldest entry past capacity", function()
        local log = ProtocolLog.new(2)
        log:record({ kind = "request", dir = "out", method = "first" })
        log:record({ kind = "request", dir = "out", method = "second" })
        log:record({ kind = "request", dir = "out", method = "third" })

        local entries = log:entries()
        assert.equal(2, #entries)
        -- "first" was evicted; the window holds the two most recent.
        assert.equal("second", entries[1].method)
        assert.equal("third", entries[2].method)
        -- seq keeps climbing even as entries are evicted.
        assert.equal(3, entries[2].seq)
    end)

    it("clear drops entries but keeps the sequence climbing", function()
        local log = ProtocolLog.new()
        log:record({ kind = "request", dir = "out", method = "a" })
        log:clear()
        assert.equal(0, #log:entries())

        log:record({ kind = "request", dir = "out", method = "b" })
        -- The post-clear entry sorts after the cleared one.
        assert.equal(2, log:entries()[1].seq)
    end)

    it("render_lines shows direction, method, and response outcome", function()
        local log = ProtocolLog.new()
        log:record({
            kind = "request",
            dir = "out",
            method = "session.prompt",
            id = 7,
        })
        log:record({
            kind = "response",
            dir = "in",
            method = "session.prompt",
            id = 7,
            ok = true,
            elapsed_ms = 12,
        })
        log:record({
            kind = "response",
            dir = "in",
            method = "task.show",
            id = 8,
            ok = false,
            err = "not found",
        })
        log:record({ kind = "notification", dir = "in", method = "event.push" })
        log:record({ kind = "connection", status = "connected" })

        local lines = log:render_lines()
        assert.equal(5, #lines)
        assert.is_not_nil(lines[1]:find("->", 1, true))
        assert.is_not_nil(lines[1]:find("request session.prompt #7", 1, true))
        assert.is_not_nil(lines[2]:find("<-", 1, true))
        assert.is_not_nil(
            lines[2]:find("response session.prompt #7 ok (12ms)", 1, true)
        )
        assert.is_not_nil(lines[3]:find("err: not found", 1, true))
        assert.is_not_nil(lines[4]:find("notification event.push", 1, true))
        assert.is_not_nil(lines[5]:find("connection connected", 1, true))
    end)
end)
