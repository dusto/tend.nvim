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

--- Add the current visual selection to the next turn's context.
function Tend.add_selection()
    with_context(function(ctx)
        ctx:add_selection()
    end)
end

--- Add the current file to the next turn's context.
function Tend.add_file()
    with_context(function(ctx)
        ctx:add_file()
    end)
end

--- Add a list of file paths or buffer numbers to the next turn's context.
--- @param opts { files: (string|integer)[] }
function Tend.add_files_to_context(opts)
    with_context(function(ctx)
        if opts and type(opts.files) == "table" then
            ctx:add_files(opts.files)
        else
            Logger.notify(
                "tend: add_files_to_context expects { files = { ... } }, got "
                    .. vim.inspect(opts),
                vim.log.levels.WARN
            )
        end
    end)
end

--- Add the visual selection when in visual mode, else the current file.
function Tend.add_selection_or_file_to_context()
    with_context(function(ctx)
        ctx:add_selection_or_file()
    end)
end

--- Add diagnostics at the current cursor line to the next turn's context.
function Tend.add_current_line_diagnostics()
    with_context(function(ctx)
        if ctx:add_current_line_diagnostics() == 0 then
            Logger.notify(
                "No diagnostics found on the current line",
                vim.log.levels.INFO
            )
        end
    end)
end

--- Add all diagnostics from the current buffer to the next turn's context.
function Tend.add_buffer_diagnostics()
    with_context(function(ctx)
        if ctx:add_buffer_diagnostics() == 0 then
            Logger.notify(
                "No diagnostics found in the current buffer",
                vim.log.levels.INFO
            )
        end
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

    -- Image paste: a clipboard image dropped/pasted in the widget is written to a
    -- file and attached to the next turn's context (as an image content block).
    if Config.image_paste.enabled then
        local Clipboard = require("tend.ui.clipboard")
        Clipboard.setup({
            is_cursor_in_widget = function()
                local ctx = Commands.current()
                return (ctx and ctx.widget and ctx.widget:is_cursor_in_widget())
                    or false
            end,
            on_paste = function(file_path)
                local ctx = Commands.current()
                if not ctx then
                    return false
                end
                ctx:add_files({ file_path })
                return true
            end,
        })
    end
end

return Tend
