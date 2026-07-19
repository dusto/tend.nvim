--- A small buffer-based authoring form for :TendTaskNew. The single-title
--- vim.ui.input prompt could not carry the real ticket context a delegated agent
--- needs, so this collects title, description, acceptance criteria, labels, and
--- priority in an editable float: markdown `#` headings delimit the fields, the
--- user fills the bodies, and `<C-s>` submits (`q`/`<Esc>` cancels).
---
--- The parser is pure (buffer lines -> fields), so it is unit-testable without a
--- window; open() is the thin UI wrapper. Only the title is required; the daemon
--- ignores fields a provider does not support (api.TaskCreateParams).
local BufHelpers = require("tend.utils.buf_helpers")

local M = {}

--- @class tend.ui.TaskForm.Fields
--- @field title string
--- @field description string
--- @field acceptance_criteria string
--- @field priority string
--- @field labels string[]

-- Heading prefix (lowercased) -> field key. Prefixes are distinct, so a simple
-- longest-unambiguous match keys each section; unknown headings are ignored.
local HEADINGS = {
    { prefix = "title", key = "title" },
    { prefix = "description", key = "description" },
    { prefix = "acceptance", key = "acceptance_criteria" },
    { prefix = "labels", key = "labels" },
    { prefix = "priority", key = "priority" },
}

--- @param heading string
--- @return string|nil key
local function field_for(heading)
    local h = heading:lower()
    for _, entry in ipairs(HEADINGS) do
        if h:sub(1, #entry.prefix) == entry.prefix then
            return entry.key
        end
    end
    return nil
end

--- The blank form template: a markdown-headed section per field.
--- @return string[] lines
function M.template()
    return {
        "# Title",
        "",
        "",
        "# Description",
        "",
        "",
        "# Acceptance criteria",
        "",
        "",
        "# Labels (comma-separated)",
        "",
        "",
        "# Priority (0-4, blank to omit)",
        "",
        "",
    }
end

--- Parse form buffer lines into task fields. Each `# Heading` starts a section;
--- its body is the lines until the next heading, trimmed. Labels split on commas
--- (empties dropped); every other field is the trimmed body text.
--- @param lines string[]
--- @return tend.ui.TaskForm.Fields fields
function M.parse(lines)
    local sections = {}
    local current = nil
    for _, line in ipairs(lines) do
        local heading = line:match("^#%s+(.+)")
        if heading then
            current = field_for(heading)
            if current and sections[current] == nil then
                sections[current] = {}
            end
        elseif current and sections[current] then
            table.insert(sections[current], line)
        end
    end

    local function body(key)
        return sections[key] and vim.trim(table.concat(sections[key], "\n"))
            or ""
    end

    local labels = {}
    for _, part in ipairs(vim.split(body("labels"), ",", { plain = true })) do
        local l = vim.trim(part)
        if l ~= "" then
            table.insert(labels, l)
        end
    end

    --- @type tend.ui.TaskForm.Fields
    local fields = {
        title = body("title"),
        description = body("description"),
        acceptance_criteria = body("acceptance_criteria"),
        priority = body("priority"),
        labels = labels,
    }
    return fields
end

--- @class tend.ui.TaskForm.Handle
--- @field buf integer
--- @field win integer
--- @field submit fun() parse the buffer and submit, or reject an empty title
--- @field cancel fun() close without submitting

--- @class tend.ui.TaskForm.Opts
--- @field on_submit fun(fields: tend.ui.TaskForm.Fields) called with a valid form
--- @field on_invalid? fun(reason: string) called when submit is rejected (no title)
--- @field on_cancel? fun()

--- Open the authoring form. Returns a handle whose submit/cancel mirror the
--- buffer keymaps, so callers (and tests) can drive it without feeding keys.
--- @param opts tend.ui.TaskForm.Opts
--- @return tend.ui.TaskForm.Handle
function M.open(opts)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = "markdown"
    vim.bo[buf].bufhidden = "wipe"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, M.template())
    pcall(vim.treesitter.start, buf, "markdown")

    local width = math.floor(vim.o.columns * 0.6)
    local height = math.min(#M.template() + 2, math.floor(vim.o.lines * 0.8))
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        row = math.floor((vim.o.lines - height) / 2),
        col = math.floor((vim.o.columns - width) / 2),
        style = "minimal",
        border = "rounded",
        title = " New task  (<C-s> submit · q cancel) ",
        title_pos = "center",
    })
    vim.wo[win][0].wrap = true
    vim.wo[win][0].linebreak = true

    local closed = false
    local function close()
        if closed then
            return
        end
        closed = true
        if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
        end
    end

    local function cancel()
        close()
        if opts.on_cancel then
            opts.on_cancel()
        end
    end

    local function submit()
        if not vim.api.nvim_buf_is_valid(buf) then
            return
        end
        local fields = M.parse(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
        if fields.title == "" then
            if opts.on_invalid then
                opts.on_invalid("a task needs a title")
            end
            return
        end
        close()
        opts.on_submit(fields)
    end

    --- @type tend.ui.TaskForm.Handle
    local handle = { buf = buf, win = win, submit = submit, cancel = cancel }

    for _, mode in ipairs({ "n", "i" }) do
        BufHelpers.keymap_set(buf, mode, "<C-s>", submit)
    end
    BufHelpers.keymap_set(buf, "n", "q", cancel)
    BufHelpers.keymap_set(buf, "n", "<Esc>", cancel)

    -- Land the cursor on the title body line, ready to type.
    vim.api.nvim_win_set_cursor(win, { 2, 0 })
    vim.cmd.startinsert()
    return handle
end

return M
