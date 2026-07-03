--- Health check for tend.nvim
--- This file is auto-discovered by :checkhealth
--- Users can run :checkhealth tend to see only tend.nvim health
--- @class tend.Health
local M = {}
local vim_health = vim.health

function M.check()
    vim_health.start("tend.nvim")
    -- Check Neovim version
    local nvim_version = vim.version()
    local required_version = { 0, 11, 0 }
    if
        nvim_version.major > required_version[1]
        or (
            nvim_version.major == required_version[1]
            and nvim_version.minor >= required_version[2]
        )
    then
        vim_health.ok(
            string.format(
                "Neovim version %d.%d.%d",
                nvim_version.major,
                nvim_version.minor,
                nvim_version.patch
            )
        )
    else
        vim_health.error(
            string.format(
                "Neovim >= %d.%d.%d required (current: %d.%d.%d)",
                required_version[1],
                required_version[2],
                required_version[3],
                nvim_version.major,
                nvim_version.minor,
                nvim_version.patch
            )
        )
    end

    -- Daemon connection and API version pin
    vim_health.start("Daemon (tendd)")
    local DaemonVersions = require("tend.daemon.versions")
    local required = DaemonVersions.REQUIRED
    vim_health.info(
        string.format(
            "pinned minimums: plugin_to_daemon >= %s, daemon_to_editor >= %s, daemon_to_client >= %s",
            required.plugin_to_daemon,
            required.daemon_to_editor,
            required.daemon_to_client
        )
    )
    local ctx = require("tend.commands").current()
    if not ctx then
        vim_health.info(
            "daemon commands not initialized; run require('tend').setup()"
        )
    else
        local conn_info = ctx.conn:info()
        if conn_info.version_mismatch then
            vim_health.error(
                "daemon API version mismatch: " .. conn_info.version_mismatch,
                {
                    "Upgrade tendd (or this plugin) so the contract versions are compatible.",
                }
            )
        elseif conn_info.status == "connected" then
            local versions = conn_info.versions or {}
            vim_health.ok(
                string.format(
                    "connected — daemon versions: plugin_to_daemon %s, daemon_to_editor %s, daemon_to_client %s (epoch %s)",
                    versions.plugin_to_daemon,
                    versions.daemon_to_editor,
                    versions.daemon_to_client,
                    conn_info.daemon_epoch
                )
            )
        else
            vim_health.info(
                string.format(
                    "not connected (%s); run :TendConnect — the version check runs on connect",
                    conn_info.status
                )
            )
        end
    end

    -- Provider processes (ACP CLIs, Node.js) are owned and health-checked by the
    -- daemon now, not the plugin; see the daemon's provider health reporting.

    -- Clipboard image paste tooling
    vim_health.start("Clipboard Image Paste")
    local ClipboardImage = require("tend.ui.clipboard_image")
    local platform = ClipboardImage.get_platform()
    local supported = ClipboardImage.is_supported()

    if platform == "mac" then
        vim_health.ok("Clipboard image paste: supported (no extra deps)")
    elseif platform == "win" then
        if supported then
            vim_health.ok("Clipboard image paste: supported (no extra deps)")
        else
            vim_health.warn(
                "Clipboard image paste: powershell.exe not found in PATH"
            )
        end
    elseif platform == "wsl" then
        if supported then
            vim_health.ok(
                "Clipboard image paste: supported through Windows interop"
            )
        else
            local has_powershell = vim.fn.executable("powershell.exe") == 1
            local has_wslpath = vim.fn.executable("wslpath") == 1
            if not has_powershell and not has_wslpath then
                vim_health.warn(
                    "Clipboard image paste: PowerShell interop (powershell.exe) and wslpath not found"
                )
            elseif not has_powershell then
                vim_health.warn(
                    "Clipboard image paste: PowerShell interop (powershell.exe) not found"
                )
            else
                vim_health.warn("Clipboard image paste: wslpath not found")
            end
        end
    elseif platform == "linux_wayland" then
        if supported then
            vim_health.ok("Clipboard image paste: wl-paste found")
        else
            vim_health.warn(
                "Clipboard image paste: wl-paste not found - install wl-clipboard"
            )
        end
    elseif platform == "linux_x11" then
        if supported then
            vim_health.ok(
                "Clipboard image paste: xclip found (clipboard access depends on session)"
            )
        else
            vim_health.warn(
                "Clipboard image paste: xclip not found - install xclip"
            )
        end
    else
        vim_health.warn("Clipboard image paste: platform not detected")
    end
end

return M
