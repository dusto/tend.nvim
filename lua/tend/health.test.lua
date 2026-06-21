local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("Health", function()
    --- @type tend.Health
    local Health

    --- @type TestStub
    local start_stub
    --- @type TestStub
    local ok_stub
    --- @type TestStub
    local warn_stub
    --- @type TestStub
    local error_stub
    --- @type TestStub
    local info_stub
    --- @type TestStub
    local executable_stub

    local original_acp_health
    local original_config
    local original_clipboard_image

    local original_commands

    before_each(function()
        package.loaded["tend.health"] = nil
        original_acp_health = package.loaded["tend.acp.acp_health"]
        original_config = package.loaded["tend.config"]
        original_clipboard_image = package.loaded["tend.ui.clipboard_image"]
        original_commands = package.loaded["tend.commands"]

        package.loaded["tend.commands"] = {
            current = function()
                return nil
            end,
        }

        package.loaded["tend.acp.acp_health"] = {
            is_command_available = function()
                return true
            end,
            is_node_installed = function()
                return true
            end,
        }
        package.loaded["tend.config"] = {
            provider = "codex",
            acp_providers = {
                codex = {
                    name = "Codex",
                    command = "codex",
                },
            },
        }
        package.loaded["tend.ui.clipboard_image"] = {
            get_platform = function()
                return "wsl"
            end,
            is_supported = function()
                return false
            end,
        }

        start_stub = spy.stub(vim.health, "start")
        ok_stub = spy.stub(vim.health, "ok")
        warn_stub = spy.stub(vim.health, "warn")
        error_stub = spy.stub(vim.health, "error")
        info_stub = spy.stub(vim.health, "info")
        executable_stub = spy.stub(vim.fn, "executable")

        Health = require("tend.health")
    end)

    after_each(function()
        start_stub:revert()
        ok_stub:revert()
        warn_stub:revert()
        error_stub:revert()
        info_stub:revert()
        executable_stub:revert()

        package.loaded["tend.health"] = nil
        package.loaded["tend.acp.acp_health"] = original_acp_health
        package.loaded["tend.config"] = original_config
        package.loaded["tend.ui.clipboard_image"] = original_clipboard_image
        package.loaded["tend.commands"] = original_commands
    end)

    --- @param info table the connection info snapshot to report
    local function with_connection(info)
        package.loaded["tend.commands"] = {
            current = function()
                return {
                    conn = {
                        info = function()
                            return info
                        end,
                    },
                }
            end,
        }
    end

    it("reports the daemon section as info when not set up", function()
        Health.check()
        assert.spy(start_stub).was.called_with("Daemon (tendd)")
        local found = false
        for _, call in ipairs(info_stub.calls) do
            if tostring(call[1]):find("setup", 1, true) then
                found = true
            end
        end
        assert.is_true(found)
    end)

    it("reports all three pinned minimums for version debugging", function()
        Health.check()
        local found = false
        for _, call in ipairs(info_stub.calls) do
            local msg = tostring(call[1])
            if
                msg:find("pinned minimums", 1, true)
                and msg:find("plugin_to_daemon", 1, true)
                and msg:find("daemon_to_editor", 1, true)
                and msg:find("daemon_to_client", 1, true)
            then
                found = true
            end
        end
        assert.is_true(found)
    end)

    it("reports a connected daemon with all three version sets", function()
        with_connection({
            status = "connected",
            client_id = "nvim-1",
            versions = {
                plugin_to_daemon = "0.5.0",
                daemon_to_editor = "0.2.1",
                daemon_to_client = "0.1.0",
            },
            daemon_epoch = "epoch-1",
        })
        Health.check()
        local found = false
        for _, call in ipairs(ok_stub.calls) do
            local msg = tostring(call[1])
            -- The unpinned daemon_to_editor set is still part of the daemon's
            -- reported snapshot and must show alongside the pinned sets.
            if
                msg:find("plugin_to_daemon 0.5.0", 1, true)
                and msg:find("daemon_to_editor 0.2.1", 1, true)
                and msg:find("daemon_to_client 0.1.0", 1, true)
                and msg:find("epoch-1", 1, true)
            then
                found = true
            end
        end
        assert.is_true(found)
    end)

    it("reports a version mismatch as a health error", function()
        with_connection({
            status = "disconnected",
            client_id = "nvim-1",
            version_mismatch = "plugin_to_daemon 0.1.0 does not satisfy 0.2.0",
        })
        Health.check()
        local found = false
        for _, call in ipairs(error_stub.calls) do
            if tostring(call[1]):find("0.2.0", 1, true) then
                found = true
            end
        end
        assert.is_true(found)
    end)

    it("reports a disconnected daemon as info, not an error", function()
        with_connection({ status = "disconnected", client_id = "nvim-1" })
        Health.check()
        local found = false
        for _, call in ipairs(info_stub.calls) do
            if tostring(call[1]):find("TendAttach", 1, true) then
                found = true
            end
        end
        assert.is_true(found)
        for _, call in ipairs(error_stub.calls) do
            assert.is_nil(tostring(call[1]):find("daemon", 1, true))
        end
    end)

    it("warns when WSL PowerShell interop is missing", function()
        executable_stub:invokes(function(name)
            return name == "wslpath" and 1 or 0
        end)

        Health.check()

        assert
            .spy(warn_stub).was
            .called_with(
                "Clipboard image paste: PowerShell interop (powershell.exe) not found"
            )
    end)

    it("warns when WSL wslpath is missing", function()
        executable_stub:invokes(function(name)
            return name == "powershell.exe" and 1 or 0
        end)

        Health.check()

        assert
            .spy(warn_stub).was
            .called_with("Clipboard image paste: wslpath not found")
    end)

    it("warns when both WSL requirements are missing", function()
        executable_stub:returns(0)

        Health.check()

        assert.spy(warn_stub).was.called_with(
            "Clipboard image paste: PowerShell interop (powershell.exe) and wslpath not found"
        )
    end)
end)
