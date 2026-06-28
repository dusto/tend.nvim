-- The fake client below stands in for tend.rpc.Client (a structural subset plus
-- test-only drivers), so it does not satisfy the full class at call sites.
--- @diagnostic disable: param-type-mismatch
local assert = require("tests.helpers.assert")
local sub_mod = require("tend.rpc.stream_subscriber")
local StreamSubscriber = sub_mod.StreamSubscriber

-- A fake RPC client capturing requests/notifications and exposing the registered
-- notification handlers so tests can drive inbound traffic.
local function fake_client()
    local c = { sent = {}, notifs = {}, handlers = {} }
    function c:request(method, params, cb)
        table.insert(self.sent, { method = method, params = params, cb = cb })
    end
    function c:notify(method, params)
        table.insert(self.notifs, { method = method, params = params })
    end
    function c:on_notification(method, handler)
        self.handlers[method] = handler
    end
    -- Deliver an inbound event.push.
    function c:push(event)
        self.handlers[sub_mod.METHOD_PUSH]({ event = event })
    end
    -- Deliver an inbound event.subscription_closed.
    function c:close_stream(stream_id)
        self.handlers[sub_mod.METHOD_SUBSCRIPTION_CLOSED]({
            stream_id = stream_id,
        })
    end
    -- The most recent events.subscribe request (with its callback).
    function c:last_subscribe()
        for i = #self.sent, 1, -1 do
            if self.sent[i].method == sub_mod.METHOD_SUBSCRIBE then
                return self.sent[i]
            end
        end
    end
    return c
end

local function ev(stream_id, seq, cursor_seq)
    return {
        stream_id = stream_id,
        seq = seq,
        cursor_seq = cursor_seq or seq,
        type = "agent_message_chunk",
    }
end

