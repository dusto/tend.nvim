local Config = require("tend.config")
local Commands = require("tend.commands")
local Theme = require("tend.theme")
local Object = require("tend.utils.object")
local Logger = require("tend.utils.logger")

--- @class tend.Tend
local Tend = {}

--- Run fn with the daemon command context, or report when setup has not run.
--- The daemon owns sessions; the require("tend").* widget API delegates to the
--- one connection-scoped context (see |tend-daemon|).
--- @param fn fun(ctx: tend.commands.Context)
local function with_context(fn)
    local ctx = Commands.current()
    if not ctx then
        Logger.notify(
            "tend: not set up; call require('tend').setup() first",
            vim.log.levels.WARN
        )
        return
    end
    fn(ctx)
end

--- Opens the chat widget on the focused session. Reports when no session is
--- focused (start one with :TendSessionNew). Safe to call multiple times.
--- @param opts tend.ui.ChatWidget.ShowOpts|nil
function Tend.open(opts)
    with_context(function(ctx)
        ctx:open_widget(opts)
    end)
end

--- Closes the chat widget. Safe to call multiple times.
function Tend.close()
    with_context(function(ctx)
        ctx:close_widget()
    end)
end

--- Toggles the chat widget on the focused session. Safe to call multiple times.
--- @param opts tend.ui.ChatWidget.ShowOpts|nil
function Tend.toggle(opts)
    with_context(function(ctx)
        ctx:toggle_widget(opts)
    end)
end

--- Rotates through predefined window layouts for the chat widget.
--- @param layouts tend.UserConfig.Windows.Position[]|nil
function Tend.rotate_layout(layouts)
    with_context(function(ctx)
        ctx:rotate_layout(layouts)
    end)
end

--- Used to make sure we don't set multiple signal handlers or autocmds, if the user calls setup multiple times
local traps_set = false
local cleanup_group = vim.api.nvim_create_augroup("TendCleanup", {
    clear = true,
})

--- Merges the current user configuration with the default configuration
--- This method should be safe to be called multiple times
--- @param opts tend.PartialUserConfig
function Tend.setup(opts)
    -- make sure invalid user config doesn't crash setup and leave things half-initialized
    local ok, err = pcall(function()
        Object.merge_config(Config, opts or {})
    end)

    if not ok then
        Logger.notify(
            "[Tend] Error in user configuration: " .. tostring(err),
            vim.log.levels.ERROR,
            { title = "Tend: user config merge error" }
        )
    end

    -- Daemon-client commands (:TendConnect and friends). Runs on every setup —
    -- not just the first — so daemon config changes rebuild the command
    -- context (the previous context's connection is stopped). Registering
    -- does not connect; the connection starts on :TendConnect.
    Commands.setup(Config.daemon --[[@as tend.commands.Opts]])

    if traps_set then
        return
    end

    traps_set = true

    vim.treesitter.language.register("markdown", "TendChat")

    Theme.setup()

    -- Force-reload buffers when files change on disk (e.g., agent edits files directly).
    -- Suppresses the "file changed" prompt so modified buffers reload silently,
    -- matching Cursor/Zed behavior where agent changes always win.
    vim.api.nvim_create_autocmd("FileChangedShell", {
        group = cleanup_group,
        pattern = "*",
        callback = function()
            vim.v.fcs_choice = "reload"
        end,
    })
end

return Tend
