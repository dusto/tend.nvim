--- Resumable event-stream subscriptions over the daemon RPC client.
---
--- The plugin declares which logical streams it cares about with `track`; the
--- subscriber then, against whatever connection is current, subscribes to each
--- from its stored cursor (`events.subscribe` with `last_seq`), so the daemon
--- replays missed records before live ones. As `event.push` notifications
--- arrive it dedups them, advances the cursor, and hands the event to the
--- stream's listener.
---
--- Reconnect is `bootstrap`: the connection owner performs the daemon.hello
--- handshake and calls bootstrap with the fresh client and the daemon epoch.
--- A changed epoch invalidates stored cursors (see CursorStore); every tracked
--- stream is then re-subscribed from whatever cursor survives, so a reconnect
--- resumes exactly where the client left off (or from the start after a daemon
--- restart). `event.subscription_closed` (per-stream overflow) is handled the
--- same way: re-subscribe that one stream from its own cursor.
local CursorStore = require("tend.rpc.cursor_store")

local M = {}

-- Wire method names, matching the daemon contract.
M.METHOD_SUBSCRIBE = "events.subscribe"
M.METHOD_UNSUBSCRIBE = "events.unsubscribe"
M.METHOD_PUSH = "event.push"
M.METHOD_SUBSCRIPTION_CLOSED = "event.subscription_closed"

-- Error code for a cursor that predates the exact-replay retention window; the
-- accompanying data carries the boundary seq to resume from.
M.ERR_CURSOR_COMPACTED = 1001

--- @class tend.rpc.TrackedStream
--- @field workspace_id string
--- @field stream_id string
--- @field on_event fun(event: table)

--- @class tend.rpc.StreamSubscriber
--- @field private cursors tend.rpc.CursorStore
--- @field private client tend.rpc.Client? current connection, nil while down
--- @field private streams table<string, tend.rpc.TrackedStream> by stream_id
--- @field private on_error fun(msg: string)
local StreamSubscriber = {}
StreamSubscriber.__index = StreamSubscriber
M.StreamSubscriber = StreamSubscriber

--- @class tend.rpc.StreamSubscriberOpts
--- @field cursors? tend.rpc.CursorStore Shared cursor store (default: a new one).
--- @field on_error? fun(msg: string) Reports a subscribe/protocol error.

--- @param opts? tend.rpc.StreamSubscriberOpts
--- @return tend.rpc.StreamSubscriber
function StreamSubscriber.new(opts)
    opts = opts or {}
    return setmetatable({
        cursors = opts.cursors or CursorStore.new(),
        client = nil,
        streams = {},
        on_error = opts.on_error or function() end,
    }, StreamSubscriber)
end

--- Declare interest in a logical stream. on_event is called with each event's
--- envelope, in seq order, with replayed-then-live delivery. If already
--- connected, the subscription starts immediately; otherwise it starts on the
--- next bootstrap. Re-tracking a stream only swaps its listener — it does not
--- re-subscribe, since the daemon rejects a duplicate subscription and the live
--- one keeps delivering.
--- @param spec tend.rpc.TrackedStream
function StreamSubscriber:track(spec)
    local existing = self.streams[spec.stream_id]
    local stream = {
        workspace_id = spec.workspace_id,
        stream_id = spec.stream_id,
        on_event = spec.on_event,
    }
    self.streams[spec.stream_id] = stream
    if self.client and not existing then
        self:subscribe(stream)
    end
end

--- Drop interest in a stream: stop delivery on the daemon and forget the
--- listener. The cursor is kept so re-tracking resumes where it left off.
--- @param stream_id string
function StreamSubscriber:untrack(stream_id)
    local stream = self.streams[stream_id]
    if not stream then
        return
    end
    self.streams[stream_id] = nil
    if self.client then
        self.client:notify(M.METHOD_UNSUBSCRIBE, { stream_id = stream_id })
    end
end

--- Bind a freshly connected client (after its daemon.hello) and (re)subscribe
--- every tracked stream from its cursor. A daemon epoch different from the last
--- one discards stale cursors first, so streams resume from the start.
--- @param client tend.rpc.Client
--- @param daemon_epoch string
function StreamSubscriber:bootstrap(client, daemon_epoch)
    self.client = client
    self.cursors:set_epoch(daemon_epoch)
    client:on_notification(M.METHOD_PUSH, function(params)
        self:handle_push(params)
    end)
    client:on_notification(M.METHOD_SUBSCRIPTION_CLOSED, function(params)
        self:handle_closed(params)
    end)
    for _, stream in pairs(self.streams) do
        self:subscribe(stream)
    end
end

--- Mark the connection lost. Cursors and tracked streams are retained so the
--- next bootstrap resumes them.
function StreamSubscriber:disconnected()
    self.client = nil
end

--- The current cursor for a tracked stream (the last processed cursor_seq).
--- @param workspace_id string
--- @param stream_id string
--- @return integer
function StreamSubscriber:cursor(workspace_id, stream_id)
    return self.cursors:get(workspace_id, stream_id)
end

--- @private
--- @param stream tend.rpc.TrackedStream
function StreamSubscriber:subscribe(stream)
    local client = self.client
    if not client then
        return
    end
    local last_seq = self.cursors:get(stream.workspace_id, stream.stream_id)
    client:request(M.METHOD_SUBSCRIBE, {
        stream_id = stream.stream_id,
        last_seq = last_seq,
    }, function(err)
        -- result.tail is informational; live records follow via event.push.
        if err then
            self:on_subscribe_error(stream, err)
        end
    end)
end

--- @private
--- @param stream tend.rpc.TrackedStream
--- @param err tend.rpc.Error
function StreamSubscriber:on_subscribe_error(stream, err)
    -- A compacted cursor: resume from just below the summary boundary so the
    -- daemon serves the summary record next, then re-subscribe once.
    if
        err.code == M.ERR_CURSOR_COMPACTED
        and type(err.data) == "table"
        and type(err.data.boundary_seq) == "number"
    then
        self.cursors:reset(
            stream.workspace_id,
            stream.stream_id,
            err.data.boundary_seq - 1
        )
        self:subscribe(stream)
        return
    end
    self.on_error(
        "tend.rpc: subscribe "
            .. stream.stream_id
            .. " failed: "
            .. tostring(err.message)
    )
end

--- @private
--- @param params table event.push params: { event = <envelope> }
function StreamSubscriber:handle_push(params)
    local event = params and params.event
    if type(event) ~= "table" or not event.stream_id then
        return
    end
    local stream = self.streams[event.stream_id]
    if not stream then
        return -- not (or no longer) tracked
    end
    -- At-least-once delivery: skip anything we have already passed.
    if self.cursors:seen(stream.workspace_id, event.stream_id, event.seq) then
        return
    end
    -- Deliver before advancing: if the listener errors, the record is not
    -- marked processed and will be redelivered on the next resubscribe.
    local ok, err = pcall(stream.on_event, event)
    if not ok then
        self.on_error(
            "tend.rpc: event handler for "
                .. event.stream_id
                .. " errored: "
                .. tostring(err)
        )
        return
    end
    self.cursors:record(stream.workspace_id, event.stream_id, event.cursor_seq)
end

--- @private
--- @param params table subscription_closed params: { stream_id = ... }
function StreamSubscriber:handle_closed(params)
    local stream = params and self.streams[params.stream_id]
    if stream then
        -- Per-stream overflow on the daemon; resume from our own cursor.
        self:subscribe(stream)
    end
end

return M
