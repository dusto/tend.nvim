--- @alias tend.UserConfig.HeaderRenderFn fun(parts: tend.ui.ChatWidget.HeaderParts): string|nil

--- User config headers - each panel can have either config parts or a custom render function
--- Customize window headers for each panel in the chat widget.
--- Each header can be either:
--- 1. A table with title and suffix fields
--- 2. A function that receives header parts and returns a custom header string
---
--- The context field is managed internally and shows dynamic info like counts.
---
--- @alias tend.UserConfig.Headers table<tend.ui.ChatWidget.PanelNames, tend.ui.ChatWidget.HeaderParts|tend.UserConfig.HeaderRenderFn|nil>

--- Daemon-client (tendd) settings for the :Tend* commands.
--- @class tend.UserConfig.Daemon
--- @field socket? string Socket path; defaults to the daemon's well-known path
--- @field providers string[] ACP provider ids offered by :TendProvider
--- @field assignee? string Task assignee for :TendClaim; defaults to $USER
--- @field persona_dirs? string[] User-scoped dirs :TendPersona scans for *.md personas
--- @field persona_sources? tend.persona.Source[] Harness agent dirs :TendPersona imports from

--- Data passed to the on_create_session_response hook
--- @class tend.UserConfig.CreateSessionResponseData
--- @field session_id? string Convenience field; equals response.sessionId when response is non-nil, nil if creation failed
--- @field tab_page_id number The tabpage ID for this session
--- @field response? tend.wire.SessionCreationResponse Raw ACP create-session response, nil on error
--- @field err? tend.wire.ACPError Error details if session creation failed

--- Data passed to the on_prompt_submit hook
--- @class tend.UserConfig.PromptSubmitData
--- @field prompt string The user's prompt text
--- @field session_id string The ACP session ID
--- @field tab_page_id number The tabpage ID

--- Data passed to the on_response_complete hook
--- @class tend.UserConfig.ResponseCompleteData
--- @field session_id string The ACP session ID
--- @field tab_page_id number The tabpage ID
--- @field success boolean Whether response completed without error
--- @field error? table Error details if failed
---
--- Data passed to the on_session_update hook
--- @class tend.UserConfig.SessionUpdateData
--- @field session_id string The ACP session ID
--- @field tab_page_id number The tabpage ID
--- @field update tend.wire.SessionUpdateMessage ACP session update details.

--- Data passed to the on_file_edit hook
--- @class tend.UserConfig.FileEditData
--- @field filepath string Absolute path to the edited file
--- @field session_id string The ACP session ID
--- @field tab_page_id number The tabpage ID
--- @field bufnr? number Buffer number if the file is loaded in a buffer

--- Data passed to the on_request_permission hook
--- @class tend.UserConfig.RequestPermissionData
--- @field request tend.wire.RequestPermission The permission request object
--- @field session_id string The ACP session ID
--- @field tab_page_id number The tabpage ID

--- @class tend.UserConfig.KeymapEntry
--- @field [1] string The key binding
--- @field mode string|string[] The mode(s) for this binding

--- @alias tend.UserConfig.KeymapValue string | string[] | (string | tend.UserConfig.KeymapEntry)[]

--- @class tend.UserConfig.Keymaps.Permission
--- @field cycle_next tend.UserConfig.KeymapValue Focus next pending permission block
--- @field cycle_prev tend.UserConfig.KeymapValue Focus previous pending permission block

--- @class tend.UserConfig.Keymaps.Chat
--- @field next_heading tend.UserConfig.KeymapValue Jump to next chat heading
--- @field prev_heading tend.UserConfig.KeymapValue Jump to previous chat heading
--- @field next_tool_call tend.UserConfig.KeymapValue Jump to next tool call
--- @field prev_tool_call tend.UserConfig.KeymapValue Jump to previous tool call

--- @class tend.UserConfig.Keymaps
--- @field widget table<string, tend.UserConfig.KeymapValue>
--- @field prompt table<string, tend.UserConfig.KeymapValue>
--- @field chat tend.UserConfig.Keymaps.Chat
--- @field diff_preview table<string, string>
--- @field permission tend.UserConfig.Keymaps.Permission

--- Window options passed to nvim_set_option_value
--- Overrides default options (wrap, linebreak, winfixheight)
--- @alias tend.UserConfig.WinOpts table<string, any>

--- @class tend.UserConfig.Windows.Chat
--- @field win_opts? tend.UserConfig.WinOpts

--- @class tend.UserConfig.Windows.Input
--- @field height number
--- @field win_opts? tend.UserConfig.WinOpts

--- @class tend.UserConfig.Windows.Code
--- @field max_height number
--- @field win_opts? tend.UserConfig.WinOpts

