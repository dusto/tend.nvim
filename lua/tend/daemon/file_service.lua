--- Serves the editor.read_buffer / editor.write_buffer reverse requests: the
--- plugin IS the editor, so the daemon's file tools resolve live buffer state
--- and write open buffers through these. The real work lives in
--- `tend.daemon.file_provider`; this only registers the handlers and normalizes
--- params, with an injectable provider so the dispatch is testable without
--- driving real buffers.
local FileProvider = require("tend.daemon.file_provider")

local M = {}

-- Wire method names, matching the daemon contract (daemon->editor).
M.METHOD_READ_BUFFER = "editor.read_buffer"
M.METHOD_WRITE_BUFFER = "editor.write_buffer"

--- @class tend.daemon.FileService
--- @field private provider tend.daemon.FileProvider
local FileService = {}
FileService.__index = FileService
M.FileService = FileService

--- @class tend.daemon.FileServiceOpts
--- @field provider? tend.daemon.FileProvider Override the backend (tests).

--- @param opts? tend.daemon.FileServiceOpts
--- @return tend.daemon.FileService
function FileService.new(opts)
    opts = opts or {}
    return setmetatable({
        provider = opts.provider or FileProvider.FileProvider.new(),
    }, FileService)
end

--- The wire URI from params, defaulting to empty (the active buffer).
--- @param params table|nil
--- @return string uri
local function uri_of(params)
    return type(params) == "table" and params.uri or ""
end

--- Register the file-mutation reverse-request handlers on a fresh client.
--- @param client tend.rpc.Client
function FileService:bootstrap(client)
    client:on_request(M.METHOD_READ_BUFFER, function(params)
        return self.provider:read_buffer(uri_of(params))
    end)
    client:on_request(M.METHOD_WRITE_BUFFER, function(params)
        params = type(params) == "table" and params or {}
        return self.provider:write_buffer(
            params.uri or "",
            params.content or "",
            params.base
        )
    end)
end

return M
