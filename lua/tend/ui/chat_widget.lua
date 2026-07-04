local Config = require("tend.config")
local BufHelpers = require("tend.utils.buf_helpers")
local BufferGuard = require("tend.ui.buffer_guard")
local ChatNavigation = require("tend.ui.chat_navigation")
local DiffPreview = require("tend.ui.diff_preview")
local FilePicker = require("tend.ui.file_picker")
local Logger = require("tend.utils.logger")
local SlashComplete = require("tend.ui.slash_complete")
local WindowDecoration = require("tend.ui.window_decoration")
local WidgetLayout = require("tend.ui.widget_layout")

--- @alias tend.ui.ChatWidget.PanelNames "chat"|"todos"|"code"|"files"|"input"|"diagnostics"

--- Runtime header parts with dynamic context
--- @class tend.ui.ChatWidget.HeaderParts
--- @field title string Main header text
--- @field context? string Dynamic info (managed internally)
--- @field suffix? string Context help text

--- @alias tend.ui.ChatWidget.BufNrs table<tend.ui.ChatWidget.PanelNames, integer>
--- @alias tend.ui.ChatWidget.WinNrs table<tend.ui.ChatWidget.PanelNames, integer|nil>

--- @alias tend.ui.ChatWidget.Headers table<tend.ui.ChatWidget.PanelNames, tend.ui.ChatWidget.HeaderParts>

--- Options for controlling widget display behavior
--- @class tend.ui.ChatWidget.AddToContextOpts
--- @field focus_prompt? boolean

--- Options for adding file paths or buffers to the current Chat context
--- @class tend.ui.ChatWidget.AddFilesToContextOpts : tend.ui.ChatWidget.AddToContextOpts
--- @field files (string|integer)[]

--- Options for showing the widget
--- @class tend.ui.ChatWidget.ShowOpts : tend.ui.ChatWidget.AddToContextOpts
--- @field auto_add_to_context? boolean Automatically add current selection or file to context when opening

--- A sidebar-style chat widget with multiple windows stacked vertically
--- The main chat window is the first, and contains the width, the below ones adapt to its size
--- @class tend.ui.ChatWidget
--- @field tab_page_id integer
--- @field buf_nrs tend.ui.ChatWidget.BufNrs
--- @field win_nrs tend.ui.ChatWidget.WinNrs
--- @field current_position tend.UserConfig.Windows.Position
--- @field on_submit_input fun(prompt: string): boolean external callback to be called when user submits the input
--- @field on_switch_session? fun() external callback opening the session switcher; nil disables the switch keymap
--- @field controls tend.ui.ChatWidget.Controls daemon-sourced switcher callbacks; absent ones leave their keymap unbound (or, for the provider, fall back to the legacy path)
--- @field slash? tend.ui.SlashSource daemon-sourced slash completion source; nil leaves the prompt without command completion (legacy path)
--- @field files? tend.ui.FileSource @-file completion source; nil leaves the prompt without @-file completion
--- @field file_picker? tend.ui.FilePicker strong ref to the input's @-file picker (kept so it is not weakly collected)
--- @field _guard_augroup? integer BufferGuard autocmd group ID
--- @field _winclosed_augroup? integer WinClosed autocmd group ID
--- @field _closing? boolean True during programmatic window closes
--- @field _avoid_auto_close_cmd fun(self: tend.ui.ChatWidget, fn: fun())
--- @field _hidden_chat_winid? integer
--- @field _chat_buffers integer[] every chat buffer created (deleted on destroy)
local ChatWidget = {}
ChatWidget.__index = ChatWidget

--- Switcher callbacks the daemon path injects so the widget keymaps act on the
--- daemon session without the widget depending on the daemon runtime. Each is
--- optional: an absent model/thought callback leaves its keymap unbound (the
--- provider/daemon offers no choice), and an absent provider callback falls back
--- to the legacy in-nvim path until it is removed (tend-9ee.9).
--- @class tend.ui.ChatWidget.Controls
--- @field switch_provider? fun()
--- @field switch_model? fun()
--- @field change_mode? fun()
--- @field change_thought_level? fun()