--- @class tend.UserConfig.Windows.Files
--- @field max_height number
--- @field win_opts? tend.UserConfig.WinOpts

--- @class tend.UserConfig.Windows.Diagnostics
--- @field max_height number
--- @field win_opts? tend.UserConfig.WinOpts

--- @class tend.UserConfig.Windows.Todos
--- @field display boolean
--- @field max_height number
--- @field win_opts? tend.UserConfig.WinOpts

--- @alias tend.UserConfig.Windows.Position "right"|"left"|"bottom"

--- @class tend.UserConfig.Windows
--- @field position tend.UserConfig.Windows.Position
--- @field width string|number
--- @field height string|number
--- @field stack_width_ratio number
--- @field chat tend.UserConfig.Windows.Chat
--- @field input tend.UserConfig.Windows.Input
--- @field code tend.UserConfig.Windows.Code
--- @field files tend.UserConfig.Windows.Files
--- @field diagnostics tend.UserConfig.Windows.Diagnostics
--- @field todos tend.UserConfig.Windows.Todos

--- @class tend.UserConfig.SpinnerChars
--- @field generating string[]
--- @field thinking string[]
--- @field searching string[]
--- @field busy string[]

--- Icons used to identify tool call states
--- @class tend.UserConfig.StatusIcons
--- @field pending string
--- @field in_progress string
--- @field completed string
--- @field failed string

--- Icons used for diagnostics in the context panel
--- @class tend.UserConfig.DiagnosticIcons
--- @field error string
--- @field warn string
--- @field info string
--- @field hint string

--- @class tend.UserConfig.PermissionIcons
--- @field allow_once string
--- @field allow_always string
--- @field reject_once string
--- @field reject_always string

--- @class tend.UserConfig.ChatIcons
--- @field user string
--- @field agent string

--- Icons used for message states in the chat widget
--- @class tend.UserConfig.MessageIcons
--- @field thinking string
--- @field finished string
--- @field stopped string
--- @field error string

--- @class tend.UserConfig.FilePicker
--- @field enabled boolean

--- @class tend.UserConfig.ImagePaste
--- @field enabled boolean Enable image drag-and-drop to add images to referenced files

--- @class tend.UserConfig.AutoScroll
--- @field threshold integer Lines from bottom to trigger auto-scroll (default: 10)

--- Show diff preview for edit tool calls in the buffer
--- @class tend.UserConfig.DiffPreview
--- @field enabled boolean
--- @field layout "inline" | "split"
--- @field center_on_navigate_hunks boolean

--- Tool call folding configuration
--- @class tend.UserConfig.Folding.ToolCalls
--- @field enabled boolean Whether to fold tool call bodies.
--- @field threshold integer Fold when the interior occupies more than this many wrapped screen rows. 0 always folds. Negative values are clamped to 0.
--- @field fold_on_error boolean Whether failed tool calls should fold when over threshold.

--- Folding behavior in the chat buffer
--- @class tend.UserConfig.Folding
--- @field tool_calls tend.UserConfig.Folding.ToolCalls

--- Tool call title display configuration
--- @class tend.UserConfig.ToolCalls.Title
--- @field max_length integer Maximum title length before truncation. 0 disables truncation.
--- @field truncate_title_kinds tend.wire.ToolKind[] Tool kinds affected by max_length.

--- Tool call display configuration
--- @class tend.UserConfig.ToolCalls
--- @field title tend.UserConfig.ToolCalls.Title

--- @class tend.UserConfig.Hooks
--- @field on_create_session_response? fun(data: tend.UserConfig.CreateSessionResponseData): nil
--- @field on_prompt_submit? fun(data: tend.UserConfig.PromptSubmitData): nil
--- @field on_response_complete? fun(data: tend.UserConfig.ResponseCompleteData): nil
--- @field on_session_update? fun(data: tend.UserConfig.SessionUpdateData): nil
--- @field on_file_edit? fun(data: tend.UserConfig.FileEditData): nil
--- @field on_request_permission? fun(data: tend.UserConfig.RequestPermissionData): nil

--- Control various behaviors and features of the plugin
--- @class tend.UserConfig.Settings
--- @field move_cursor_to_chat_on_submit boolean Automatically move cursor to chat window after submitting a prompt

