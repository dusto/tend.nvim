local assert = require("tests.helpers.assert")
local rpc = require("tend.rpc.client")

describe("tend.daemon.editor_service", function()
    local EditorServiceMod = require("tend.daemon.editor_service")

    -- A review backend (stateless module shape: dot-called functions) that
    -- records calls instead of driving windows.
    local function fake_review()
        local rec = { opened = nil, diffed = nil }
        rec.open_files = function(uris)
            rec.opened = uris
            return {}
        end
        rec.show_snapshots = function(csid, files)
            rec.diffed = { change_set_id = csid, files = files }
            return {}
        end
        return rec
    end

    -- A fake transport recording framed messages, plus a wired client.
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
        local review = fake_review()
        local svc = EditorServiceMod.EditorService.new({ review = review })
        return svc, review
    end

    it(
        "bootstrap registers editor.open and editor.diff request handlers",
        function()
            local svc, review = new_service()
            local client, sent = fake_client()
            svc:bootstrap(client)

            client:feed(frame({
                jsonrpc = "2.0",
                id = 1,
                method = EditorServiceMod.METHOD_OPEN,
                params = { uris = { "file:///repo/a.go", "file:///repo/b.go" } },
            }))
            assert.same(
                { "file:///repo/a.go", "file:///repo/b.go" },
                review.opened
            )
            -- A request gets a reply (an empty ack), not dropped.
            assert.equal(1, sent[1].id)
            assert.is_not_nil(sent[1].result)
        end
    )

    it("editor.diff renders the carried snapshots", function()
        local svc, review = new_service()
        local client, sent = fake_client()
        svc:bootstrap(client)

        client:feed(frame({
            jsonrpc = "2.0",
            id = 7,
            method = EditorServiceMod.METHOD_DIFF,
            params = {
                change_set_id = "cs-9",
                files = {
                    {
                        uri = "file:///repo/a.go",
                        before = "old",
                        after = "new",
                    },
                },
            },
        }))
        assert.equal("cs-9", review.diffed.change_set_id)
        assert.equal("file:///repo/a.go", review.diffed.files[1].uri)
        assert.equal("old", review.diffed.files[1].before)
        assert.equal("new", review.diffed.files[1].after)
        assert.equal(7, sent[1].id)
        assert.is_not_nil(sent[1].result)
    end)

    it("degrades cleanly on missing params", function()
        local svc, review = new_service()
        local client, sent = fake_client()
        svc:bootstrap(client)

        client:feed(frame({
            jsonrpc = "2.0",
            id = 3,
            method = EditorServiceMod.METHOD_OPEN,
            params = {},
        }))
        -- No uris: nothing opened, but still a well-formed reply, not an error.
        assert.same({}, review.opened)
        assert.equal(3, sent[1].id)
        assert.is_nil(sent[1].error)
    end)
end)
