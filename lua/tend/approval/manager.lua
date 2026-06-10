--- Approval flow wiring over the daemon RPC client.
---
--- Receives prompt.raise notifications (kind "approval"; clarifications are not
--- this module's concern), normalizes the gate envelope + ApprovalDetail into
--- the model, and surfaces the view. Responses go through approval.respond —
--- the daemon re-verifies freshness on respond, so a stale/conflict error is
--- reported and the pending set re-synced rather than retried. sync() rebuilds
--- the pending set from approval.list: the connection owner calls bootstrap()
--- per connection, so a reconnect recovers approvals raised while detached.
--- Session-stream events keep the set honest: approval_resolved (any responder,
--- including daemon-side TTL expiry) clears an entry; approval_requested for an
--- unknown id means we attached mid-flight and triggers a sync.
local Logger = require("tend.utils.logger")
local Model = require("tend.approval.model")
local ViewMod = require("tend.approval.view")

local M = {}

-- Wire method names, matching the daemon contract.
M.METHOD_PROMPT_RAISE = "prompt.raise"
M.METHOD_LIST = "approval.list"
M.METHOD_RESPOND = "approval.respond"

-- Session-stream event types this manager reacts to.
M.EVENT_REQUESTED = "approval_requested"
M.EVENT_RESOLVED = "approval_resolved"

--- The view surface the manager drives (tend.approval.View satisfies it).
--- @class tend.approval.ViewSurface
--- @field show fun(self: any)
--- @field refresh fun(self: any)

--- Normalize a wire payload — a prompt.raise's params or an approval.list
--- summary — into a model approval. The operation kind and detail body live in
--- the ApprovalDetail ({ kind, <kind> = body }); a summary also carries the
--- kind on the envelope.
--- @param envelope table
--- @return tend.approval.Approval|nil
local function normalize(envelope)
    if type(envelope.approval_id) ~= "string" then
        return nil
    end
    local detail = envelope.detail
    if type(detail) ~= "table" then
        detail = {}
    end
    local kind = envelope.kind
    if kind == nil or kind == "approval" then
        kind = detail.kind
    end
    if type(kind) ~= "string" then
        return nil
    end
    --- @type tend.approval.Approval
    local approval = {
        approval_id = envelope.approval_id,
        session_id = envelope.session_id,
        kind = kind,
        detail = type(detail[kind]) == "table" and detail[kind] or nil,
    }
    if type(envelope.prompt) == "string" and envelope.prompt ~= "" then
        approval.prompt = envelope.prompt
    end
    if type(envelope.expires_at) == "string" then
        approval.expires_at = envelope.expires_at
    end
    return approval
end

--- @class tend.approval.Manager
--- @field model tend.approval.Model
--- @field private view tend.approval.ViewSurface
--- @field private client tend.rpc.Client|nil current connection, nil while down
--- @field private on_error fun(msg: string)
local Manager = {}
Manager.__index = Manager
M.Manager = Manager

--- @class tend.approval.ManagerOpts
--- @field view? tend.approval.ViewSurface Override the default float view.
--- @field keys? tend.approval.ViewKeys Keymaps for the default view.
--- @field on_error? fun(msg: string) Reports respond/sync errors.

--- @param opts? tend.approval.ManagerOpts
--- @return tend.approval.Manager
function Manager.new(opts)
    opts = opts or {}
    local model = Model.new()
    local self = setmetatable({
        model = model,
        client = nil,
        on_error = opts.on_error or function(msg)
            Logger.notify(msg, vim.log.levels.ERROR)
        end,
    }, Manager)
    self.view = opts.view
        or ViewMod.View.new(model, {
            keys = opts.keys,
            respond = function(approval_id, approved)
                self:respond(approval_id, approved)
            end,
        }) --[[@as tend.approval.ViewSurface]]
    return self
end

--- Bind a freshly connected client: route its prompt.raise notifications here
--- and sync the pending set, so approvals raised while detached are recovered.
--- @param client tend.rpc.Client
function Manager:bootstrap(client)
    self.client = client
    client:on_notification(M.METHOD_PROMPT_RAISE, function(params)
        self:handle_prompt(params)
    end)
    self:sync()
end

--- Mark the connection lost. Pending state is retained for the next bootstrap.
function Manager:disconnected()
    self.client = nil
end

--- Rebuild the pending set from approval.list and surface the view. The
--- optional callback receives (err, pending_count) once the sync settles.
--- @param cb? fun(err: string|nil, count: integer|nil)
function Manager:sync(cb)
    local client = self.client
    if not client then
        if cb then
            cb("tend.approval: not connected", nil)
        end
        return
    end
    client:request(M.METHOD_LIST, vim.empty_dict(), function(err, result)
        if err then
            local msg = "tend.approval: list failed: " .. err.message
            self.on_error(msg)
            if cb then
                cb(msg, nil)
            end
            return
        end
        local approvals = {}
        local summaries = type(result) == "table" and result.approvals or nil
        if type(summaries) == "table" then
            for _, summary in ipairs(summaries) do
                local approval = normalize(summary)
                if approval then
                    table.insert(approvals, approval)
                end
            end
        end
        self.model:replace(approvals)
        if self.model:count() > 0 then
            self.view:show()
        else
            self.view:refresh()
        end
        if cb then
            cb(nil, self.model:count())
        end
    end)
end

--- Resolve a pending approval via approval.respond. On error the failure is
--- reported and the pending set re-synced (the approval may be stale, expired,
--- or superseded); the daemon decides, we never retry.
--- @param approval_id string
--- @param approved boolean
function Manager:respond(approval_id, approved)
    local client = self.client
    if not client then
        self.on_error("tend.approval: not connected; cannot respond")
        return
    end
    client:request(M.METHOD_RESPOND, {
        approval_id = approval_id,
        approved = approved,
    }, function(err)
        if err then
            self.on_error("tend.approval: respond failed: " .. err.message)
            self:sync()
            return
        end
        if self.model:resolve(approval_id) then
            self.view:refresh()
        end
    end)
end

--- @private
--- @param params table prompt.raise params
function Manager:handle_prompt(params)
    if type(params) ~= "table" or params.kind ~= "approval" then
        return
    end
    local approval = normalize(params)
    if approval and self.model:add(approval) then
        self.view:show()
    end
end

--- Apply a session-stream event (approval_requested / approval_resolved).
--- The owner wires this from its stream subscription; other event types are
--- ignored.
--- @param event table event envelope with type + payload
function Manager:handle_event(event)
    local payload = type(event.payload) == "table" and event.payload or {}
    if event.type == M.EVENT_RESOLVED then
        if self.model:resolve(payload.approval_id) then
            self.view:refresh()
        end
    elseif event.type == M.EVENT_REQUESTED then
        -- The event carries no decision context; an unknown id means the
        -- prompt.raise predates this connection, so re-list to pick it up.
        if payload.approval_id and not self.model:get(payload.approval_id) then
            self:sync()
        end
    end
end

return M
