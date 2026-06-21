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

    it("pins plugin_to_daemon and daemon_to_client minimums", function()
        assert.is_not_nil(Versions.REQUIRED.plugin_to_daemon)
        assert.is_not_nil(Versions.REQUIRED.daemon_to_client)
    end)

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
