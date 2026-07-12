--- Pure mapping between Neovim's LSP/diagnostic vocabulary and the tend wire
--- contract (`api.Diagnostic`/`DocumentSymbol`/`Location`/`CodeAction`, keyed by
--- `api/lsp.go` + `api/editor.go`). Kept free of `vim.api`/`vim.lsp` so it is
--- exhaustively unit-testable: line text is supplied through injected `get_line`
--- callbacks and `Base` through a `base_resolver`.
---
--- Position encoding is the subtle part. The wire uses a UTF-8 **byte** offset
--- (`Position.byte_col`, 0-based line); the LSP protocol uses a UTF-16 (or the
--- client's negotiated) **character** offset. `vim.diagnostic.get` already
--- reports native byte offsets, so diagnostics need no conversion; raw LSP
--- protocol responses (symbols, locations, hover, code actions) do, in both
--- directions, using the buffer/file line text.
local M = {}

-- vim.diagnostic.severity and the LSP DiagnosticSeverity share 1..4.
local SEVERITY = { [1] = "error", [2] = "warning", [3] = "info", [4] = "hint" }

-- LSP SymbolKind (1..26) -> the wire's lowercase symbol-kind name.
local SYMBOL_KIND = {
    [1] = "file",
    [2] = "module",
    [3] = "namespace",
    [4] = "package",
    [5] = "class",
    [6] = "method",
    [7] = "property",
    [8] = "field",
    [9] = "constructor",
    [10] = "enum",
    [11] = "interface",
    [12] = "function",
    [13] = "variable",
    [14] = "constant",
    [15] = "string",
    [16] = "number",
    [17] = "boolean",
    [18] = "array",
    [19] = "object",
    [20] = "key",
    [21] = "null",
    [22] = "enum_member",
    [23] = "struct",
    [24] = "event",
    [25] = "operator",
    [26] = "type_parameter",
}

--- @param n integer|nil vim.diagnostic severity
--- @return string severity wire severity ("error"/"warning"/"info"/"hint")
function M.severity_to_wire(n)
    return SEVERITY[n] or "info"
end

--- @param n integer|nil LSP SymbolKind
--- @return string kind wire symbol-kind name ("" when unknown)
function M.symbol_kind_to_wire(n)
    return SYMBOL_KIND[n] or ""
end

--- Convert an LSP character offset within a line to a UTF-8 byte offset. Clamps
--- an out-of-range offset to the line length; falls back to the input on any
--- failure or missing line.
--- @param line string|nil
--- @param char integer
--- @param enc string offset encoding ("utf-8"/"utf-16"/"utf-32")
--- @return integer byte_col
function M.char_to_byte(line, char, enc)
    if type(line) ~= "string" then
        return char
    end
    local ok, byte = pcall(vim.str_byteindex, line, enc, char, false)
    if ok and byte ~= nil then
        return byte
    end
    return #line
end

--- Convert a UTF-8 byte offset within a line to an LSP character offset. Inverse
--- of `char_to_byte`, with the same clamping/fallback behavior.
--- @param line string|nil
--- @param byte integer
--- @param enc string
--- @return integer char
function M.byte_to_char(line, byte, enc)
    if type(line) ~= "string" then
        return byte
    end
    local ok, ch = pcall(vim.str_utfindex, line, enc, byte, false)
    if ok and ch ~= nil then
        return ch
    end
    return byte
end

--- @param pos table LSP Position { line, character }
--- @param get_line fun(row: integer): string|nil 0-based line text
--- @param enc string
--- @return table wire_pos { line, byte_col }
function M.lsp_pos_to_wire(pos, get_line, enc)
    return {
        line = pos.line,
        byte_col = M.char_to_byte(get_line(pos.line), pos.character, enc),
    }
end

--- @param pos table wire Position { line, byte_col }
--- @param get_line fun(row: integer): string|nil
--- @param enc string
--- @return table lsp_pos { line, character }
function M.wire_pos_to_lsp(pos, get_line, enc)
    return {
        line = pos.line,
        character = M.byte_to_char(get_line(pos.line), pos.byte_col, enc),
    }
end

--- @param range table LSP Range { start, end }
--- @param get_line fun(row: integer): string|nil
--- @param enc string
--- @return table wire_range
function M.lsp_range_to_wire(range, get_line, enc)
    return {
        start = M.lsp_pos_to_wire(range.start, get_line, enc),
        ["end"] = M.lsp_pos_to_wire(range["end"], get_line, enc),
    }
end

--- @param range table wire Range { start, end }
--- @param get_line fun(row: integer): string|nil
--- @param enc string
--- @return table lsp_range
function M.wire_range_to_lsp(range, get_line, enc)
    return {
        start = M.wire_pos_to_lsp(range.start, get_line, enc),
        ["end"] = M.wire_pos_to_lsp(range["end"], get_line, enc),
    }
end

--- Map a vim.diagnostic item (native byte offsets) to a wire Diagnostic.
--- @param d table vim.Diagnostic
--- @return table diagnostic wire Diagnostic
function M.diagnostic_to_wire(d)
    local out = {
        range = {
            start = { line = d.lnum, byte_col = d.col },
            ["end"] = {
                line = d.end_lnum or d.lnum,
                byte_col = d.end_col or d.col,
            },
        },
        severity = M.severity_to_wire(d.severity),
        message = d.message or "",
    }
    if d.source and d.source ~= "" then
        out.source = d.source
    end
    if d.code ~= nil then
        out.code = tostring(d.code)
    end
    return out
end

--- Flatten an LSP documentSymbol/SymbolInformation response into a flat wire
--- DocumentSymbol list, expressing DocumentSymbol nesting through
--- `container_name` rather than a child tree.
--- @param result table|nil LSP documentSymbol response
--- @param get_line fun(row: integer): string|nil for the queried document
--- @param enc string
--- @return table symbols wire DocumentSymbol[]
function M.symbols_to_wire(result, get_line, enc)
    local out = {}
    if type(result) ~= "table" then
        return out
    end
    local function walk(items, container)
        for _, s in ipairs(items) do
            if s.range then -- DocumentSymbol (hierarchical)
                out[#out + 1] = {
                    name = s.name,
                    kind = M.symbol_kind_to_wire(s.kind),
                    detail = s.detail or "",
                    container_name = container or "",
                    range = M.lsp_range_to_wire(s.range, get_line, enc),
                    selection_range = M.lsp_range_to_wire(
                        s.selectionRange or s.range,
                        get_line,
                        enc
                    ),
                }
                if s.children then
                    walk(s.children, s.name)
                end
            elseif s.location then -- SymbolInformation (flat)
                out[#out + 1] = {
                    name = s.name,
                    kind = M.symbol_kind_to_wire(s.kind),
                    detail = "",
                    container_name = s.containerName or "",
                    range = M.lsp_range_to_wire(
                        s.location.range,
                        get_line,
                        enc
                    ),
                    selection_range = M.lsp_range_to_wire(
                        s.location.range,
                        get_line,
                        enc
                    ),
                }
            end
        end
    end
    walk(result, nil)
    return out
end

--- Normalize an LSP definition/references response (Location, Location[], or
--- LocationLink[]) into wire Location[]. Locations may point outside the
--- worktree; the daemon does not filter them.
--- @param result table|nil
--- @param get_line_for_uri fun(uri: string, row: integer): string|nil
--- @param enc string
--- @return table locations wire Location[]
function M.locations_to_wire(result, get_line_for_uri, enc)
    local out = {}
    if type(result) ~= "table" then
        return out
    end
    -- A single Location/LocationLink arrives as an object, not an array.
    local items = result
    if result.uri or result.targetUri then
        items = { result }
    end
    for _, loc in ipairs(items) do
        local uri = loc.uri or loc.targetUri
        local range = loc.range or loc.targetSelectionRange or loc.targetRange
        if uri and range then
            local get_line = function(row)
                return get_line_for_uri(uri, row)
            end
            out[#out + 1] = {
                uri = uri,
                range = M.lsp_range_to_wire(range, get_line, enc),
            }
        end
    end
    return out
end

--- Reduce an LSP hover result's contents (MarkupContent, MarkedString, or an
--- array of MarkedString) to a plain string.
--- @param contents any
--- @return string
function M.hover_contents_to_string(contents)
    if contents == nil then
        return ""
    end
    if type(contents) == "string" then
        return contents
    end
    if type(contents) ~= "table" then
        return ""
    end
    -- MarkupContent { kind, value } or MarkedString { language, value }.
    if contents.value and contents[1] == nil then
        return contents.value
    end
    local parts = {}
    for _, c in ipairs(contents) do
        if type(c) == "string" then
            parts[#parts + 1] = c
        elseif type(c) == "table" and c.value then
            parts[#parts + 1] = c.value
        end
    end
    return table.concat(parts, "\n")
end

--- Convert an LSP WorkspaceEdit into wire FileChange[], stamping each target's
--- Base through base_resolver so the result submits to file.apply_change_set
--- as-is.
--- @param edit table|nil LSP WorkspaceEdit
--- @param get_line_for_uri fun(uri: string, row: integer): string|nil
--- @param base_resolver fun(uri: string): table wire FileBase
--- @param enc string
--- @return table changes wire FileChange[]
function M.workspace_edit_to_changes(edit, get_line_for_uri, base_resolver, enc)
    local changes = {}
    if type(edit) ~= "table" then
        return changes
    end
    local function add(uri, text_edits)
        local get_line = function(row)
            return get_line_for_uri(uri, row)
        end
        local edits = {}
        for _, te in ipairs(text_edits) do
            edits[#edits + 1] = {
                range = M.lsp_range_to_wire(te.range, get_line, enc),
                new_text = te.newText or "",
            }
        end
        changes[#changes + 1] = {
            uri = uri,
            base = base_resolver(uri),
            kind = "patch",
            edits = edits,
        }
    end
    if edit.changes then
        for uri, text_edits in pairs(edit.changes) do
            add(uri, text_edits)
        end
    elseif edit.documentChanges then
        for _, dc in ipairs(edit.documentChanges) do
            if dc.textDocument and dc.edits then
                add(dc.textDocument.uri, dc.edits)
            end
        end
    end
    return changes
end

--- Convert an LSP codeAction response ((Command | CodeAction)[]) into wire
--- CodeAction[]. An edit-carrying action is resolved into change-set-ready
--- Changes and `edit=true`; a command-only action is listed with `edit=false`
--- for visibility (it cannot be applied through the change-set path). This is
--- list-only: actions whose edits require a codeAction/resolve round-trip are
--- reported command-style (edit=false) rather than resolved.
--- @param result table|nil
--- @param get_line_for_uri fun(uri: string, row: integer): string|nil
--- @param base_resolver fun(uri: string): table
--- @param enc string
--- @return table actions wire CodeAction[]
function M.code_actions_to_wire(result, get_line_for_uri, base_resolver, enc)
    local out = {}
    if type(result) ~= "table" then
        return out
    end
    for _, a in ipairs(result) do
        local changes = {}
        if a.edit then
            changes = M.workspace_edit_to_changes(
                a.edit,
                get_line_for_uri,
                base_resolver,
                enc
            )
        end
        out[#out + 1] = {
            title = a.title or "",
            kind = a.kind or "",
            edit = #changes > 0,
            changes = changes,
        }
    end
    return out
end

return M
