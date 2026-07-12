local assert = require("tests.helpers.assert")
local rpc = require("tend.rpc.client")

describe("tend.daemon.lsp_service", function()
    local LspServiceMod = require("tend.daemon.lsp_service")

    -- A provider (method shape: colon-called) that records its calls and returns
    -- canned wire results, so the dispatch is tested without a live LSP.
    local function fake_provider()
        local rec = { calls = {} }
        local function record(name)
            return function(_, ...)
                rec.calls[name] = { ... }
                return { ok = name }
            end
        end
        rec.current_buffer = function(_)
            rec.calls.current_buffer = {}
            return { uri = "file:///cur.lua" }
        end
        rec.diagnostics = record("diagnostics")
        rec.symbols = record("symbols")
        rec.definition = record("definition")
        rec.references = record("references")
        rec.hover = record("hover")
        rec.code_actions = record("code_actions")
        return rec
    end

    local function fake_client()
        local sent = {}
        local client = rpc.Client.new({
            writer = function(data)
                table.insert(sent, vim.json.decode(vim.trim(data)))
            end,
        })
        return client, sent
    end

    local function frame(msg)
        return vim.json.encode(msg) .. "\n"
    end

    local function new_service()
        local provider = fake_provider()
        local svc = LspServiceMod.LspService.new({ provider = provider })
        return svc, provider
    end

    it("current_buffer answers with the provider result", function()
        local svc, provider = new_service()
        local client, sent = fake_client()
        svc:bootstrap(client)

        client:feed(frame({
            jsonrpc = "2.0",
            id = 1,
            method = LspServiceMod.METHOD_CURRENT_BUFFER,
        }))
        assert.is_not_nil(provider.calls.current_buffer)
        assert.equal("file:///cur.lua", sent[1].result.uri)
        assert.is_nil(sent[1].error)
    end)

    it("diagnostics forwards the uri and replies", function()
        local svc, provider = new_service()
        local client, sent = fake_client()
        svc:bootstrap(client)

        client:feed(frame({
            jsonrpc = "2.0",
            id = 2,
            method = LspServiceMod.METHOD_DIAGNOSTICS,
            params = { uri = "file:///a.lua" },
        }))
        assert.equal("file:///a.lua", provider.calls.diagnostics[1])
        assert.equal("diagnostics", sent[1].result.ok)
    end)

    it("definition forwards uri and position", function()
        local svc, provider = new_service()
        local client, sent = fake_client()
        svc:bootstrap(client)

        client:feed(frame({
            jsonrpc = "2.0",
            id = 3,
            method = LspServiceMod.METHOD_DEFINITION,
            params = {
                uri = "file:///a.lua",
                position = { line = 4, byte_col = 2 },
            },
        }))
        assert.equal("file:///a.lua", provider.calls.definition[1])
        assert.same({ line = 4, byte_col = 2 }, provider.calls.definition[2])
        assert.equal(3, sent[1].id)
    end)

    it("references forwards include_declaration", function()
        local svc, provider = new_service()
        local client = fake_client()
        svc:bootstrap(client)

        client:feed(frame({
            jsonrpc = "2.0",
            id = 4,
            method = LspServiceMod.METHOD_REFERENCES,
            params = {
                uri = "file:///a.lua",
                position = { line = 1, byte_col = 0 },
                include_declaration = true,
            },
        }))
        assert.is_true(provider.calls.references[3])
    end)

    it("code_actions forwards range and only", function()
        local svc, provider = new_service()
        local client = fake_client()
        svc:bootstrap(client)

        client:feed(frame({
            jsonrpc = "2.0",
            id = 5,
            method = LspServiceMod.METHOD_CODE_ACTIONS,
            params = {
                uri = "file:///a.lua",
                range = {
                    start = { line = 0, byte_col = 0 },
                    ["end"] = { line = 0, byte_col = 4 },
                },
                only = { "quickfix" },
            },
        }))
        assert.equal("file:///a.lua", provider.calls.code_actions[1])
        assert.equal(0, provider.calls.code_actions[2].start.line)
        assert.same({ "quickfix" }, provider.calls.code_actions[3])
    end)

    it("degrades to defaults on malformed params but still replies", function()
        local svc, provider = new_service()
        local client, sent = fake_client()
        svc:bootstrap(client)

        client:feed(frame({
            jsonrpc = "2.0",
            id = 6,
            method = LspServiceMod.METHOD_HOVER,
            params = {},
        }))
        assert.equal("", provider.calls.hover[1])
        assert.same({ line = 0, byte_col = 0 }, provider.calls.hover[2])
        assert.equal(6, sent[1].id)
        assert.is_nil(sent[1].error)
    end)
end)