--- Nested partial types for user config overrides
--- @class (partial) tend.PartialUserConfig.Windows.Chat: tend.UserConfig.Windows.Chat
--- @class (partial) tend.PartialUserConfig.Windows.Input: tend.UserConfig.Windows.Input
--- @class (partial) tend.PartialUserConfig.Windows.Code: tend.UserConfig.Windows.Code
--- @class (partial) tend.PartialUserConfig.Windows.Files: tend.UserConfig.Windows.Files
--- @class (partial) tend.PartialUserConfig.Windows.Diagnostics: tend.UserConfig.Windows.Diagnostics
--- @class (partial) tend.PartialUserConfig.Windows.Todos: tend.UserConfig.Windows.Todos
--- @class (partial) tend.PartialUserConfig.Keymaps: tend.UserConfig.Keymaps
--- @class (partial) tend.PartialUserConfig.SpinnerChars: tend.UserConfig.SpinnerChars
--- @class (partial) tend.PartialUserConfig.StatusIcons: tend.UserConfig.StatusIcons
--- @class (partial) tend.PartialUserConfig.DiagnosticIcons: tend.UserConfig.DiagnosticIcons
--- @class (partial) tend.PartialUserConfig.PermissionIcons: tend.UserConfig.PermissionIcons
--- @class (partial) tend.PartialUserConfig.ChatIcons: tend.UserConfig.ChatIcons
--- @class (partial) tend.PartialUserConfig.MessageIcons: tend.UserConfig.MessageIcons
--- @class (partial) tend.PartialUserConfig.FilePicker: tend.UserConfig.FilePicker
--- @class (partial) tend.PartialUserConfig.ImagePaste: tend.UserConfig.ImagePaste
--- @class (partial) tend.PartialUserConfig.AutoScroll: tend.UserConfig.AutoScroll
--- @class (partial) tend.PartialUserConfig.DiffPreview: tend.UserConfig.DiffPreview
--- @class (partial) tend.PartialUserConfig.Folding.ToolCalls: tend.UserConfig.Folding.ToolCalls
--- @class (partial) tend.PartialUserConfig.ToolCalls.Title: tend.UserConfig.ToolCalls.Title
--- @class (partial) tend.PartialUserConfig.Settings: tend.UserConfig.Settings

--- Windows partial with nested type overrides
--- @class (partial) tend.PartialUserConfig.Windows: tend.UserConfig.Windows
--- @field chat? tend.PartialUserConfig.Windows.Chat
--- @field input? tend.PartialUserConfig.Windows.Input
--- @field code? tend.PartialUserConfig.Windows.Code
--- @field files? tend.PartialUserConfig.Windows.Files
--- @field diagnostics? tend.PartialUserConfig.Windows.Diagnostics
--- @field todos? tend.PartialUserConfig.Windows.Todos

--- Folding partial with nested type overrides
--- @class (partial) tend.PartialUserConfig.Folding: tend.UserConfig.Folding
--- @field tool_calls? tend.PartialUserConfig.Folding.ToolCalls

--- Tool calls partial with nested type overrides
--- @class (partial) tend.PartialUserConfig.ToolCalls: tend.UserConfig.ToolCalls
--- @field title? tend.PartialUserConfig.ToolCalls.Title

--- Top-level partial config -- all UserConfig fields become optional
--- Nested fields override to use partial variants
--- @class (partial) tend.PartialUserConfig: tend.UserConfig
--- @field windows? tend.PartialUserConfig.Windows
--- @field keymaps? tend.PartialUserConfig.Keymaps
--- @field spinner_chars? tend.PartialUserConfig.SpinnerChars
--- @field status_icons? tend.PartialUserConfig.StatusIcons
--- @field diagnostic_icons? tend.PartialUserConfig.DiagnosticIcons
--- @field permission_icons? tend.PartialUserConfig.PermissionIcons
--- @field chat_icons? tend.PartialUserConfig.ChatIcons
--- @field message_icons? tend.PartialUserConfig.MessageIcons
--- @field file_picker? tend.PartialUserConfig.FilePicker
--- @field image_paste? tend.PartialUserConfig.ImagePaste
--- @field auto_scroll? tend.PartialUserConfig.AutoScroll
--- @field diff_preview? tend.PartialUserConfig.DiffPreview
--- @field folding? tend.PartialUserConfig.Folding
--- @field tool_calls? tend.PartialUserConfig.ToolCalls
--- @field settings? tend.PartialUserConfig.Settings

