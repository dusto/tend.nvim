--- Serves the daemon->editor reverse requests: the plugin IS the editor, so
--- when the daemon calls editor.open / editor.diff this answers them.
---
--- Both are read-only review affordances (the daemon never sends them
--- unprompted for a mutation — those go through the approval gate). The diff
--- snapshots travel in the editor.diff request, so rendering needs no daemon
--- round-trip. The review backend is injectable so the handlers are testable
--- without driving real windows.
local DiffReview = require("tend.ui.diff_review")

local M = {}

-- Wire method names, matching the daemon contract (daemon->editor).
M.METHOD_OPEN = "editor.open"
M.METHOD_DIFF = "editor.diff"

--- @class tend.daemon.EditorService
--- @field private review tend.ui.DiffReview the review backend
local EditorService = {}
EditorService.__index = EditorService
M.EditorService = EditorService

--- @class tend.daemon.EditorServiceOpts
--- @field review? tend.ui.DiffReview Override the review backend (tests).

--- @param opts? tend.daemon.EditorServiceOpts
--- @return tend.daemon.EditorService
function EditorService.new(opts)
    opts = opts or {}
    return setmetatable({ review = opts.review or DiffReview }, EditorService)
end

--- Register the editor reverse-request handlers on a freshly connected client.
--- @param client tend.rpc.Client
function EditorService:bootstrap(client)
    client:on_request(M.METHOD_OPEN, function(params)
        return self:handle_open(params)
    end)
    client:on_request(M.METHOD_DIFF, function(params)
        return self:handle_diff(params)
    end)
end

--- Handle an editor.open request: open the named files for in-place review.
--- @param params table EditorOpenParams
--- @return table result EditorOpenResult (empty ack)
function EditorService:handle_open(params)
    local uris = type(params) == "table" and params.uris or nil
    self.review.open_files(uris or {})
    return vim.empty_dict()
end

--- Handle an editor.diff request: render the carried before/after snapshots.
--- @param params table EditorDiffParams
--- @return table result EditorDiffResult (empty ack)
function EditorService:handle_diff(params)
    if type(params) == "table" then
        self.review.show_snapshots(params.change_set_id, params.files or {})
    end
    return vim.empty_dict()
end

return M
