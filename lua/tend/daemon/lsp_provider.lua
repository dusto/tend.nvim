--- The real editor-LSP backend behind the editor.* reverse handlers: resolves a
--- wire URI to a buffer, queries Neovim's built-in diagnostics/LSP, and hands the
--- raw results to `tend.daemon.lsp_wire` for wire-shaping (including the
--- byte<->UTF-16 position conversion). Kept behind an interface so
--- `tend.daemon.lsp_service` is testable with a fake backend.
---
--- Contract: the plugin answers only for **open** buffers (editor-fresh). A URI
--- that is not a loaded buffer yields an empty, `open=false` result rather than
--- loading the file or spinning up an LSP client — the daemon owns the
--- closed-file story (a future workspace index), and a headless session never
--- reaches here (the daemon returns editor_unavailable at the binding layer).
local Wire = require("tend.daemon.lsp_wire")

local M = {}

-- How long a synchronous LSP round-trip may block the reverse handler.
local REQUEST_TIMEOUT_MS = 2000

--- @class tend.daemon.LspProvider
local LspProvider = {}
LspProvider.__index = LspProvider
M.LspProvider = LspProvider

--- @return tend.daemon.LspProvider
function LspProvider.new()
    return setmetatable({}, LspProvider)
end

--- Resolve a wire URI to a buffer. An empty URI means the active buffer.
--- @param uri string|nil
--- @return integer bufnr
--- @return boolean open whether the buffer is loaded (editor-fresh)
--- @return string buf_uri the buffer's own URI
local function resolve(uri)
    local bufnr
    if uri == nil or uri == "" then
        bufnr = vim.api.nvim_get_current_buf()
    else
        bufnr = vim.uri_to_bufnr(uri)
    end
    return bufnr, vim.api.nvim_buf_is_loaded(bufnr), vim.uri_from_bufnr(bufnr)
end

--- @param bufnr integer
--- @param row integer 0-based
--- @return string line
local function buf_line(bufnr, row)
    local lines = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)
    return lines[1] or ""
end

--- The offset encoding negotiated by the buffer's LSP clients (utf-16 default).
--- @param bufnr integer
--- @return string encoding
local function encoding(bufnr)
    for _, c in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
        if c.offset_encoding then
            return c.offset_encoding
        end
    end
    return "utf-16"
end

--- Read a closed file's raw bytes (exactly, including a trailing newline) so a
--- content hash matches the daemon's `crypto/sha256` over the same bytes.
--- @param path string
--- @return string|nil bytes
local function read_bytes(path)
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local data = f:read("*a")
    f:close()
    return data
end

--- A line reader spanning any URI (loaded buffer or, failing that, the file on
--- disk), memoized per call so a multi-location result reads each file once. Used
--- to convert result ranges that may point at files other than the queried one.
--- @return fun(uri: string, row: integer): string
local function line_reader()
    local cache = {}
    return function(uri, row)
        local lines = cache[uri]
        if lines == nil then
            local b = vim.uri_to_bufnr(uri)
            if vim.api.nvim_buf_is_loaded(b) then
                lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
            else
                local bytes = read_bytes(vim.uri_to_fname(uri))
                lines = bytes and vim.split(bytes, "\n", { plain = true }) or {}
            end
            cache[uri] = lines
        end
        return lines[row + 1] or ""
    end
end

--- The FileBase for a change target: a changedtick for an open buffer, else a
--- SHA-256 content hash of the file's bytes — matching the daemon's verifyBase.
--- @param uri string
--- @return table base wire FileBase
local function base_of(uri)
    local b = vim.uri_to_bufnr(uri)
    if vim.api.nvim_buf_is_loaded(b) then
        return { changedtick = vim.api.nvim_buf_get_changedtick(b) }
    end
    local bytes = read_bytes(vim.uri_to_fname(uri)) or ""
    return { content_hash = vim.fn.sha256(bytes) }
end

