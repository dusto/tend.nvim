--- Per-stream cursor store for resumable event subscriptions.
---
--- A cursor is the last `cursor_seq` the client has processed on a stream; on
--- (re)subscribe it is sent as `last_seq` so the daemon replays from just after
--- it. Cursors are scoped to a daemon epoch and a workspace: seqs are per daemon
--- process, so a new epoch (daemon restart) invalidates every stored seq, and
--- grouping by workspace lets a closed workspace's cursors be dropped together.
---
--- Cursors only ever move forward (the seq stream is monotonic and contiguous
--- within a stream), so `record` keeps the maximum and `seen` reports whether a
--- seq has already been passed — the basis for at-least-once dedup.
---
--- @class tend.rpc.CursorStore
--- @field private epoch string? current daemon epoch the cursors belong to
--- @field private cursors table<string, table<string, integer>> workspace_id -> stream_id -> cursor_seq
local CursorStore = {}
CursorStore.__index = CursorStore

--- @return tend.rpc.CursorStore
function CursorStore.new()
    return setmetatable({ epoch = nil, cursors = {} }, CursorStore)
end

--- Bind the store to a daemon epoch. When the epoch differs from the current one
--- (a daemon restart, or the first connect after one), every stored cursor is
--- discarded because its seqs no longer mean anything against the new process.
--- @param epoch string
--- @return boolean discarded Whether stale cursors were dropped for a new epoch.
function CursorStore:set_epoch(epoch)
    if self.epoch == epoch then
        return false
    end
    local discarded = self.epoch ~= nil
    self.epoch = epoch
    self.cursors = {}
    return discarded
end

--- @private
--- @param workspace_id string
--- @return table<string, integer>
function CursorStore:streams_of(workspace_id)
    local ws = self.cursors[workspace_id]
    if not ws then
        ws = {}
        self.cursors[workspace_id] = ws
    end
    return ws
end

--- The last cursor_seq processed for a stream, or 0 if none (resume from the
--- start of the stream's retained log).
--- @param workspace_id string
--- @param stream_id string
--- @return integer
function CursorStore:get(workspace_id, stream_id)
    local ws = self.cursors[workspace_id]
    return ws and ws[stream_id] or 0
end

--- Advance a stream's cursor to cursor_seq, keeping the maximum so a replayed or
--- duplicated record never moves it backward.
--- @param workspace_id string
--- @param stream_id string
--- @param cursor_seq integer
--- @return integer cursor The stored cursor after the update.
function CursorStore:record(workspace_id, stream_id, cursor_seq)
    local ws = self:streams_of(workspace_id)
    local current = ws[stream_id] or 0
    if cursor_seq > current then
        ws[stream_id] = cursor_seq
        return cursor_seq
    end
    return current
end

--- Set a stream's cursor explicitly, even backward. Used to resume from a
--- compaction boundary: subscribing with last_seq just below the summary's
--- from_seq makes the daemon serve the summary record next.
--- @param workspace_id string
--- @param stream_id string
--- @param cursor_seq integer
function CursorStore:reset(workspace_id, stream_id, cursor_seq)
    self:streams_of(workspace_id)[stream_id] = cursor_seq
end

--- Whether seq is at or before the stream's cursor, i.e. already processed. With
--- in-stream ordering this is sufficient dedup for at-least-once delivery.
--- @param workspace_id string
--- @param stream_id string
--- @param seq integer
--- @return boolean
function CursorStore:seen(workspace_id, stream_id, seq)
    return seq <= self:get(workspace_id, stream_id)
end

--- Drop a single stream's cursor.
--- @param workspace_id string
--- @param stream_id string
function CursorStore:forget(workspace_id, stream_id)
    local ws = self.cursors[workspace_id]
    if ws then
        ws[stream_id] = nil
    end
end

--- Drop every cursor for a workspace (e.g. when the workspace is closed).
--- @param workspace_id string
function CursorStore:forget_workspace(workspace_id)
    self.cursors[workspace_id] = nil
end

return CursorStore
