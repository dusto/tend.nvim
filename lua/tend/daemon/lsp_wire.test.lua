local assert = require("tests.helpers.assert")

describe("tend.daemon.lsp_wire", function()
    local Wire = require("tend.daemon.lsp_wire")

    -- "héllo" — h is 1 byte / 1 utf-16 unit, é is 2 bytes / 1 utf-16 unit, so an
    -- LSP character offset and a wire byte offset diverge after the é.
    local LINE = "héllo world"
    local function get_line(_)
        return LINE
    end
    local function get_line_for_uri(_, _)
        return LINE
    end

    it("maps diagnostic severity numbers to wire names", function()
        assert.equal("error", Wire.severity_to_wire(1))
        assert.equal("warning", Wire.severity_to_wire(2))
        assert.equal("info", Wire.severity_to_wire(3))
        assert.equal("hint", Wire.severity_to_wire(4))
        assert.equal("info", Wire.severity_to_wire(nil))
    end)

    it("maps LSP SymbolKind numbers to wire names", function()
        assert.equal("function", Wire.symbol_kind_to_wire(12))
        assert.equal("struct", Wire.symbol_kind_to_wire(23))
        assert.equal("enum_member", Wire.symbol_kind_to_wire(22))
        assert.equal("", Wire.symbol_kind_to_wire(99))
    end)

    it(
        "converts LSP character offsets to byte offsets past a multibyte char",
        function()
            -- After "hé" there are 2 utf-16 units but 3 bytes.
            assert.equal(3, Wire.char_to_byte(LINE, 2, "utf-16"))
            -- Inverse.
            assert.equal(2, Wire.byte_to_char(LINE, 3, "utf-16"))
        end
    )

    it("clamps an out-of-range offset and falls back without a line", function()
        assert.equal(#LINE, Wire.char_to_byte(LINE, 999, "utf-16"))
        assert.equal(7, Wire.char_to_byte(nil, 7, "utf-16"))
        assert.equal(7, Wire.byte_to_char(nil, 7, "utf-16"))
    end)

    it(
        "maps a vim.diagnostic item (native byte offsets) to a wire Diagnostic",
        function()
            local d = {
                lnum = 4,
                col = 2,
                end_lnum = 4,
                end_col = 9,
                severity = 1,
                message = "undefined name",
                source = "lua_ls",
                code = 113,
            }
            local w = Wire.diagnostic_to_wire(d)
            assert.same({ line = 4, byte_col = 2 }, w.range.start)
            assert.same({ line = 4, byte_col = 9 }, w.range["end"])
            assert.equal("error", w.severity)
            assert.equal("undefined name", w.message)
            assert.equal("lua_ls", w.source)
            assert.equal("113", w.code)
        end
    )

    it(
        "omits diagnostic source/code when absent and defaults end to start",
        function()
            local w = Wire.diagnostic_to_wire({
                lnum = 1,
                col = 0,
                severity = 2,
                message = "x",
            })
            assert.same({ line = 1, byte_col = 0 }, w.range["end"])
            assert.is_nil(w.source)
            assert.is_nil(w.code)
        end
    )

    it(
        "flattens hierarchical DocumentSymbols through container_name",
        function()
            local result = {
                {
                    name = "Server",
                    kind = 23, -- struct
                    range = {
                        start = { line = 0, character = 0 },
                        ["end"] = { line = 9, character = 0 },
                    },
                    selectionRange = {
                        start = { line = 0, character = 6 },
                        ["end"] = { line = 0, character = 12 },
                    },
                    children = {
                        {
                            name = "Serve",
                            kind = 6, -- method
                            range = {
                                start = { line = 2, character = 2 },
                                ["end"] = { line = 4, character = 2 },
                            },
                            selectionRange = {
                                start = { line = 2, character = 2 },
                                ["end"] = { line = 2, character = 7 },
                            },
                        },
                    },
                },
            }
            local syms = Wire.symbols_to_wire(result, get_line, "utf-16")
            assert.equal(2, #syms)
            assert.equal("Server", syms[1].name)
            assert.equal("struct", syms[1].kind)
            assert.equal("", syms[1].container_name)
            assert.equal("Serve", syms[2].name)
            assert.equal("method", syms[2].kind)
            assert.equal("Server", syms[2].container_name)
        end
    )

    it(
        "flattens SymbolInformation using its location and containerName",
        function()
            local result = {
                {
                    name = "helper",
                    kind = 12,
                    containerName = "pkg",
                    location = {
                        uri = "file:///a.lua",
                        range = {
                            start = { line = 3, character = 0 },
                            ["end"] = { line = 3, character = 6 },
                        },
                    },
                },
            }
            local syms = Wire.symbols_to_wire(result, get_line, "utf-16")
            assert.equal(1, #syms)
            assert.equal("helper", syms[1].name)
            assert.equal("pkg", syms[1].container_name)
            assert.same(syms[1].range, syms[1].selection_range)
        end
    )

    it("returns an empty list for a nil symbols result", function()
        assert.same({}, Wire.symbols_to_wire(nil, get_line, "utf-16"))
    end)

    it("normalizes a single Location into a one-element wire list", function()
        local locs = Wire.locations_to_wire({
            uri = "file:///a.lua",
            range = {
                start = { line = 1, character = 2 },
                ["end"] = { line = 1, character = 5 },
            },
        }, get_line_for_uri, "utf-16")
        assert.equal(1, #locs)
        assert.equal("file:///a.lua", locs[1].uri)
        assert.equal(3, locs[1].range.start.byte_col) -- char 2 past "hé" -> byte 3
    end)

    it("normalizes LocationLinks (targetUri/targetSelectionRange)", function()
        local locs = Wire.locations_to_wire({
            {
                targetUri = "file:///b.lua",
                targetRange = {
                    start = { line = 0, character = 0 },
                    ["end"] = { line = 2, character = 0 },
                },
                targetSelectionRange = {
                    start = { line = 0, character = 4 },
                    ["end"] = { line = 0, character = 8 },
                },
            },
        }, get_line_for_uri, "utf-16")
        assert.equal(1, #locs)
        assert.equal("file:///b.lua", locs[1].uri)
        -- Prefers targetSelectionRange over targetRange.
        assert.equal(0, locs[1].range.start.line)
    end)

    it("reduces hover contents of every shape to a string", function()
        assert.equal("plain", Wire.hover_contents_to_string("plain"))
        assert.equal(
            "md body",
            Wire.hover_contents_to_string({
                kind = "markdown",
                value = "md body",
            })
        )
        assert.equal(
            "a\nb",
            Wire.hover_contents_to_string({
                "a",
                { language = "lua", value = "b" },
            })
        )
        assert.equal("", Wire.hover_contents_to_string(nil))
    end)

    it("converts a WorkspaceEdit.changes map into based FileChanges", function()
        local base = function(uri)
            return { content_hash = "hash-of-" .. uri }
        end
        local changes = Wire.workspace_edit_to_changes({
            changes = {
                ["file:///a.lua"] = {
                    {
                        range = {
                            start = { line = 0, character = 0 },
                            ["end"] = { line = 0, character = 2 },
                        },
                        newText = "X",
                    },
                },
            },
        }, get_line_for_uri, base, "utf-16")
        assert.equal(1, #changes)
        assert.equal("file:///a.lua", changes[1].uri)
        assert.equal("patch", changes[1].kind)
        assert.same({ content_hash = "hash-of-file:///a.lua" }, changes[1].base)
        assert.equal("X", changes[1].edits[1].new_text)
    end)

    it("converts WorkspaceEdit.documentChanges", function()
        local base = function(_)
            return { changedtick = 7 }
        end
        local changes = Wire.workspace_edit_to_changes({
            documentChanges = {
                {
                    textDocument = { uri = "file:///c.lua", version = 1 },
                    edits = {
                        {
                            range = {
                                start = { line = 1, character = 0 },
                                ["end"] = { line = 1, character = 0 },
                            },
                            newText = "// c",
                        },
                    },
                },
            },
        }, get_line_for_uri, base, "utf-16")
        assert.equal(1, #changes)
        assert.equal("file:///c.lua", changes[1].uri)
        assert.same({ changedtick = 7 }, changes[1].base)
    end)

    it(
        "lists an edit-carrying code action as edit=true with changes",
        function()
            local base = function(_)
                return { changedtick = 1 }
            end
            local actions = Wire.code_actions_to_wire({
                {
                    title = "Organize Imports",
                    kind = "source.organizeImports",
                    edit = {
                        changes = {
                            ["file:///a.lua"] = {
                                {
                                    range = {
                                        start = { line = 0, character = 0 },
                                        ["end"] = { line = 0, character = 0 },
                                    },
                                    newText = "",
                                },
                            },
                        },
                    },
                },
            }, get_line_for_uri, base, "utf-16")
            assert.equal(1, #actions)
            assert.equal("Organize Imports", actions[1].title)
            assert.equal("source.organizeImports", actions[1].kind)
            assert.is_true(actions[1].edit)
            assert.equal(1, #actions[1].changes)
        end
    )

    it(
        "lists a command-only code action as edit=false with no changes",
        function()
            local base = function(_)
                return {}
            end
            local actions = Wire.code_actions_to_wire({
                { title = "Run test", command = "test.run" },
            }, get_line_for_uri, base, "utf-16")
            assert.equal(1, #actions)
            assert.equal("Run test", actions[1].title)
            assert.is_false(actions[1].edit)
            assert.same({}, actions[1].changes)
        end
    )
end)