--- Issue a synchronous LSP request on bufnr, returning every attached client's
--- non-nil result in stable client-id order. A buffer can have several clients
--- (a language server plus a linter, or two servers for one filetype), and each
--- may contribute results; callers aggregate across all of them so the first
--- client's answer never hides the rest.
--- @param bufnr integer
--- @param method string
--- @param params table
--- @return any[] results
local function request_all(bufnr, method, params)
    local responses =
        vim.lsp.buf_request_sync(bufnr, method, params, REQUEST_TIMEOUT_MS)
    if not responses then
        return {}
    end
    local ids = {}
    for id in pairs(responses) do
        ids[#ids + 1] = id
    end
    table.sort(ids)
    local out = {}
    for _, id in ipairs(ids) do
        local r = responses[id]
        if r and r.result ~= nil then
            out[#out + 1] = r.result
        end
    end
    return out
end

--- @return table result EditorCurrentBufferResult { uri }
function LspProvider:current_buffer()
    local bufnr = vim.api.nvim_get_current_buf()
    -- Only a file-backed normal buffer has a URI; special buffers (the chat
    -- widget, pickers) report empty so the daemon treats them as out-of-scope.
    if
        vim.api.nvim_buf_get_name(bufnr) == ""
        or vim.bo[bufnr].buftype ~= ""
    then
        return { uri = "" }
    end
    return { uri = vim.uri_from_bufnr(bufnr) }
end

--- @param uri string|nil
--- @return table result EditorDiagnosticsResult
function LspProvider:diagnostics(uri)
    local bufnr, open, buf_uri = resolve(uri)
    if not open then
        return { uri = buf_uri, open = false, diagnostics = {} }
    end
    local out = {}
    for _, d in ipairs(vim.diagnostic.get(bufnr)) do
        out[#out + 1] = Wire.diagnostic_to_wire(d)
    end
    return { uri = buf_uri, open = true, diagnostics = out }
end

--- @param uri string|nil
--- @return table result EditorSymbolsResult
function LspProvider:symbols(uri)
    local bufnr, open, buf_uri = resolve(uri)
    if not open then
        return { uri = buf_uri, open = false, symbols = {} }
    end
    local get_line = function(row)
        return buf_line(bufnr, row)
    end
    local enc = encoding(bufnr)
    local symbols = {}
    for _, res in
        ipairs(request_all(bufnr, "textDocument/documentSymbol", {
            textDocument = { uri = buf_uri },
        }))
    do
        vim.list_extend(symbols, Wire.symbols_to_wire(res, get_line, enc))
    end
    return { uri = buf_uri, open = true, symbols = symbols }
end

--- @param uri string|nil
--- @param position table wire Position { line, byte_col }
--- @return table result EditorDefinitionResult
function LspProvider:definition(uri, position)
    local bufnr, open, buf_uri = resolve(uri)
    if not open then
        return { uri = buf_uri, open = false, locations = {} }
    end
    local enc = encoding(bufnr)
    local lsp_pos = Wire.wire_pos_to_lsp(position, function(row)
        return buf_line(bufnr, row)
    end, enc)
    local reader = line_reader()
    local locations = {}
    for _, res in
        ipairs(request_all(bufnr, "textDocument/definition", {
            textDocument = { uri = buf_uri },
            position = lsp_pos,
        }))
    do
        vim.list_extend(locations, Wire.locations_to_wire(res, reader, enc))
    end
    return { uri = buf_uri, open = true, locations = locations }
end

--- @param uri string|nil
--- @param position table wire Position
--- @param include_declaration boolean|nil
--- @return table result EditorReferencesResult
function LspProvider:references(uri, position, include_declaration)
    local bufnr, open, buf_uri = resolve(uri)
    if not open then
        return { uri = buf_uri, open = false, locations = {} }
    end
    local enc = encoding(bufnr)
    local lsp_pos = Wire.wire_pos_to_lsp(position, function(row)
        return buf_line(bufnr, row)
    end, enc)
    local reader = line_reader()
    local locations = {}
    for _, res in
        ipairs(request_all(bufnr, "textDocument/references", {
            textDocument = { uri = buf_uri },
            position = lsp_pos,
            context = { includeDeclaration = include_declaration == true },
        }))
    do
        vim.list_extend(locations, Wire.locations_to_wire(res, reader, enc))
    end
    return { uri = buf_uri, open = true, locations = locations }
end

--- @param uri string|nil
--- @param position table wire Position
--- @return table result EditorHoverResult
function LspProvider:hover(uri, position)
    local bufnr, open, buf_uri = resolve(uri)
    if not open then
        return { uri = buf_uri, open = false, contents = "" }
    end
    local enc = encoding(bufnr)
    local get_line = function(row)
        return buf_line(bufnr, row)
    end
    -- Hover is a point query; the first client that answers wins rather than
    -- concatenating several servers' prose at one cursor position.
    local res = request_all(bufnr, "textDocument/hover", {
        textDocument = { uri = buf_uri },
        position = Wire.wire_pos_to_lsp(position, get_line, enc),
    })[1]
    local out = {
        uri = buf_uri,
        open = true,
        contents = res and Wire.hover_contents_to_string(res.contents) or "",
    }
    if res and res.range then
        out.range = Wire.lsp_range_to_wire(res.range, get_line, enc)
    end
    return out
end

--- @param uri string|nil
--- @param range table wire Range
--- @param only string[]|nil requested CodeActionKinds
--- @return table result EditorCodeActionsResult
function LspProvider:code_actions(uri, range, only)
    local bufnr, open, buf_uri = resolve(uri)
    if not open then
        return { uri = buf_uri, open = false, actions = {} }
    end
    local enc = encoding(bufnr)
    local context = { diagnostics = {} }
    if only and #only > 0 then
        context.only = only
    end
    local reader = line_reader()
    local actions = {}
    for _, res in
        ipairs(request_all(bufnr, "textDocument/codeAction", {
            textDocument = { uri = buf_uri },
            range = Wire.wire_range_to_lsp(range, function(row)
                return buf_line(bufnr, row)
            end, enc),
            context = context,
        }))
    do
        vim.list_extend(
            actions,
            Wire.code_actions_to_wire(res, reader, base_of, enc)
        )
    end
    return { uri = buf_uri, open = true, actions = actions }
end

return M
