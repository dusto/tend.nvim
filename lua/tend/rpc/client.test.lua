local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")
local rpc = require("tend.rpc.client")

-- A fake transport: captures every framed message the client sends, decoded.
local function fake()
    local sent = {}
    local client = rpc.Client.new({
        writer = function(data)
            -- The client frames one message per write, terminated by a newline.
            assert.equal(data:sub(-1), "\n")
            table.insert(sent, vim.json.decode(vim.trim(data)))
        end,
    })
    return client, sent
end

-- Encode a peer->client message the way the daemon would frame it.
local function frame(msg)
    return vim.json.encode(msg) .. "\n"
end

describe("tend.rpc.client request/response", function()
    it("sends a request and resolves the matching response", function()
        local client, sent = fake()
        local got_err, got_result
        client:request(
            "workspace.open",
            { dir = "/repo" },
            function(err, result)
                got_err, got_result = err, result
            end
        )

        assert.equal(#sent, 1)
        assert.equal(sent[1].jsonrpc, "2.0")
        assert.equal(sent[1].method, "workspace.open")
        assert.same(sent[1].params, { dir = "/repo" })
        local id = sent[1].id
        assert.is_not_nil(id)

        client:feed(frame({
            jsonrpc = "2.0",
            id = id,
            result = { workspace_id = "ws1" },
        }))
        assert.is_nil(got_err)
        assert.same(got_result, { workspace_id = "ws1" })
    end)

    it("delivers an error response to the requester", function()
        local client, sent = fake()
        local got_err
        client:request("task.show", { ref = {} }, function(err)
            got_err = err
        end)
        client:feed(frame({
            jsonrpc = "2.0",
            id = sent[1].id,
            error = { code = -32602, message = "invalid params" },
        }))
        assert.is_not_nil(got_err)
        assert.equal(got_err.code, -32602)
    end)

    it(
        "gives each request a distinct id and routes replies independently",
        function()
            local client, sent = fake()
            local a, b
            client:request("one", nil, function(_, r)
                a = r
            end)
            client:request("two", nil, function(_, r)
                b = r
            end)
            assert.is_not_nil(sent[1].id)
            assert.is_not_nil(sent[2].id)
            assert.is_true(sent[1].id ~= sent[2].id)

            -- Reply out of order; each lands in its own callback.
            client:feed(
                frame({ jsonrpc = "2.0", id = sent[2].id, result = "B" })
            )
            client:feed(
                frame({ jsonrpc = "2.0", id = sent[1].id, result = "A" })
            )
            assert.equal(a, "A")
            assert.equal(b, "B")
        end
    )
end)

describe("tend.rpc.client notifications", function()
    it("sends a notification with no id", function()
        local client, sent = fake()
        client:notify("events.unsubscribe", { stream_id = "session:s1" })
        assert.equal(#sent, 1)
        assert.equal(sent[1].method, "events.unsubscribe")
        assert.is_nil(sent[1].id)
    end)

    it("dispatches an inbound notification and sends no reply", function()
        local client, sent = fake()
        local seen
        client:on_notification("event.push", function(params)
            seen = params
        end)
        client:feed(frame({
            jsonrpc = "2.0",
            method = "event.push",
            params = { event = { type = "turn_end" } },
        }))
        assert.same(seen, { event = { type = "turn_end" } })
        assert.equal(#sent, 0) -- notifications are never replied to
    end)
end)

describe("tend.rpc.client inbound requests", function()
    it("dispatches a request and replies with the handler result", function()
        local client, sent = fake()
        client:on_request("editor.read_buffer", function(params)
            return { content = "x", open = true, uri = params.uri }
        end)
        client:feed(frame({
            jsonrpc = "2.0",
            id = 7,
            method = "editor.read_buffer",
            params = { uri = "file:///a" },
        }))
        assert.equal(#sent, 1)
        assert.equal(sent[1].id, 7)
        assert.same(
            sent[1].result,
            { content = "x", open = true, uri = "file:///a" }
        )
    end)

    it("replies method-not-found for an unregistered request", function()
        local client, sent = fake()
        client:feed(
            frame({ jsonrpc = "2.0", id = 9, method = "editor.unknown" })
        )
        assert.equal(sent[1].id, 9)
        assert.equal(sent[1].error.code, rpc.ERR_METHOD_NOT_FOUND)
    end)

    it("sends the error a handler returns", function()
        local client, sent = fake()
        client:on_request("editor.selection", function()
            return nil, { code = 1003, message = "editor unavailable" }
        end)
        client:feed(
            frame({ jsonrpc = "2.0", id = 3, method = "editor.selection" })
        )
        assert.equal(sent[1].error.code, 1003)
        assert.is_nil(sent[1].result)
    end)

    it("reports an internal error when a handler throws", function()
        local client, sent = fake()
        client:on_request("editor.read_buffer", function()
            error("boom")
        end)
        client:feed(
            frame({ jsonrpc = "2.0", id = 4, method = "editor.read_buffer" })
        )
        assert.equal(sent[1].error.code, rpc.ERR_INTERNAL)
    end)
end)

describe("tend.rpc.client framing", function()
    it("buffers a partial line until the rest arrives", function()
        local client, _ = fake()
        local seen = 0
        client:on_notification("ping", function()
            seen = seen + 1
        end)
        local line = frame({ jsonrpc = "2.0", method = "ping" })
        client:feed(line:sub(1, 5))
        assert.equal(seen, 0) -- incomplete
        client:feed(line:sub(6))
        assert.equal(seen, 1)
    end)

    it("routes multiple messages delivered in one chunk, in order", function()
        local client, _ = fake()
        local order = {}
        client:on_notification("n", function(params)
            table.insert(order, params.i)
        end)
        local chunk = frame({
            jsonrpc = "2.0",
            method = "n",
            params = { i = 1 },
        }) .. frame({
            jsonrpc = "2.0",
            method = "n",
            params = { i = 2 },
        })
        client:feed(chunk)
        assert.same(order, { 1, 2 })
    end)

    it("reports a parse error and keeps going", function()
        local errors = {}
        local client = rpc.Client.new({
            writer = function() end,
            on_error = function(msg)
                table.insert(errors, msg)
            end,
        })
        local seen = false
        client:on_notification("ok", function()
            seen = true
        end)
        client:feed("{not json}\n" .. frame({ jsonrpc = "2.0", method = "ok" }))
        assert.equal(#errors, 1)
        assert.is_true(seen) -- the valid message after the bad one still routes
    end)
end)

-- connect() drives dispatch and callbacks through vim.schedule, so this is a
-- child-process test: vim.wait()/vim.uv.sleep() in the same process can't
-- reliably flush scheduled work (and can silently skip the test). The child
-- runs an in-process JSON-RPC peer plus the client; the parent flushes the
-- child's event loop and asserts on state the callbacks stored in vim.g.
describe("tend.rpc.client over a real unix socket", function()
    local child = Child.new()

    before_each(function()
        child.setup()
    end)

    after_each(function()
        child.stop()
    end)

    it("round-trips through connect() outside fast-event context", function()
        -- A minimal JSON-RPC peer replies to any request by echoing its params.
        -- The peer's pipes and the client are kept in _G so they outlive this
        -- child.lua call; the callbacks record state in vim.g for the parent.
        child.lua([[
            local rpc = require("tend.rpc.client")
            local uv = vim.uv or vim.loop
            local dir = vim.fn.tempname()
            vim.fn.mkdir(dir, "p")
            local path = dir .. "/test.sock"

            local server = uv.new_pipe(false)
            if not server then
                error("failed to create server pipe")
            end
            server:bind(path)
            _G.tend_test_conns = {}
            server:listen(16, function()
                local conn = uv.new_pipe(false)
                if not conn then
                    return
                end
                table.insert(_G.tend_test_conns, conn)
                server:accept(conn)
                local buf = ""
                conn:read_start(function(_, data)
                    if not data then
                        return
                    end
                    buf = buf .. data
                    local lines = vim.split(buf, "\n", { plain = true })
                    buf = lines[#lines]
                    for i = 1, #lines - 1 do
                        if vim.trim(lines[i]) ~= "" then
                            local msg = vim.json.decode(lines[i])
                            conn:write(vim.json.encode({
                                jsonrpc = "2.0",
                                id = msg.id,
                                result = msg.params,
                            }) .. "\n")
                        end
                    end
                end)
            end)
            _G.tend_test_server = server

            rpc.connect({ path = path }, function(c, err)
                vim.g.tend_connect_ok = err == nil
                vim.g.tend_connect_fast = vim.in_fast_event()
                _G.tend_test_client = c
                c:request("echo", { hello = "world" }, function(_, r)
                    vim.g.tend_reply_fast = vim.in_fast_event()
                    vim.g.tend_test_result = r
                end)
            end)
        ]])

        -- Flush the child's event loop until the reply callback stores a result.
        local result
        for _ = 1, 200 do
            child.flush()
            vim.uv.sleep(10)
            result = child.lua_get("vim.g.tend_test_result")
            if result ~= vim.NIL then
                break
            end
        end

        assert.same(result, { hello = "world" })
        assert.is_true(child.lua_get("vim.g.tend_connect_ok"))
        -- The callbacks ran on the main loop, where vim.api is available.
        assert.is_false(child.lua_get("vim.g.tend_connect_fast"))
        assert.is_false(child.lua_get("vim.g.tend_reply_fast"))
    end)
end)