--- Source the @-file completion needs, injected so the widget stays decoupled
--- from the daemon connection: on_pick attaches the picked path to the next
--- turn's context. Optional — an absent source leaves @-completion unwired.
--- @class tend.ui.FileSource
--- @field on_pick fun(path: string)

--- @param tab_page_id integer
--- @param on_submit_input fun(prompt: string): boolean
--- @param on_switch_session fun()|nil
--- @param controls tend.ui.ChatWidget.Controls|nil
--- @param slash tend.ui.SlashSource|nil
--- @param files tend.ui.FileSource|nil
function ChatWidget:new(
    tab_page_id,
    on_submit_input,
    on_switch_session,
    controls,
    slash,
    files
)
    self = setmetatable({}, self)

    self.win_nrs = {}
    self.current_position = Config.windows.position

    self.on_submit_input = on_submit_input
    self.on_switch_session = on_switch_session
    self.controls = controls or {}
    self.slash = slash
    self.files = files
    self.tab_page_id = tab_page_id

    self:_initialize()
    self:_bind_events_to_change_headers()

    return self
end

function ChatWidget:is_open()
    local win_id = self.win_nrs.chat
    return (win_id and vim.api.nvim_win_is_valid(win_id)) or false
end

--- Check if the cursor is currently in one of the widget's buffers
--- @return boolean
function ChatWidget:is_cursor_in_widget()
    if not self:is_open() then
        return false
    end

    return self:_is_widget_buffer(vim.api.nvim_get_current_buf())
end

function ChatWidget:_close_hidden_chat_window()
    local winid = self._hidden_chat_winid
    self._hidden_chat_winid = nil
    if not winid or not vim.api.nvim_win_is_valid(winid) then
        return
    end
    -- 0.11.5 Linux post-tabclose segfault, see WidgetLayout.close.
    local tab_ok, win_tab = pcall(vim.api.nvim_win_get_tabpage, winid)
    if tab_ok and vim.api.nvim_tabpage_is_valid(win_tab) then
        pcall(vim.api.nvim_win_close, winid, true)
    end
end

--- @param opts tend.ui.ChatWidget.ShowOpts|tend.ui.ChatWidget.AddToContextOpts|nil
function ChatWidget:show(opts)
    opts = opts or {}

    self:_close_hidden_chat_window()

    WidgetLayout.open({
        tab_page_id = self.tab_page_id,
        buf_nrs = self.buf_nrs,
        win_nrs = self.win_nrs,
        focus_prompt = opts.focus_prompt,
        position = self.current_position,
    })
end

--- @param layouts tend.UserConfig.Windows.Position[]|nil
function ChatWidget:rotate_layout(layouts)
    if not layouts or #layouts == 0 then
        layouts = { "right", "bottom", "left" }
    end

    if #layouts == 1 then
        Logger.notify(
            "Only one layout defined for rotation, it'll always show the same: "
                .. layouts[1],
            vim.log.levels.WARN,
            { title = "Tend: rotate layout" }
        )
    end

    local current = self.current_position
    local next_layout = layouts[1]

    for i, layout in ipairs(layouts) do
        if layout == current then
            local next_index = i % #layouts + 1
            if layouts[next_index] then
                next_layout = layouts[next_index]
            end
            break
        end
    end

    self.current_position = next_layout

    local previous_mode = vim.fn.mode()
    local previous_buf = vim.api.nvim_get_current_buf()

    self:hide()
    self:show({
        focus_prompt = false,
    })

    vim.schedule(function()
        local win = vim.fn.bufwinid(previous_buf)
        if win ~= -1 then
            vim.api.nvim_set_current_win(win)
        end
        if previous_mode == "i" then
            vim.cmd("startinsert")
        end
    end)
end

