--- Bidirectional JSON-RPC 2.0 client for the tend daemon.
---
--- The daemon and plugin speak the same wire: newline-delimited compact JSON
--- objects over a Unix socket, where either side may issue requests and
--- notifications. This client routes both directions:
---   - plugin -> daemon: `request` (id-correlated reply) and `notify`.
---   - daemon -> plugin: inbound requests (e.g. editor.read_buffer) dispatched
---     to `on_request` handlers, and notifications (event.push, prompt.raise,
---     event.subscription_closed) dispatched to `on_notification` handlers.
---
--- The protocol core is transport-agnostic (it is driven by a `writer` function
--- and fed bytes via `feed`), so it is unit-testable without a socket; `connect`
--- wires it to a real Unix socket via libuv.
local uv = vim.uv or vim.loop

local M = {}

-- JSON-RPC 2.0 error codes used by this client.
M.ERR_PARSE = -32700
M.ERR_INVALID_REQUEST = -32600
M.ERR_METHOD_NOT_FOUND = -32601
M.ERR_INTERNAL = -32603

--- @class tend.rpc.Error
--- @field code integer
--- @field message string
--- @field data? any

--- A protocol observation event emitted at each wire boundary. Purely for
--- tracing (e.g. :TendEvents); it never affects request handling.
--- @class tend.rpc.TraceEvent
--- @field dir "out"|"in" Outbound (plugin->daemon) or inbound.
--- @field kind "request"|"notification"|"response"
--- @field method? string RPC method (a response carries the request's method).
--- @field id? integer Request/response correlation id.
--- @field ok? boolean Response outcome.
--- @field err? string Error message on a failed response.
--- @field elapsed_ms? integer Request round-trip time on a response.

--- @class tend.rpc.Client
--- @field private writer fun(data: string)
--- @field private closer fun()
--- @field private on_error fun(msg: string)
--- @field private buffer string
--- @field private next_id integer
--- @field private pending table<integer, fun(err: tend.rpc.Error?, result: any)>
--- @field private requests table<string, fun(params: any): any, tend.rpc.Error?>
--- @field private notifications table<string, fun(params: any)>
--- @field private on_trace fun(event: tend.rpc.TraceEvent)
--- @field private trace_pending table<integer, { method: string, t0: integer }>
local Client = {}
Client.__index = Client
M.Client = Client

--- @class tend.rpc.ClientOpts
--- @field writer fun(data: string) Sends one framed message to the peer.
--- @field closer? fun() Closes the transport (called by Client:close).
--- @field on_error? fun(msg: string) Reports a parse/protocol error.
--- @field on_trace? fun(event: tend.rpc.TraceEvent) Observes wire activity.

--- @param opts tend.rpc.ClientOpts
--- @return tend.rpc.Client
function Client.new(opts)
    return setmetatable({
        writer = opts.writer,
        closer = opts.closer or function() end,
        on_error = opts.on_error or function() end,
        on_trace = opts.on_trace or function() end,
        buffer = "",
        next_id = 0,
        pending = {},
        requests = {},
        notifications = {},
        trace_pending = {},
    }, Client)
end

--- Send a request to the peer; cb is called with (err, result) on the reply.
--- @param method string
--- @param params any
--- @param cb? fun(err: tend.rpc.Error?, result: any)
function Client:request(method, params, cb)
    self.next_id = self.next_id + 1
    local id = self.next_id
    self.pending[id] = cb or function() end
    self.trace_pending[id] = { method = method, t0 = uv.now() }
    self.on_trace({ dir = "out", kind = "request", method = method, id = id })
    self:send({ jsonrpc = "2.0", id = id, method = method, params = params })
end

--- Send a notification (no reply expected).
--- @param method string
--- @param params any
function Client:notify(method, params)
    self.on_trace({ dir = "out", kind = "notification", method = method })
    self:send({ jsonrpc = "2.0", method = method, params = params })
end

--- Register a handler for an inbound request method. The handler returns
--- `(result, err)`: a non-nil err (a tend.rpc.Error) is sent as the error reply,
--- otherwise result is sent (a nil result becomes JSON null).
--- @param method string
--- @param handler fun(params: any): any, tend.rpc.Error?
function Client:on_request(method, handler)
    self.requests[method] = handler
end

--- Register a handler for an inbound notification method.
--- @param method string
--- @param handler fun(params: any)
function Client:on_notification(method, handler)
    self.notifications[method] = handler
end

--- Close the transport.
function Client:close()
    self.closer()
end

--- Feed raw bytes received from the peer; routes each complete message. Partial
--- trailing data is buffered until the rest arrives.
--- @param data string
function Client:feed(data)
    self.buffer = self.buffer .. data
    local lines = vim.split(self.buffer, "\n", { plain = true })
    self.buffer = lines[#lines]
    for i = 1, #lines - 1 do
        local line = vim.trim(lines[i])
        if line ~= "" then
            self:dispatch(line)
        end
    end
end

--- @private
--- @param msg table
function Client:send(msg)
    local ok, encoded = pcall(vim.json.encode, msg)
    if not ok then
        self.on_error("tend.rpc: encode failed: " .. tostring(encoded))
        return
    end
    self.writer(encoded .. "\n")
end

--- @private
--- @param line string
function Client:dispatch(line)
    local ok, msg = pcall(vim.json.decode, line)
    if not ok or type(msg) ~= "table" then
        self.on_error("tend.rpc: parse failed: " .. line)
        return
    end
    if msg.method ~= nil then
        if msg.id ~= nil then
            self:handle_request(msg)
        else
            self:handle_notification(msg)
        end
    else
        self:handle_response(msg)
    end
end

--- @private
--- @param msg table
function Client:handle_request(msg)
    self.on_trace({
        dir = "in",
        kind = "request",
        method = msg.method,
        id = msg.id,
    })
    local handler = self.requests[msg.method]
    if not handler then
        self:send({
            jsonrpc = "2.0",
            id = msg.id,
            error = {
                code = M.ERR_METHOD_NOT_FOUND,
                message = "method not found: " .. tostring(msg.method),
            },
        })
        return
    end
    local ok, result, err = pcall(handler, msg.params)
    if not ok then
        self:send({
            jsonrpc = "2.0",
            id = msg.id,
            error = { code = M.ERR_INTERNAL, message = tostring(result) },
        })
        return
    end
    if err ~= nil then
        self:send({ jsonrpc = "2.0", id = msg.id, error = err })
        return
    end
    if result == nil then
        result = vim.NIL
    end
    self:send({ jsonrpc = "2.0", id = msg.id, result = result })
end

--- @private
--- @param msg table
function Client:handle_notification(msg)
    self.on_trace({ dir = "in", kind = "notification", method = msg.method })
    local handler = self.notifications[msg.method]
    if handler then
        pcall(handler, msg.params)
    end
end

--- @private
--- @param msg table
function Client:handle_response(msg)
    local meta = self.trace_pending[msg.id]
    self.trace_pending[msg.id] = nil
    self.on_trace({
        dir = "in",
        kind = "response",
        method = meta and meta.method,
        id = msg.id,
        ok = msg.error == nil,
        err = msg.error and msg.error.message,
        elapsed_ms = meta and (uv.now() - meta.t0) or nil,
    })

    local cb = self.pending[msg.id]
    if not cb then
        self.on_error("tend.rpc: response for unknown id " .. tostring(msg.id))
        return
    end
    self.pending[msg.id] = nil
    if msg.error ~= nil then
        cb(msg.error, nil)
    else
        cb(nil, msg.result)
    end
end

--- The default daemon socket path: `$XDG_RUNTIME_DIR/tend/tend.sock`, falling
--- back to `/tmp/tend-<uid>/tend.sock` when XDG_RUNTIME_DIR is unset.
--- @return string
function M.socket_path()
    local runtime = vim.env.XDG_RUNTIME_DIR
    if runtime and runtime ~= "" then
        return runtime .. "/tend/tend.sock"
    end
    local uid = uv.getuid and uv.getuid() or 0
    return "/tmp/tend-" .. tostring(uid) .. "/tend.sock"
end

--- @class tend.rpc.ConnectOpts
--- @field path? string Socket path (default: M.socket_path()).
--- @field on_error? fun(msg: string)
--- @field on_disconnect? fun()
--- @field on_trace? fun(event: tend.rpc.TraceEvent)

--- Connect to the daemon over a Unix socket and return a wired Client.
---
--- libuv runs its `connect`/`read_start` callbacks in Neovim's fast-event
--- context, where most of the `vim.api` is unavailable. Since dispatched
--- handlers and reply callbacks routinely touch the editor, every transition
--- back into client/user code here is deferred via `vim.schedule`, so the whole
--- public surface (the connect cb, request/notification handlers, response
--- callbacks, on_error, on_disconnect) runs in the main loop.
--- @param opts tend.rpc.ConnectOpts
--- @param cb fun(client: tend.rpc.Client?, err: string?)
function M.connect(opts, cb)
    opts = opts or {}
    local path = opts.path or M.socket_path()
    local pipe = uv.new_pipe(false)
    if not pipe then
        vim.schedule(function()
            cb(nil, "tend.rpc: failed to create pipe")
        end)
        return
    end
    pipe:connect(path, function(err)
        if err then
            pipe:close()
            vim.schedule(function()
                cb(nil, "tend.rpc: connect " .. path .. ": " .. err)
            end)
            return
        end
        local client = Client.new({
            -- write is loop-safe from any context; no need to schedule it.
            writer = function(data)
                pipe:write(data)
            end,
            closer = function()
                if not pipe:is_closing() then
                    pipe:close()
                end
            end,
            on_error = opts.on_error,
            on_trace = opts.on_trace,
        })
        pipe:read_start(function(rerr, data)
            if rerr then
                vim.schedule(function()
                    if opts.on_error then
                        opts.on_error("tend.rpc: read: " .. rerr)
                    end
                    client:close()
                    if opts.on_disconnect then
                        opts.on_disconnect()
                    end
                end)
            elseif data then
                -- Defer dispatch out of fast-event context: feed() routes into
                -- handlers and reply callbacks that may use vim.api.
                vim.schedule(function()
                    client:feed(data)
                end)
            else
                vim.schedule(function()
                    client:close() -- EOF
                    if opts.on_disconnect then
                        opts.on_disconnect()
                    end
                end)
            end
        end)
        vim.schedule(function()
            cb(client, nil)
        end)
    end)
end

return M