describe("tend.rpc.stream_subscriber subscribe", function()
    it("subscribes every tracked stream from cursor 0 on bootstrap", function()
        local sub = StreamSubscriber.new()
        sub:track({
            workspace_id = "ws",
            stream_id = "session:s1",
            on_event = function() end,
        })
        sub:track({
            workspace_id = "ws",
            stream_id = "workspace:ws",
            on_event = function() end,
        })
        local c = fake_client()
        sub:bootstrap(c, "e1")

        local subs = {}
        for _, req in ipairs(c.sent) do
            if req.method == sub_mod.METHOD_SUBSCRIBE then
                subs[req.params.stream_id] = req.params.last_seq
            end
        end
        assert.same(subs, { ["session:s1"] = 0, ["workspace:ws"] = 0 })
    end)

    it("subscribes immediately when tracking while connected", function()
        local sub = StreamSubscriber.new()
        local c = fake_client()
        sub:bootstrap(c, "e1")
        sub:track({
            workspace_id = "ws",
            stream_id = "session:s1",
            on_event = function() end,
        })
        assert.equal(c:last_subscribe().params.stream_id, "session:s1")
    end)

    it("re-tracking swaps the listener without re-subscribing", function()
        local sub = StreamSubscriber.new()
        local first, second = 0, 0
        sub:track({
            workspace_id = "ws",
            stream_id = "session:s1",
            on_event = function()
                first = first + 1
            end,
        })
        local c = fake_client()
        sub:bootstrap(c, "e1")
        -- Re-track to swap the listener; the daemon rejects duplicate
        -- subscribes, so no second events.subscribe must be sent.
        sub:track({
            workspace_id = "ws",
            stream_id = "session:s1",
            on_event = function()
                second = second + 1
            end,
        })
        local count = 0
        for _, req in ipairs(c.sent) do
            if req.method == sub_mod.METHOD_SUBSCRIBE then
                count = count + 1
            end
        end
        assert.equal(count, 1)
        c:push(ev("session:s1", 1))
        assert.equal(first, 0)
        assert.equal(second, 1)
    end)

    it("defers subscription until bootstrap when disconnected", function()
        local sub = StreamSubscriber.new()
        sub:track({
            workspace_id = "ws",
            stream_id = "session:s1",
            on_event = function() end,
        })
        local c = fake_client()
        -- Nothing sent yet: no client bound.
        assert.equal(#c.sent, 0)
        sub:bootstrap(c, "e1")
        assert.is_not_nil(c:last_subscribe())
    end)
end)

describe("tend.rpc.stream_subscriber delivery", function()
    it("routes events in order and advances the cursor", function()
        local sub = StreamSubscriber.new()
        local got = {}
        sub:track({
            workspace_id = "ws",
            stream_id = "session:s1",
            on_event = function(e)
                table.insert(got, e.seq)
            end,
        })
        local c = fake_client()
        sub:bootstrap(c, "e1")
        c:push(ev("session:s1", 1))
        c:push(ev("session:s1", 2))
        assert.same(got, { 1, 2 })
        assert.equal(sub:cursor("ws", "session:s1"), 2)
    end)

    it("dedups already-seen seqs (at-least-once)", function()
        local sub = StreamSubscriber.new()
        local count = 0
        sub:track({
            workspace_id = "ws",
            stream_id = "session:s1",
            on_event = function()
                count = count + 1
            end,
        })
        local c = fake_client()
        sub:bootstrap(c, "e1")
        c:push(ev("session:s1", 1))
        c:push(ev("session:s1", 1)) -- duplicate
        c:push(ev("session:s1", 2))
        c:push(ev("session:s1", 1)) -- old replay
        assert.equal(count, 2)
        assert.equal(sub:cursor("ws", "session:s1"), 2)
    end)

    it("delivers a summary sharing a seq with an already-seen event", function()
        local sub = StreamSubscriber.new()
        local got = {}
        sub:track({
            workspace_id = "ws",
            stream_id = "session:s1",
            on_event = function(e)
                table.insert(got, e.kind or e.type)
            end,
        })
        local c = fake_client()
        sub:bootstrap(c, "e1")
        -- A raw event at seq 1 advances the cursor; a summary for [1,3] also
        -- carries seq 1. The cursor check would drop it, but kind-aware dedup
        -- must deliver it (records are distinct by stream_id + seq + kind).
        c:push(ev("session:s1", 1))
        c:push({
            stream_id = "session:s1",
            seq = 1,
            cursor_seq = 3,
            kind = "summary",
        })
        assert.same(got, { "agent_message_chunk", "summary" })
    end)

    it("reset_cursor makes the next subscribe replay from 0", function()
        local sub = StreamSubscriber.new()
        sub:track({
            workspace_id = "ws",
            stream_id = "session:s1",
            on_event = function() end,
        })
        local c = fake_client()
        sub:bootstrap(c, "e1")
        c:push(ev("session:s1", 1))
        c:push(ev("session:s1", 2))
        assert.equal(sub:cursor("ws", "session:s1"), 2)

        -- Reset, then a fresh bootstrap (re-attach) subscribes from 0 so the
        -- daemon replays the retained history.
        sub:reset_cursor("ws", "session:s1")
        assert.equal(sub:cursor("ws", "session:s1"), 0)

        local c2 = fake_client()
        sub:bootstrap(c2, "e1")
        assert.equal(c2:last_subscribe().params.last_seq, 0)
    end)

    it("dedups a replayed summary record", function()
        local sub = StreamSubscriber.new()
        local count = 0
        sub:track({
            workspace_id = "ws",
            stream_id = "session:s1",
            on_event = function()
                count = count + 1
            end,
        })
        local c = fake_client()
        sub:bootstrap(c, "e1")
        local summary = {
            stream_id = "session:s1",
            seq = 1,
            cursor_seq = 3,
            kind = "summary",
        }
        c:push(summary)
        c:push(summary) -- replay on reconnect
        assert.equal(count, 1)
    end)

    it("advances the cursor to cursor_seq for a summary record", function()
        local sub = StreamSubscriber.new()
        sub:track({
            workspace_id = "ws",
            stream_id = "session:s1",
            on_event = function() end,
        })
        local c = fake_client()
        sub:bootstrap(c, "e1")
        -- A summary collapses [1,10]: seq=from, cursor_seq=to, kind=summary.
        c:push({
            stream_id = "session:s1",
            seq = 1,
            cursor_seq = 10,
            kind = "summary",
        })
        assert.equal(sub:cursor("ws", "session:s1"), 10)
        -- The next raw record continues after the range.
        local seen = false
        sub:track({
            workspace_id = "ws",
            stream_id = "session:s1",
            on_event = function()
                seen = true
            end,
        })
        c:push(ev("session:s1", 11))
        assert.is_true(seen)
    end)

    it("ignores events for an untracked stream", function()
        local sub = StreamSubscriber.new()
        local count = 0
        sub:track({
            workspace_id = "ws",
            stream_id = "session:s1",
            on_event = function()
                count = count + 1
            end,
        })
        local c = fake_client()
        sub:bootstrap(c, "e1")
        c:push(ev("session:other", 1))
        assert.equal(count, 0)
    end)

    it("does not advance the cursor when the listener errors", function()
        local errors = {}
        local sub = StreamSubscriber.new({
            on_error = function(m)
                table.insert(errors, m)
            end,
        })
        sub:track({
            workspace_id = "ws",
            stream_id = "session:s1",
            on_event = function()
                error("boom")
            end,
        })
        local c = fake_client()
        sub:bootstrap(c, "e1")
        c:push(ev("session:s1", 1))
        assert.equal(#errors, 1)
        assert.equal(sub:cursor("ws", "session:s1"), 0)
    end)
end)

describe("tend.rpc.stream_subscriber reconnect", function()
    it("resumes from the stored cursor on a new connection", function()
        local sub = StreamSubscriber.new()
        sub:track({
            workspace_id = "ws",
            stream_id = "session:s1",
            on_event = function() end,
        })
        local c1 = fake_client()
        sub:bootstrap(c1, "e1")
        c1:push(ev("session:s1", 1))
        c1:push(ev("session:s1", 2))

        sub:disconnected()
        local c2 = fake_client()
        sub:bootstrap(c2, "e1") -- same epoch
        assert.equal(c2:last_subscribe().params.last_seq, 2)
    end)

    it("resets cursors and resumes from 0 on a new daemon epoch", function()
        local sub = StreamSubscriber.new()
        sub:track({
            workspace_id = "ws",
            stream_id = "session:s1",
            on_event = function() end,
        })
        local c1 = fake_client()
        sub:bootstrap(c1, "e1")
        c1:push(ev("session:s1", 5))

        sub:disconnected()
        local c2 = fake_client()
        sub:bootstrap(c2, "e2") -- daemon restarted
        assert.equal(c2:last_subscribe().params.last_seq, 0)
        assert.equal(sub:cursor("ws", "session:s1"), 0)
    end)

    it(
        "resubscribes one stream from its cursor on subscription_closed",
        function()
            local sub = StreamSubscriber.new()
            sub:track({
                workspace_id = "ws",
                stream_id = "session:s1",
                on_event = function() end,
            })
            local c = fake_client()
            sub:bootstrap(c, "e1")
            c:push(ev("session:s1", 3))
            c:close_stream("session:s1")
            assert.equal(c:last_subscribe().params.last_seq, 3)
        end
    )
end)

describe("tend.rpc.stream_subscriber errors", function()
    it("resumes below the boundary on a compacted cursor", function()
        local sub = StreamSubscriber.new()
        sub:track({
            workspace_id = "ws",
            stream_id = "session:s1",
            on_event = function() end,
        })
        local c = fake_client()
        sub:bootstrap(c, "e1")
        -- Reject the subscribe with cursor_compacted; boundary is the summary
        -- from_seq, so we resume at boundary-1 to receive the summary record.
        c:last_subscribe().cb({
            code = sub_mod.ERR_CURSOR_COMPACTED,
            message = "compacted",
            data = { boundary_seq = 5 },
        })
        assert.equal(sub:cursor("ws", "session:s1"), 4)
        assert.equal(c:last_subscribe().params.last_seq, 4)
    end)

    it("reports a non-compaction subscribe error", function()
        local errors = {}
        local sub = StreamSubscriber.new({
            on_error = function(m)
                table.insert(errors, m)
            end,
        })
        sub:track({
            workspace_id = "ws",
            stream_id = "session:s1",
            on_event = function() end,
        })
        local c = fake_client()
        sub:bootstrap(c, "e1")
        c:last_subscribe().cb({ code = -32603, message = "internal" })
        assert.equal(#errors, 1)
    end)
end)

describe("tend.rpc.stream_subscriber untrack", function()
    it("unsubscribes and stops routing", function()
        local sub = StreamSubscriber.new()
        local count = 0
        sub:track({
            workspace_id = "ws",
            stream_id = "session:s1",
            on_event = function()
                count = count + 1
            end,
        })
        local c = fake_client()
        sub:bootstrap(c, "e1")
        sub:untrack("session:s1")

        assert.equal(c.notifs[1].method, sub_mod.METHOD_UNSUBSCRIBE)
        assert.equal(c.notifs[1].params.stream_id, "session:s1")
        c:push(ev("session:s1", 1))
        assert.equal(count, 0)
    end)
end)