--- Closes all windows but keeps buffers in memory
function ChatWidget:hide()
    vim.cmd("stopinsert")

    -- Check if we're on the correct tabpage before trying to find/create fallback window
    local current_tabpage = vim.api.nvim_get_current_tabpage()
    local should_create_fallback = current_tabpage == self.tab_page_id

    if should_create_fallback then
        local fallback_winid = self:find_first_non_widget_window()

        if not fallback_winid then
            -- Fallback: create a new left window to avoid closing the last window error
            local created_winid = self:open_editor_window()
            if not created_winid then
                Logger.notify(
                    "Failed to create fallback window; cannot hide widget safely, run `:tabclose` to close the tab instead.",
                    vim.log.levels.ERROR
                )
                return
            end
        end
    end

    self:_avoid_auto_close_cmd(function()
        WidgetLayout.close(self.win_nrs)
    end)

    -- Close prior float before reopen to avoid leaking the winid.
    self:_close_hidden_chat_window()
    self._hidden_chat_winid =
        WidgetLayout.open_hidden_chat_window(self.buf_nrs.chat)
end

--- Cleans up all buffers content without destroying them
function ChatWidget:clear()
    for name, bufnr in pairs(self.buf_nrs) do
        BufHelpers.with_modifiable(bufnr, function()
            local ok =
                pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, { "" })
            if not ok then
                Logger.debug(
                    string.format(
                        "Failed to clear buffer '%s' with id: %d",
                        name,
                        bufnr
                    )
                )
            end
        end)
    end
end

--- Deletes all buffers and removes them from memory
--- This instance is no longer usable after calling this method
function ChatWidget:destroy()
    if self._guard_augroup then
        BufferGuard.detach(self._guard_augroup)
        self._guard_augroup = nil
    end

    if self._winclosed_augroup then
        pcall(vim.api.nvim_del_augroup_by_id, self._winclosed_augroup)
        self._winclosed_augroup = nil
    end

    -- During TabClosed, the tabpage is removed from nvim_list_tabpages()
    -- but nvim_tabpage_is_valid() still returns true. Neovim tears down
    -- the windows itself; calling nvim_win_close on those handles crashes
    -- Neovim 0.11.x. Detect this by checking the tabpages list.
    local tab_closing =
        not vim.tbl_contains(vim.api.nvim_list_tabpages(), self.tab_page_id)

    if not tab_closing then
        self:hide()
    end

    self:_close_hidden_chat_window()

    for name, bufnr in pairs(self.buf_nrs) do
        self.buf_nrs[name] = nil
        local ok = pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        if not ok then
            Logger.debug(
                string.format(
                    "Failed to delete buffer '%s' with id: %d",
                    name,
                    bufnr
                )
            )
        end
    end

    -- Delete every chat buffer the widget created (the original plus each
    -- per-session buffer). The active one was just deleted via buf_nrs.chat;
    -- pcall absorbs that overlap.
    for _, bufnr in ipairs(self._chat_buffers) do
        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
    self._chat_buffers = {}
end

function ChatWidget:_submit_input()
    vim.cmd("stopinsert")

    local lines = vim.api.nvim_buf_get_lines(self.buf_nrs.input, 0, -1, false)

    local prompt = table.concat(lines, "\n"):match("^%s*(.-)%s*$")

    -- Check if prompt is empty or contains only whitespace
    if not prompt or prompt == "" or not prompt:match("%S") then
        return
    end

    -- Ask session if it can accept this prompt
    local accepted = self.on_submit_input(prompt)
    if not accepted then
        return
    end

    -- Clear buffers only after successful submission
    vim.api.nvim_buf_set_lines(self.buf_nrs.input, 0, -1, false, {})

    BufHelpers.with_modifiable(self.buf_nrs.code, function(bufnr)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
    end)

    BufHelpers.with_modifiable(self.buf_nrs.files, function(bufnr)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
    end)

    BufHelpers.with_modifiable(self.buf_nrs.diagnostics, function(bufnr)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
    end)

    self:close_optional_window("code")
    self:close_optional_window("files")
    self:close_optional_window("diagnostics")
    -- Move cursor to chat buffer after submit for easy access to permission requests
    self:move_cursor_to(self.win_nrs.chat)
end