--- @class tend.UserConfig
--- @field debug boolean Enable printing debug messages which can be read via `:messages`
--- @field windows tend.UserConfig.Windows
--- @field keymaps tend.UserConfig.Keymaps
--- @field spinner_chars tend.UserConfig.SpinnerChars
--- @field status_icons tend.UserConfig.StatusIcons
--- @field diagnostic_icons tend.UserConfig.DiagnosticIcons
--- @field permission_icons tend.UserConfig.PermissionIcons
--- @field chat_icons tend.UserConfig.ChatIcons
--- @field message_icons tend.UserConfig.MessageIcons
--- @field file_picker tend.UserConfig.FilePicker
--- @field image_paste tend.UserConfig.ImagePaste
--- @field auto_scroll tend.UserConfig.AutoScroll
--- @field diff_preview tend.UserConfig.DiffPreview
--- @field folding tend.UserConfig.Folding
--- @field tool_calls tend.UserConfig.ToolCalls
--- @field hooks tend.UserConfig.Hooks
--- @field headers tend.UserConfig.Headers
--- @field settings tend.UserConfig.Settings
--- @field daemon tend.UserConfig.Daemon
local ConfigDefault = {
    debug = false,

    windows = {
        position = "right",
        width = "40%",
        height = "30%",
        stack_width_ratio = 0.4,
        chat = { win_opts = {} },
        input = { height = 10, win_opts = {} },
        code = { max_height = 15, win_opts = {} },
        files = { max_height = 10, win_opts = {} },
        diagnostics = { max_height = 10, win_opts = {} },
        todos = { display = true, max_height = 10, win_opts = {} },
    },

    keymaps = {
        --- Keys bindings for ALL buffers in the widget
        widget = {
            close = "q",
            change_mode = {
                {
                    "<S-Tab>",
                    mode = { "i", "n", "v" },
                },
            },
            switch_provider = "<localLeader>s",
            switch_session = "<localLeader>S",
            switch_model = "<localLeader>m",
            change_thought_level = "<localLeader>t",
        },

        --- Keys bindings for the prompt buffer
        prompt = {
            submit = {
                "<CR>",
                {
                    "<C-s>",
                    mode = { "i", "n", "v" },
                },
            },

            paste_image = {
                {
                    "<localLeader>p",
                    mode = { "n" },
                },
                {
                    "<C-v>", -- Same as Claude-code in insert mode
                    mode = { "i" },
                },
            },

            accept_completion = {
                {
                    "<Tab>",
                    mode = { "i" },
                },
            },

            pick_file = "<localLeader>f",
        },

        --- Keys bindings for chat buffer navigation
        chat = {
            next_heading = "]]",
            prev_heading = "[[",
            next_tool_call = "]t",
            prev_tool_call = "[t",
        },

        --- Keys bindings for diff preview navigation
        diff_preview = {
            next_hunk = "]c",
            prev_hunk = "[c",
        },

        permission = {
            cycle_next = "<C-n>",
            cycle_prev = "<C-p>",
        },
    },

    -- stylua: ignore start
    spinner_chars = {
        generating = { "·", "✢", "✳", "∗", "✻", "✽" },
        thinking = { "🤔", "🤨" },
        searching = { "🔎. . .", ". 🔎. .", ". . 🔎." },
        busy = { "⡀", "⠄", "⠂", "⠁", "⠈", "⠐", "⠠", "⢀", "⣀", "⢄", "⢂", "⢁", "⢈", "⢐", "⢠", "⣠", "⢤", "⢢", "⢡", "⢨", "⢰", "⣰", "⢴", "⢲", "⢱", "⢸", "⣸", "⢼", "⢺", "⢹", "⣹", "⢽", "⢻", "⣻", "⢿", "⣿", },
    },
    -- stylua: ignore end

    status_icons = {
        pending = "󰔛",
        in_progress = "󰔛",
        completed = "✔",
        failed = "",
    },

    diagnostic_icons = {
        error = "❌",
        warn = "⚠️",
        info = "ℹ️",
        hint = "✨",
    },

    permission_icons = {
        allow_once = "",
        allow_always = "",
        reject_once = "",
        reject_always = "󰜺",
    },

    chat_icons = {
        user = " ",
        agent = "󱚠 ",
    },

    message_icons = {
        thinking = "🧠",
        finished = "🏁",
        stopped = "🛑",
        error = "❌",
    },

    file_picker = {
        enabled = true,
    },

    image_paste = {
        enabled = true,
    },

    auto_scroll = {
        threshold = 10,
    },

    diff_preview = {
        enabled = true,
        layout = "split",
        center_on_navigate_hunks = true,
    },

    folding = {
        tool_calls = {
            enabled = true,
            threshold = 10,
            fold_on_error = false,
        },
    },

    tool_calls = {
        title = {
            max_length = 50,
            truncate_title_kinds = {
                "execute",
                "think",
                "SubAgent",
                "fetch",
                "search",
            },
        },
    },

    hooks = {
        on_create_session_response = nil,
        on_prompt_submit = nil,
        on_response_complete = nil,
        on_session_update = nil,
        on_file_edit = nil,
        on_request_permission = nil,
    },

    headers = {},

    settings = {
        move_cursor_to_chat_on_submit = true,
    },

    daemon = {
        providers = {},
    },
}

return ConfigDefault
