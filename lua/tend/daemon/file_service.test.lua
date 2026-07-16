local assert = require("tests.helpers.assert")
local rpc = require("tend.rpc.client")

describe("tend.daemon.file_service", function()
    local FileServiceMod = require("tend.daemon.file_service")

    -- A provider (colon-called) that records its calls and returns canned
    -- results, so dispatch is tested without touching real buffers.
    local function fake_provider()
        local rec = { calls = {} }
        rec.read_buffer = function(_, uri)
            rec.calls.read_buffer = { uri }
            return { content = "x\n", base = { changedtick = 3 }, open = true }
        end
        rec.write_buffer = function(_, uri, content, base)
            rec.calls.write_buffer = { uri, content, base }
            if base and base.changedtick == 99 then
                return nil, { code = -32600, message = "conflict" }
            end
            return { base = { changedtick = 4 } }
        end
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
        local svc = FileServiceMod.FileService.new({ provider = provider })
        return svc, provider
    end

    it(
        "read_buffer forwards the uri and replies with the provider result",
        function()
            local svc, provider = new_service()
            local client, sent = fake_client()
            svc:bootstrap(client)

            client:feed(frame({
                jsonrpc = "2.0",
                id = 1,
                method = FileServiceMod.METHOD_READ_BUFFER,
                params = { uri = "file:///a.lua" },
            }))
            assert.equal("file:///a.lua", provider.calls.read_buffer[1])
            assert.equal("x\n", sent[1].result.content)
            assert.is_nil(sent[1].error)
        end
    )

    it(
        "write_buffer forwards uri/content/base and replies with the new base",
        function()
            local svc, provider = new_service()
            local client, sent = fake_client()
            svc:bootstrap(client)

            client:feed(frame({
                jsonrpc = "2.0",
                id = 2,
                method = FileServiceMod.METHOD_WRITE_BUFFER,
                params = {
                    uri = "file:///a.lua",
                    content = "new\n",
                    base = { changedtick = 7 },
                },
            }))
            assert.equal("file:///a.lua", provider.calls.write_buffer[1])
            assert.equal("new\n", provider.calls.write_buffer[2])
            assert.same({ changedtick = 7 }, provider.calls.write_buffer[3])
            assert.equal(4, sent[1].result.base.changedtick)
            assert.is_nil(sent[1].error)
        end
    )

    it("write_buffer surfaces a provider conflict as an error reply", function()
        local svc = new_service()
        local client, sent = fake_client()
        svc:bootstrap(client)

        client:feed(frame({
            jsonrpc = "2.0",
            id = 3,
            method = FileServiceMod.METHOD_WRITE_BUFFER,
            params = {
                uri = "file:///a.lua",
                content = "new\n",
                base = { changedtick = 99 },
            },
        }))
        assert.is_nil(sent[1].result)
        assert.equal("conflict", sent[1].error.message)
    end)

    it("degrades to an empty uri on malformed read params", function()
        local svc, provider = new_service()
        local client, sent = fake_client()
        svc:bootstrap(client)

        client:feed(frame({
            jsonrpc = "2.0",
            id = 4,
            method = FileServiceMod.METHOD_READ_BUFFER,
        }))
        assert.equal("", provider.calls.read_buffer[1])
        assert.equal(4, sent[1].id)
    end)
end)
