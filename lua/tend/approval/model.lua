--- Ordered store of pending approvals with a focus cursor.
---
--- Approvals arrive from prompt.raise notifications or an approval.list sync
--- and leave when resolved — by this client, another prompt-capable responder,
--- or daemon-side TTL expiry (all observed as resolutions; the daemon owns the
--- TTL). Order is arrival order. Focus points at the approval the UI is
--- presenting: it follows its approval across unrelated additions and
--- resolutions, and moves to the next pending one when the focused approval
--- itself resolves.

--- @class tend.approval.Approval
--- @field approval_id string
--- @field session_id string
--- @field kind string operation kind: file_edit | pane_open | pane_run | code_action
--- @field prompt? string human-facing text from prompt.raise
--- @field expires_at? string RFC3339 deadline from the gate envelope
--- @field detail? table kind-specific decision context (the ApprovalDetail body)

--- @class tend.approval.Model
--- @field private order tend.approval.Approval[]
--- @field private focus integer 1-based index into order; 0 when empty
local Model = {}
Model.__index = Model

--- @return tend.approval.Model
function Model.new()
    return setmetatable({ order = {}, focus = 0 }, Model)
end

--- @private
--- @param approval_id string
--- @return integer|nil index
function Model:index_of(approval_id)
    for i, a in ipairs(self.order) do
        if a.approval_id == approval_id then
            return i
        end
    end
    return nil
end

--- Add a pending approval; duplicates (same approval_id) are ignored.
--- @param approval tend.approval.Approval
--- @return boolean added
function Model:add(approval)
    if self:index_of(approval.approval_id) then
        return false
    end
    table.insert(self.order, approval)
    if self.focus == 0 then
        self.focus = 1
    end
    return true
end

--- @param approval_id string
--- @return tend.approval.Approval|nil
function Model:get(approval_id)
    local idx = self:index_of(approval_id)
    return idx and self.order[idx] or nil
end

--- Remove a pending approval (it was responded to, resolved elsewhere, or
--- expired). Returns the removed approval, or nil if unknown.
--- @param approval_id string
--- @return tend.approval.Approval|nil
function Model:resolve(approval_id)
    local idx = self:index_of(approval_id)
    if not idx then
        return nil
    end
    local removed = table.remove(self.order, idx)
    if idx < self.focus then
        self.focus = self.focus - 1
    end
    -- Removing the focused approval leaves focus on the next pending one; the
    -- min() clamps to the new last when the removed one was last.
    self.focus = math.min(self.focus, #self.order)
    return removed
end

--- Replace the whole pending set (an approval.list sync). Focus stays on the
--- same approval_id when it survives, otherwise resets to the first.
--- @param approvals tend.approval.Approval[]
function Model:replace(approvals)
    local focused = self:focused()
    self.order = approvals
    self.focus = #self.order > 0 and 1 or 0
    if focused then
        local idx = self:index_of(focused.approval_id)
        if idx then
            self.focus = idx
        end
    end
end

--- @return tend.approval.Approval|nil
function Model:focused()
    return self.order[self.focus]
end

--- @return integer index 1-based focus position; 0 when empty
function Model:focused_index()
    return self.focus
end

--- @return integer
function Model:count()
    return #self.order
end

--- Move focus by delta, wrapping; a no-op when empty.
--- @param delta integer
function Model:cycle(delta)
    local n = #self.order
    if n == 0 then
        return
    end
    self.focus = (self.focus - 1 + delta) % n + 1
end

--- The pending approval_ids in order (for tests/inspection).
--- @return string[]
function Model:ids()
    local out = {}
    for i, a in ipairs(self.order) do
        out[i] = a.approval_id
    end
    return out
end

return Model
