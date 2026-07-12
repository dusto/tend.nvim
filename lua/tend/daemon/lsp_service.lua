--- Serves the daemon->editor LSP reverse requests. The plugin IS the editor, so
--- when the daemon's lsp.* tools (`lsp.diagnostics`/`symbols`/`definition`/
--- `references`/`hover`/`code_actions`) proxy to the session's bound editor, these
--- handlers answer with editor-fresh data from Neovim's built-in diagnostics and
--- LSP. `editor.current_buffer` is answered here too, so the daemon can resolve an
--- empty-URI "current file" query.
---
--- All wire-shaping (including byte<->UTF-16 position conversion) lives in the
--- provider + `tend.daemon.lsp_wire`; this module only decodes params, dispatches,
--- and returns the provider's result. The provider is injectable so the dispatch
--- is testable without a live LSP.
local LspProvider = require("tend.daemon.lsp_provider")

local M = {}

-- Wire method names (daemon->editor), matching the daemon contract.
M.METHOD_CURRENT_BUFFER = "editor.current_buffer"
M.METHOD_DIAGNOSTICS = "editor.diagnostics"
M.METHOD_SYMBOLS = "editor.symbols"
M.METHOD_DEFINITION = "editor.definition"
M.METHOD_REFERENCES = "editor.references"
M.METHOD_HOVER = "editor.hover"
M.METHOD_CODE_ACTIONS = "editor.code_actions"

-- A zeroed position/range for a malformed request, so a handler still answers.
local ZERO_POS = { line = 0, byte_col = 0 }
local ZERO_RANGE = { start = ZERO_POS, ["end"] = ZERO_POS }

--- @class tend.daemon.LspService
--- @field private provider tend.daemon.LspProvider
local LspService = {}
LspService.__index = LspService
M.LspService = LspService

--- @class tend.daemon.LspServiceOpts
--- @field provider? tend.daemon.LspProvider Override the LSP backend (tests).

--- @param opts? tend.daemon.LspServiceOpts
--- @return tend.daemon.LspService
function LspService.new(opts)
    opts = opts or {}
    return setmetatable(
        { provider = opts.provider or LspProvider.LspProvider.new() },
        LspService
    )
end

--- Register the LSP reverse-request handlers on a freshly connected client.
--- @param client tend.rpc.Client
function LspService:bootstrap(client)
    client:on_request(M.METHOD_CURRENT_BUFFER, function()
        return self.provider:current_buffer()
    end)
    client:on_request(M.METHOD_DIAGNOSTICS, function(params)
        return self.provider:diagnostics(self._uri(params))
    end)
    client:on_request(M.METHOD_SYMBOLS, function(params)
        return self.provider:symbols(self._uri(params))
    end)
    client:on_request(M.METHOD_DEFINITION, function(params)
        return self.provider:definition(self._uri(params), self._pos(params))
    end)
    client:on_request(M.METHOD_REFERENCES, function(params)
        local p = type(params) == "table" and params or {}
        return self.provider:references(
            self._uri(params),
            self._pos(params),
            p.include_declaration
        )
    end)
    client:on_request(M.METHOD_HOVER, function(params)
        return self.provider:hover(self._uri(params), self._pos(params))
    end)
    client:on_request(M.METHOD_CODE_ACTIONS, function(params)
        local p = type(params) == "table" and params or {}
        return self.provider:code_actions(
            self._uri(params),
            p.range or ZERO_RANGE,
            p.only
        )
    end)
end

--- @private
--- @param params any
--- @return string uri
function LspService._uri(params)
    if type(params) == "table" and type(params.uri) == "string" then
        return params.uri
    end
    return ""
end

--- @private
--- @param params any
--- @return table position wire Position
function LspService._pos(params)
    if type(params) == "table" and type(params.position) == "table" then
        return params.position
    end
    return ZERO_POS
end

return M
