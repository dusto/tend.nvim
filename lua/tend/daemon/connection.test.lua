local assert = require("tests.helpers.assert")
local rpc = require("tend.rpc.client")

describe("tend.daemon.connection", function()
    local ConnMod = require("tend.daemon.connection")

    -- Encode a peer->client message the way the daemon would frame it.
    local function frame(msg)
        return vim.json.encode(msg) .. "\n"
    end

    -- A controllable transport: connects are captured and completed manually
    -- with a fake rpc client; deferred reconnects are captured, not timed.
    local function harness()
        local h = { connects = {}, defers = {}, errors = {} }
        h.connect_fn = function(copts, cb)
            table.insert(h.connects, { opts = copts, cb = cb })
        end
        h.defer_fn = function(fn, ms)
            table.insert(h.defers, { fn = fn, ms = ms })
        end
        h.on_error = function(msg)
            table.insert(h.errors, msg)
        end
        h.subscriber = {
            bootstraps = {},
            disconnects = 0,
            bootstrap = function(self, client, epoch)
                table.insert(
                    self.bootstraps,
                    { client = client, epoch = epoch }
                )
            end,
            disconnected = function(self)
                self.disconnects = self.disconnects + 1
            end,
        }
        h.approvals = {
            bootstraps = 0,
            disconnects = 0,
            bootstrap = function(self)
                self.bootstraps = self.bootstraps + 1
            end,
            disconnected = function(self)
                self.disconnects = self.disconnects + 1
            end,
        }
        return h
    end

    --- @param h table
    --- @return tend.daemon.Connection
    local function new_conn(h)
        return ConnMod.Connection.new({
            client_id = "nvim-test",
            connect_fn = h.connect_fn,
            defer_fn = h.defer_fn,
            on_error = h.on_error,
            subscriber = h.subscriber --[[@as tend.rpc.StreamSubscriber]],
            approvals = h.approvals --[[@as tend.approval.Manager]],
            reconnect_delay_ms = 100,
        })
    end

    -- Complete the latest pending connect with a fake client and play the
    -- hello/register handshake; returns the client and its captured frames.
    local function accept(h, epoch)
        local pending = h.connects[#h.connects]
        local sent = {}
        local client = rpc.Client.new({
            writer = function(data)
                table.insert(sent, vim.json.decode(vim.trim(data)))
            end,
        })
        pending.cb(client, nil)
        assert.equal(ConnMod.METHOD_HELLO, sent[1].method)
        client:feed(frame({
            jsonrpc = "2.0",
            id = sent[1].id,
            result = {
                versions = {
                    plugin_to_daemon = "0.11.0",
                    daemon_to_editor = "0.2.0",
                    daemon_to_client = "0.1.0",
                },
                daemon_epoch = epoch or "epoch-1",
            },
        }))
        assert.equal(ConnMod.METHOD_REGISTER, sent[2].method)
        client:feed(frame({
            jsonrpc = "2.0",
            id = sent[2].id,
            result = { client_id = sent[2].params.client_id },
        }))
        return client, sent
    end

    it("start connects, handshakes, registers, and bootstraps", function()
        local h = harness()
        local conn = new_conn(h)
        conn:start()
        assert.equal("connecting", conn:status())
        assert.equal(1, #h.connects)

        local _, sent = accept(h, "epoch-1")
        assert.same({
            client_id = "nvim-test",
            role = "editor",
            prompt_capable = true,
        }, sent[2].params)
        assert.equal("connected", conn:status())
        assert.equal(1, #h.subscriber.bootstraps)
        assert.equal("epoch-1", h.subscriber.bootstraps[1].epoch)
        assert.equal(1, h.approvals.bootstraps)
    end)

    it("start is idempotent while connecting and connected", function()
        local h = harness()
        local conn = new_conn(h)
        conn:start()
        conn:start()
        assert.equal(1, #h.connects)
        accept(h)
        conn:start()
        assert.equal(1, #h.connects)
    end)

    it("requests pass through when connected", function()
        local h = harness()
        local conn = new_conn(h)
        conn:start()
        local client, sent = accept(h)
        local got
        conn:request("task.list", { workspace_id = "ws-1" }, function(_, r)
            got = r
        end)
        assert.equal("task.list", sent[3].method)
        client:feed(frame({
            jsonrpc = "2.0",
            id = sent[3].id,
            result = { tasks = {} },
        }))
        assert.same({ tasks = {} }, got)
    end)

    it("requests fail fast while disconnected", function()
        local h = harness()
        local conn = new_conn(h)
        local got_err
        conn:request("task.list", {}, function(err)
            got_err = err
        end)
        assert.equal(ConnMod.ERR_NOT_CONNECTED, got_err.code)
    end)

    it("when_connected queues until the bootstrap completes", function()
        local h = harness()
        local conn = new_conn(h)
        local ran = 0
        conn:when_connected(function()
            ran = ran + 1
        end)
        assert.equal(0, ran)
        conn:start()
        accept(h)
        assert.equal(1, ran)
        conn:when_connected(function()
            ran = ran + 1
        end)
        assert.equal(2, ran)
    end)

    it("a failed connect reports and schedules a retry", function()
        local h = harness()
        local conn = new_conn(h)
        conn:start()
        h.connects[1].cb(nil, "connect refused")
        assert.equal(1, #h.errors)
        assert.equal("disconnected", conn:status())
        assert.equal(1, #h.defers)
        h.defers[1].fn()
        assert.equal(2, #h.connects)
    end)

    it("a hello error closes the connection and retries", function()
        local h = harness()
        local conn = new_conn(h)
        conn:start()
        local sent = {}
        local client = rpc.Client.new({
            writer = function(data)
                table.insert(sent, vim.json.decode(vim.trim(data)))
            end,
        })
        h.connects[1].cb(client, nil)
        client:feed(frame({
            jsonrpc = "2.0",
            id = sent[1].id,
            error = { code = -32600, message = "bad hello" },
        }))
        assert.equal(1, #h.errors)
        assert.equal("disconnected", conn:status())
        assert.equal(1, #h.defers)
    end)

    it(
        "a disconnect notifies subscriber/approvals and reconnects with the new epoch",
        function()
            local h = harness()
            local conn = new_conn(h)
            conn:start()
            accept(h, "epoch-1")

            h.connects[1].opts.on_disconnect()
            assert.equal("disconnected", conn:status())
            assert.equal(1, h.subscriber.disconnects)
            assert.equal(1, h.approvals.disconnects)

            assert.equal(1, #h.defers)
            h.defers[1].fn()
            assert.equal(2, #h.connects)
            accept(h, "epoch-2")
            assert.equal("connected", conn:status())
            assert.equal("epoch-2", h.subscriber.bootstraps[2].epoch)
            assert.equal(2, h.approvals.bootstraps)
        end
    )

    it("hello carries the pinned required versions", function()
        local Versions = require("tend.daemon.versions")
        local h = harness()
        local conn = new_conn(h)
        conn:start()
        local _, sent = accept(h)
        assert.same(Versions.REQUIRED, sent[1].params.required)
    end)

    it("info reports the daemon versions and epoch when connected", function()
        local h = harness()
        local conn = new_conn(h)
        conn:start()
        accept(h, "epoch-9")
        local info = conn:info()
        assert.equal("connected", info.status)
        assert.equal("0.11.0", info.versions.plugin_to_daemon)
        assert.equal("epoch-9", info.daemon_epoch)
        assert.is_nil(info.version_mismatch)
    end)

    it("a version mismatch reports, stops, and never reconnects", function()
        local h = harness()
        local conn = new_conn(h)
        conn:start()
        local pending = h.connects[1]
        local sent = {}
        local client = rpc.Client.new({
            writer = function(data)
                table.insert(sent, vim.json.decode(vim.trim(data)))
            end,
        })
        pending.cb(client, nil)
        client:feed(frame({
            jsonrpc = "2.0",
            id = sent[1].id,
            result = {
                -- Older than the plugin's plugin_to_daemon pin.
                versions = {
                    plugin_to_daemon = "0.1.0",
                    daemon_to_editor = "0.2.0",
                    daemon_to_client = "0.1.0",
                },
                daemon_epoch = "epoch-1",
            },
        }))
        assert.equal(1, #h.errors)
        assert.is_not_nil(h.errors[1]:find("version mismatch", 1, true))
        -- No register attempt, no bootstrap, no scheduled retry.
        assert.equal(1, #sent)
        assert.equal(0, #h.subscriber.bootstraps)
        assert.equal("disconnected", conn:status())
        assert.equal(0, #h.defers)
        assert.is_not_nil(conn:info().version_mismatch)
    end)

    it("stop closes and suppresses reconnects", function()
        local h = harness()
        local conn = new_conn(h)
        conn:start()
        accept(h)
        conn:stop()
        assert.equal("disconnected", conn:status())
        -- The transport-level disconnect arriving after stop stays quiet.
        h.connects[1].opts.on_disconnect()
        assert.equal(0, #h.defers)
    end)
end)