--- @param winid integer|nil
--- @param callback fun()|nil
function ChatWidget:move_cursor_to(winid, callback)
    vim.schedule(function()
        if winid and vim.api.nvim_win_is_valid(winid) then
            if Config.settings.move_cursor_to_chat_on_submit then
                vim.api.nvim_set_current_win(winid)
            end

            -- make sure to scroll to the bottom
            -- 1. user can see the new message
            -- 2. auto-scroll will start again
            vim.api.nvim_win_call(winid, function()
                vim.cmd("normal! G0zb")
            end)

            if callback then
                callback()
            end
        end
    end)
end

function ChatWidget:_initialize()
    self.buf_nrs = self:_create_buf_nrs()
    -- Wire daemon-sourced slash completion onto the prompt input, when provided.
    if self.slash then
        SlashComplete.attach(self.buf_nrs.input, self.slash)
    end
    -- Wire @-file completion onto the prompt input. The picker uses omnifunc
    -- (<C-x><C-o>) while slash uses completefunc, so the two coexist. The widget
    -- owns the picker for its lifetime.
    if self.files then
        self.file_picker =
            FilePicker:new(self.buf_nrs.input, self.files.on_pick)
    end
    -- Track every chat buffer the widget owns so destroy() cleans them all. The
    -- daemon path swaps buf_nrs.chat per session (create_chat_buffer), so the
    -- original and each session buffer must be tracked here rather than relying
    -- on buf_nrs, which only holds the currently active one.
    self._chat_buffers = { self.buf_nrs.chat }

    self._hidden_chat_winid =
        WidgetLayout.open_hidden_chat_window(self.buf_nrs.chat)

    self:_bind_keymaps()

    self._guard_augroup = BufferGuard.attach({
        tab_page_id = self.tab_page_id,
        find_target_window = function()
            return self:find_first_non_widget_window()
                or self:open_editor_window()
        end,
    })

    -- Track whether we're programmatically closing windows
    -- to avoid recursive hide() calls
    self._closing = false

    self._winclosed_augroup = vim.api.nvim_create_augroup(
        "TendWinClosed_" .. tostring(self.tab_page_id),
        { clear = true }
    )

    vim.api.nvim_create_autocmd("WinClosed", {
        group = self._winclosed_augroup,
        callback = function(ev)
            if self._closing then
                return
            end
            local closed_winid = tonumber(ev.match)
            if not closed_winid then
                return
            end
            -- Any widget window closed by the user closes the whole widget,
            -- except "todos" which can be closed independently.
            for _, winid in pairs(self.win_nrs) do
                if winid == closed_winid then
                    vim.schedule(function()
                        self:hide()
                    end)
                    return
                end
            end
        end,
        desc = "Tend: close widget when user closes a core window",
    })
end

function ChatWidget:_bind_keymaps()
    BufHelpers.multi_keymap_set(
        Config.keymaps.prompt.submit,
        self.buf_nrs.input,
        function()
            self:_submit_input()
        end,
        { desc = "Tend: Submit prompt" }
    )

    BufHelpers.multi_keymap_set(
        Config.keymaps.prompt.paste_image,
        self.buf_nrs.input,
        function()
            vim.schedule(function()
                local Clipboard = require("tend.ui.clipboard")
                local res = Clipboard.paste_image()

                if res ~= nil then
                    -- call vim.paste directly to avoid coupling to the file list logic
                    vim.paste({ res }, -1)
                end
            end)
        end,
        { desc = "Tend: Paste image from clipboard" }
    )

    -- The @-file picker keymap opens the user's vim.ui.select over the workspace
    -- files (the same source as the inline @ completion), inserting the picked
    -- reference and attaching the file. Only wired on the daemon path (a files
    -- source), which owns the attach.
    if self.files then
        BufHelpers.multi_keymap_set(
            Config.keymaps.prompt.pick_file,
            self.buf_nrs.input,
            function()
                self:_pick_file_reference()
            end,
            { desc = "Tend: Attach file (picker)" }
        )
    end

    for _, bufnr in pairs(self.buf_nrs) do
        BufHelpers.multi_keymap_set(
            Config.keymaps.widget.close,
            bufnr,
            function()
                self:hide()
            end,
            { desc = "Tend: Close Chat widget" }
        )

        self:_bind_controls(bufnr)
        self:_bind_switch_session(bufnr)
    end

    -- Add keybindings to chat, todos, code, and files buffers to jump back to input and start insert mode
    for panel_name, bufnr in pairs(self.buf_nrs) do
        if panel_name ~= "input" then
            for _, key in ipairs({
                "a",
                "A",
                "o",
                "O",
                "i",
                "I",
                "c",
                "C",
                "x",
                "X",
            }) do
                BufHelpers.keymap_set(bufnr, "n", key, function()
                    self:move_cursor_to(
                        self.win_nrs.input,
                        BufHelpers.start_insert_on_last_char
                    )
                end)
            end
        end
    end

    DiffPreview.setup_diff_navigation_keymaps(self.buf_nrs)
    self:bind_chat_keymaps(self.buf_nrs.chat)
