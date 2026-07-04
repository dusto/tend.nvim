--- A bounded, read-only record of plugin<->daemon wire activity: the outbound
--- requests/notifications the plugin sends, the responses it gets back (method,
--- ok/err, round-trip timing), the inbound requests/notifications the daemon
--- pushes, and connection-lifecycle transitions. It is the plugin-side mirror of
--- the daemon's TEND_LOG trace, surfaced by :TendEvents for debugging the link.
---
--- It is a passive sink: the rpc client and the connection feed it via
--- `record`, and it never touches the wire itself. The buffer is bounded so a
--- long-lived session cannot grow it without limit.
local uv = vim.uv or vim.loop

local M = {}

-- A busy link (subscriptions, streaming updates) can emit many events per
-- second; 500 keeps recent history without unbounded growth.
M.DEFAULT_CAPACITY = 500

--- @class tend.daemon.ProtocolLog.Entry
--- @field seq integer Monotonic sequence number, oldest lowest.
--- @field ts string Wall-clock HH:MM:SS the entry was recorded.
--- @field ms integer Monotonic timestamp (uv.now) for internal use.
--- @field kind "request"|"notification"|"response"|"connection"
--- @field dir? "out"|"in" Direction; nil for connection-lifecycle entries.
--- @field method? string RPC method name.
--- @field id? integer Request id for request/response correlation.
--- @field ok? boolean Response outcome (true = result, false = error).
--- @field err? string Error message on a failed response.
--- @field elapsed_ms? integer Request round-trip time.
--- @field status? string Connection status for lifecycle entries.

--- A partial entry as supplied by callers: the log stamps seq/ts/ms itself.
--- @class tend.daemon.ProtocolLog.Record
--- @field kind "request"|"notification"|"response"|"connection"
--- @field dir? "out"|"in"
--- @field method? string
--- @field id? integer
--- @field ok? boolean
--- @field err? string
--- @field elapsed_ms? integer
--- @field status? string

--- @class tend.daemon.ProtocolLog
--- @field private capacity integer
--- @field private buf tend.daemon.ProtocolLog.Entry[]
--- @field private seq integer
local ProtocolLog = {}
ProtocolLog.__index = ProtocolLog
M.ProtocolLog = ProtocolLog

--- @param capacity? integer Max retained entries (default: DEFAULT_CAPACITY).
--- @return tend.daemon.ProtocolLog
function M.new(capacity)
    return setmetatable({
        capacity = capacity and capacity > 0 and capacity or M.DEFAULT_CAPACITY,
        buf = {},
        seq = 0,
    }, ProtocolLog)
end

--- Append an entry, evicting the oldest once capacity is exceeded.
--- @param record tend.daemon.ProtocolLog.Record
function ProtocolLog:record(record)
    self.seq = self.seq + 1
    --- @type tend.daemon.ProtocolLog.Entry
    local entry = {
        seq = self.seq,
        ts = os.date("%H:%M:%S") --[[@as string]],
        ms = uv.now(),
        kind = record.kind,
        dir = record.dir,
        method = record.method,
        id = record.id,
        ok = record.ok,
        err = record.err,
        elapsed_ms = record.elapsed_ms,
        status = record.status,
    }
    table.insert(self.buf, entry)
    if #self.buf > self.capacity then
        table.remove(self.buf, 1)
    end
end

--- The retained entries, oldest first.
--- @return tend.daemon.ProtocolLog.Entry[]
function ProtocolLog:entries()
    return self.buf
end

--- Drop all retained entries. The sequence counter keeps climbing so entries
--- recorded after a clear still sort after the ones it removed.
function ProtocolLog:clear()
    self.buf = {}
end

--- @param entry tend.daemon.ProtocolLog.Entry
--- @return string line
local function format_entry(entry)
    local arrow = "  "
    if entry.dir == "out" then
        arrow = "->"
    elseif entry.dir == "in" then
        arrow = "<-"
    end

    local detail
    if entry.kind == "connection" then
        detail = "connection " .. (entry.status or "?")
    elseif entry.kind == "response" then
        local outcome = entry.ok and "ok" or ("err: " .. (entry.err or "?"))
        detail = "response " .. (entry.method or "?")
        if entry.id then
            detail = detail .. " #" .. entry.id
        end
        detail = detail .. " " .. outcome
        if entry.elapsed_ms then
            detail = detail .. " (" .. entry.elapsed_ms .. "ms)"
        end
    else
        detail = entry.kind .. " " .. (entry.method or "?")
        if entry.id then
            detail = detail .. " #" .. entry.id
        end
    end

    return string.format("%s  %s  %s", entry.ts, arrow, detail)
end

--- Render the retained entries as display lines, oldest first.
--- @return string[] lines
function ProtocolLog:render_lines()
    local lines = {}
    for _, entry in ipairs(self.buf) do
        table.insert(lines, format_entry(entry))
    end
    return lines
end

return M
