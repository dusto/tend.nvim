local assert = require("tests.helpers.assert")

describe("tend.daemon.versions", function()
    local Versions = require("tend.daemon.versions")

    local function have(p2d)
        return {
            plugin_to_daemon = p2d,
            daemon_to_editor = "0.2.0",
            daemon_to_client = "0.1.0",
        }
    end

    it(
        "pins plugin_to_daemon, daemon_to_editor, and daemon_to_client",
        function()
            assert.is_not_nil(Versions.REQUIRED.plugin_to_daemon)
            assert.is_not_nil(Versions.REQUIRED.daemon_to_editor)
            assert.is_not_nil(Versions.REQUIRED.daemon_to_client)
        end
    )

    it(
        "requires the daemon version of the newest contract it relies on",
        function()
            -- The prompt's slash send relies on slash.invoke (plugin_to_daemon
            -- 0.14.0); a daemon that predates it (e.g. 0.13.0, which had
            -- slash.complete but no slash.invoke) must be rejected at the
            -- handshake, not fail later when a "/command" is first submitted.
            assert.is_false(Versions.satisfies({
                plugin_to_daemon = "0.13.0",
                daemon_to_editor = "0.2.0",
                daemon_to_client = "0.6.0",
            }))
            assert.is_true(Versions.satisfies({
                plugin_to_daemon = "0.14.0",
                daemon_to_editor = "0.2.0",
                daemon_to_client = "0.6.0",
            }))
        end
    )

    it(
        "requires the daemon->client version for the command-set event",
        function()
            -- The completion source consumes slash_commands_updated (daemon_to_client
            -- 0.6.0); an older event contract must be rejected at the handshake.
            assert.is_false(Versions.satisfies({
                plugin_to_daemon = "0.14.0",
                daemon_to_editor = "0.2.0",
                daemon_to_client = "0.5.0",
            }))
        end
    )

    it("accepts versions equal to the pin", function()
        local ok, why = Versions.satisfies({
            plugin_to_daemon = "0.2.0",
            daemon_to_client = "0.1.0",
        }, { plugin_to_daemon = "0.2.0", daemon_to_client = "0.1.0" })
        assert.is_nil(why)
        assert.is_true(ok)
    end)

    it("accepts newer minor and patch versions", function()
        assert.is_true(
            Versions.satisfies(have("0.5.2"), { plugin_to_daemon = "0.2.0" })
        )
    end)

    it("rejects an older version, naming the set", function()
        local ok, why =
            Versions.satisfies(have("0.1.0"), { plugin_to_daemon = "0.2.0" })
        assert.is_false(ok)
        why = why --[[@as string]]
        assert.is_not_nil(why:find("plugin_to_daemon", 1, true))
        assert.is_not_nil(why:find("0.1.0", 1, true))
        assert.is_not_nil(why:find("0.2.0", 1, true))
    end)

    it(
        "rejects a different major version even when numerically newer",
        function()
            local ok = Versions.satisfies(have("1.0.0"), {
                plugin_to_daemon = "0.2.0",
            })
            assert.is_false(ok)
        end
    )

    it("skips empty required fields", function()
        assert.is_true(Versions.satisfies({
            plugin_to_daemon = "9.9.9",
        }, { daemon_to_client = "" }))
    end)

    it("rejects a malformed or missing reported version", function()
        local ok, why = Versions.satisfies(have("not-a-version"), {
            plugin_to_daemon = "0.2.0",
        })
        assert.is_false(ok)
        assert.is_not_nil(why)
        local ok2 = Versions.satisfies({}, { plugin_to_daemon = "0.2.0" })
        assert.is_false(ok2)
    end)
end)