end

--- Open the workspace file picker (through vim.ui.select, so the user's own
--- picker is reused) and, on a choice, insert the "@path" reference at the
--- prompt cursor and attach the file to the next turn via the files source. A
--- no-op when no picker/source is wired or the scan finds nothing.
function ChatWidget:_pick_file_reference()
    local picker = self.file_picker
    local win = self.win_nrs.input
    if
        not picker
        or not self.files
        or not win
        or not vim.api.nvim_win_is_valid(win)
    then
        return
    end
    local bufnr = self.buf_nrs.input
    local cursor = vim.api.nvim_win_get_cursor(win)
    local items = picker:scan_files()
    if #items == 0 then
        Logger.notify("tend: no workspace files found")
        return
    end
    vim.ui.select(items, {
        prompt = "Attach file",
        format_item = function(item)
            return item.word
        end,
    }, function(choice)
        if not choice then
            return
        end
        -- choice.word is the "@path" reference; the file itself attaches, and the
        -- reference text stays in the prompt so providers that read @mentions see
        -- it too.
        local path = choice.word:gsub("^@", "")
        self:_insert_prompt_text(bufnr, win, cursor, choice.word .. " ")
        self.files.on_pick(path)
    end)
end

--- Insert text into the prompt input at the given (1-based row, 0-based col),
--- leaving the cursor after it and returning to insert mode when the input
--- window is focused. The modal picker blocks edits, so the captured position
--- stays valid across the selection.
--- @param bufnr integer the input buffer
--- @param win integer the input window
--- @param cursor integer[] { row, col } captured before the picker opened
--- @param text string
function ChatWidget:_insert_prompt_text(bufnr, win, cursor, text)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end
    local row, col = cursor[1], cursor[2]
    vim.api.nvim_buf_set_text(bufnr, row - 1, col, row - 1, col, { text })
    if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_set_cursor(win, { row, col + #text })
        if vim.api.nvim_get_current_win() == win then
            vim.cmd("startinsert")
        end
    end
end

--- Bind the provider/model/thought switcher keymaps on a buffer. Each switcher
--- targets the active daemon session via an injected control callback and is
--- bound only when its callback is given, so keys stay unbound (not dead) where
--- the provider offers no such choice.
--- @param bufnr integer
function ChatWidget:_bind_controls(bufnr)
    local controls = self.controls
    if controls.switch_provider then
        BufHelpers.multi_keymap_set(
            Config.keymaps.widget.switch_provider,
            bufnr,
            function()
                controls.switch_provider()
            end,
            { desc = "Tend: Switch provider" }
        )
    end
    if controls.switch_model then
        BufHelpers.multi_keymap_set(
            Config.keymaps.widget.switch_model,
            bufnr,
            function()
                controls.switch_model()
            end,
            { desc = "Tend: Switch model" }
        )
    end
    if controls.change_mode then
        BufHelpers.multi_keymap_set(
            Config.keymaps.widget.change_mode,
            bufnr,
            function()
                controls.change_mode()
            end,
            { desc = "Tend: Change mode" }
        )
    end
    if controls.change_thought_level then
        BufHelpers.multi_keymap_set(
            Config.keymaps.widget.change_thought_level,
            bufnr,
            function()
                controls.change_thought_level()
            end,
            { desc = "Tend: Change thought level" }
        )
    end
end

--- Bind the session-switch keymap on a buffer, opening the in-chat switcher
--- without leaving the widget. A no-op when no on_switch_session callback was
--- given (e.g. a standalone widget with no daemon session context), so the key
--- is only live where switching is meaningful.
--- @param bufnr integer
function ChatWidget:_bind_switch_session(bufnr)
    if not self.on_switch_session then
        return
    end
    BufHelpers.multi_keymap_set(
        Config.keymaps.widget.switch_session,
        bufnr,
        function()
            self.on_switch_session()
        end,
        { desc = "Tend: Switch session" }
    )
end

--- Bind the chat-buffer keymaps (close, jump-to-input, transcript navigation)
--- to an arbitrary chat buffer. The daemon path renders one chat buffer per
--- session and swaps which one the chat window shows, so each session buffer
--- needs the same keymaps as the widget's own chat buffer.
--- @param bufnr integer
function ChatWidget:bind_chat_keymaps(bufnr)
    BufHelpers.multi_keymap_set(Config.keymaps.widget.close, bufnr, function()
        self:hide()
    end, { desc = "Tend: Close Chat widget" })
    self:_bind_controls(bufnr)
    self:_bind_switch_session(bufnr)
    for _, key in ipairs({ "a", "A", "o", "O", "i", "I", "c", "C", "x", "X" }) do
        BufHelpers.keymap_set(bufnr, "n", key, function()
            self:move_cursor_to(
                self.win_nrs.input,
                BufHelpers.start_insert_on_last_char
            )
        end)
    end
    ChatNavigation.setup_keymaps(bufnr)
end

--- Create a chat buffer set up like the widget's own (TendChat filetype, chat
--- keymaps), for a caller that renders one transcript per session and points
--- the chat window at the active session's buffer via buf_nrs.chat.
--- @return integer bufnr
function ChatWidget:create_chat_buffer()
    local bufnr = self:_create_new_buf({ filetype = "TendChat" })
    self:bind_chat_keymaps(bufnr)
    table.insert(self._chat_buffers, bufnr)
    return bufnr
end

--- @return tend.ui.ChatWidget.BufNrs
function ChatWidget:_create_buf_nrs()
    local chat = self:_create_new_buf({
        filetype = "TendChat",
    })

    local todos = self:_create_new_buf({
        filetype = "TendTodos",
    })

    local code = self:_create_new_buf({
        filetype = "TendCode",
    })

    local files = self:_create_new_buf({
        filetype = "TendFiles",
    })

    local diagnostics = self:_create_new_buf({
        filetype = "TendDiagnostics",
    })

    local input = self:_create_new_buf({
        filetype = "TendInput",
        modifiable = true,
    })

    -- Don't call it for the chat buffer as its managed somewhere else
    pcall(vim.treesitter.start, todos, "markdown")
    pcall(vim.treesitter.start, code, "markdown")
    pcall(vim.treesitter.start, files, "markdown")
    pcall(vim.treesitter.start, diagnostics, "markdown")
    pcall(vim.treesitter.start, input, "markdown")

    --- @type tend.ui.ChatWidget.BufNrs
    local buf_nrs = {
        chat = chat,
        todos = todos,
        code = code,
        files = files,
        diagnostics = diagnostics,
        input = input,
    }

    return buf_nrs
end

--- @param opts table<string, any>
--- @return integer bufnr
function ChatWidget:_create_new_buf(opts)
    local bufnr = vim.api.nvim_create_buf(false, true)

    local config = vim.tbl_deep_extend("force", {
        swapfile = false,
        buftype = "nofile",
        bufhidden = "hide",
        buflisted = false,
        modifiable = false,
    }, opts)

    for key, value in pairs(config) do
        vim.bo[bufnr][key] = value
    end

    return bufnr
end

--- @param keymaps  tend.UserConfig.KeymapValue
--- @param mode string
local function find_keymap(keymaps, mode)
    if type(keymaps) == "string" then
        return keymaps
    end

    for _, keymap in ipairs(keymaps) do
        if type(keymap) == "string" and mode == "n" then
            return keymap
        elseif type(keymap) == "table" then
            if keymap.mode == mode then
                return keymap[1]
            end

            if type(keymap.mode) == "table" then
                ---@diagnostic disable-next-line: param-type-mismatch
                for _, m in ipairs(keymap.mode) do
                    if m == mode then
                        return keymap[1]
                    end
                end
            end
        end
    end
end

--- Binds events to change the suffix header texts based on current mode keymaps
--- For the Chat and Input buffers only
function ChatWidget:_bind_events_to_change_headers()
    local tab_page_id = self.tab_page_id

    for _, bufnr in ipairs({ self.buf_nrs.chat, self.buf_nrs.input }) do
        vim.api.nvim_create_autocmd("ModeChanged", {
            buffer = bufnr,
            callback = function()
                vim.schedule(function()
                    -- Check if tabpage is still valid before accessing vim.t
                    -- I couldn't test it, it seems to only happen from command -> normal, not from insert -> normal
                    if not vim.api.nvim_tabpage_is_valid(tab_page_id) then
                        return
                    end

                    -- Get headers from tabpage-local storage (must reassign after modification)
                    local headers =
                        WindowDecoration.get_headers_state(tab_page_id)

                    local mode = vim.fn.mode()
                    local change_mode_key =
                        find_keymap(Config.keymaps.widget.change_mode, mode)

                    if change_mode_key ~= nil then
                        headers.chat.suffix =
                            string.format("%s: change mode", change_mode_key)
                    else
                        headers.chat.suffix = nil
                    end

                    local submit_key =
                        find_keymap(Config.keymaps.prompt.submit, mode)

                    if submit_key ~= nil then
                        headers.input.suffix =
                            string.format("%s: submit", submit_key)
                    else
                        headers.input.suffix = nil
                    end

                    -- Reassign to persist changes
                    WindowDecoration.set_headers_state(tab_page_id, headers)

                    self:render_header("chat")
                    self:render_header("input")
                end)
            end,
        })
    end
end

--- @param window_name tend.ui.ChatWidget.PanelNames
--- @param context string|nil
function ChatWidget:render_header(window_name, context)
    local bufnr = self.buf_nrs[window_name]
    if not bufnr then
        return
    end

    WindowDecoration.render_header(bufnr, window_name, context)
end

--- @param panel_name tend.ui.ChatWidget.PanelNames
function ChatWidget:close_optional_window(panel_name)
    self:_avoid_auto_close_cmd(function()
        WidgetLayout.close_optional_window(
            self.win_nrs,
            panel_name,
            self.current_position
        )
    end)
end

--- Wraps a window-closing operation with the _closing flag so the
--- WinClosed autocmd ignores programmatic closes.
--- @param fn fun()
function ChatWidget:_avoid_auto_close_cmd(fn)
    self._closing = true
    local ok, err = pcall(fn)
    self._closing = false
    if not ok then
        Logger.notify(tostring(err), vim.log.levels.ERROR)
    end
end

--- Filetypes that should be excluded when finding fallback windows
local EXCLUDED_FILETYPES = {
    -- File explorers
    ["neo-tree"] = true,
    ["NvimTree"] = true,
    ["oil"] = true,
    -- Neovim special buffers
    ["qf"] = true, -- Quickfix
    ["help"] = true, -- Help buffers
    ["man"] = true, -- Man pages
    ["terminal"] = true, -- Terminal buffers
    -- Plugin special windows
    ["TelescopePrompt"] = true,
    ["DiffviewFiles"] = true,
    ["DiffviewFileHistory"] = true,
    ["fugitive"] = true,
    ["fugitiveblame"] = true,
    ["gitcommit"] = true,
    ["dashboard"] = true,
    ["alpha"] = true, -- Alpha dashboard
    ["starter"] = true, -- Mini.starter
    ["notify"] = true, -- nvim-notify
    ["noice"] = true, -- Noice popup
    ["aerial"] = true, -- Aerial outline
    ["Outline"] = true, -- symbols-outline
    ["trouble"] = true, -- Trouble diagnostics
    ["spectre_panel"] = true, -- nvim-spectre
    ["lazy"] = true, -- Lazy plugin manager
    ["mason"] = true, -- Mason installer
}

--- Finds the first window on the current tabpage that is NOT part of the chat widget
--- @return number|nil winid The first non-widget window ID, or nil if none found
function ChatWidget:find_first_non_widget_window()
    local all_windows = vim.api.nvim_tabpage_list_wins(self.tab_page_id)

    -- Build a set of widget window IDs for fast lookup
    local widget_win_ids = {}
    for _, winid in pairs(self.win_nrs) do
        if winid then
            widget_win_ids[winid] = true
        end
    end

    for _, winid in ipairs(all_windows) do
        if not widget_win_ids[winid] then
            -- Skip floating windows (pickers, popups, etc.)
            local win_config = vim.api.nvim_win_get_config(winid)
            if win_config.relative == "" then
                local bufnr = vim.api.nvim_win_get_buf(winid)
                local ft = vim.bo[bufnr].filetype
                if not EXCLUDED_FILETYPES[ft] then
                    return winid
                end
            end
        end
    end

    return nil
end

--- Checks if a buffer belongs to this widget
--- @param bufnr number
--- @return boolean
function ChatWidget:_is_widget_buffer(bufnr)
    for _, widget_bufnr in pairs(self.buf_nrs) do
        if widget_bufnr == bufnr then
            return true
        end
    end
    return false
end

--- Opens a new editor window on the opposite side of the widget.
--- Position-aware: respects the current layout position.
--- @param bufnr number|nil The buffer to display in the new window
--- @return number|nil winid The newly created window ID or nil
function ChatWidget:open_editor_window(bufnr)
    if bufnr == nil then
        -- Try first oldfile under current directory
        local oldfiles = vim.v.oldfiles
        local cwd = vim.fn.getcwd()
        if oldfiles and #oldfiles > 0 then
            for _, filepath in ipairs(oldfiles) do
                if
                    vim.startswith(filepath, cwd)
                    and vim.fn.filereadable(filepath) == 1
                then
                    local file_bufnr = vim.fn.bufnr(filepath)
                    if file_bufnr == -1 then
                        file_bufnr = vim.fn.bufadd(filepath)
                    end
                    bufnr = file_bufnr
                    break
                end
            end
        end
    end

    -- Fallback: create new scratch buffer — safer than using
    -- alternate buffer (#) which could be a widget buffer
    if bufnr == nil then
        bufnr = vim.api.nvim_create_buf(false, true)
    end

    -- Position-aware split using topleft/botright vim commands.
    -- These always create full-width/full-height splits
    -- regardless of which window is current.
    local split_cmd
    if self.current_position == "left" then
        split_cmd = "botright vsplit"
    elseif self.current_position == "bottom" then
        split_cmd = "topleft split"
    else
        -- "right" or any unknown → full-height left
        split_cmd = "topleft vsplit"
    end

    -- Use nvim_win_call to run the split in the widget's tabpage context
    -- without disturbing the user's focus when they're on another tab.
    local anchor_win = self.win_nrs.chat or self.win_nrs.input
    if not anchor_win or not vim.api.nvim_win_is_valid(anchor_win) then
        return nil
    end

    --- @type integer|nil
    local winid
    local ok = pcall(function()
        winid = vim.api.nvim_win_call(anchor_win, function()
            vim.cmd(split_cmd)
            local new_win = vim.api.nvim_get_current_win()
            pcall(vim.api.nvim_win_set_buf, new_win, bufnr)
            return new_win
        end)
    end)
    if not ok or not winid then
        Logger.notify("Failed to create editor window", vim.log.levels.WARN)
        return nil
    end

    return winid
end

return ChatWidget
