--- A buffer-based authoring form for :TendMemoryWrite, a sibling of task_form:
--- markdown `#` headings delimit Title / Tags / Body, the user fills the bodies,
--- and `<C-s>` submits (`q`/`<Esc>` cancels).
---
--- The parser is pure (buffer lines -> fields), so it is unit-testable without a
--- window; open() is the thin UI wrapper. A note needs a body; the title is
--- optional (the daemon derives a stable id from it, or generates one when it is
--- blank). Notes only — steering authoring (apply/globs) is a separate feature.
--- open({ body = ... }) seeds the Body section, so a visual selection can be
--- stashed as a note.
local BufHelpers = require("tend.utils.buf_helpers")

local M = {}

--- @class tend.ui.MemoryForm.Fields
--- @field title string
--- @field tags string[]
--- @field body string

-- Heading prefix (lowercased) -> field key; unknown headings are ignored.
local HEADINGS = {
    { prefix = "title", key = "title" },
    { prefix = "tags", key = "tags" },
    { prefix = "body", key = "body" },
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

--- The blank form template: a markdown-headed section per field. An optional
--- body string seeds the Body section (selection capture).
--- @param opts? { body?: string }
--- @return string[] lines
function M.template(opts)
    local body = opts and opts.body or ""
    --- @type string[]
    local lines = {
        "# Title",
        "",
        "",
        "# Tags (comma-separated)",
        "",
        "",
        "# Body",
        "",
    }
    vim.list_extend(lines, vim.split(body, "\n", { plain = true }))
    return lines
end

--- Parse form buffer lines into note fields. Each `# Heading` starts a section;
--- its body is the lines until the next heading, trimmed. Tags split on commas
--- (empties dropped); title and body are the trimmed section text.
--- @param lines string[]
--- @return tend.ui.MemoryForm.Fields fields
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

    local tags = {}
    for _, part in ipairs(vim.split(body("tags"), ",", { plain = true })) do
        local t = vim.trim(part)
        if t ~= "" then
            table.insert(tags, t)
        end
    end

    --- @type tend.ui.MemoryForm.Fields
    local fields = {
        title = body("title"),
        tags = tags,
        body = body("body"),
    }
    return fields
end

--- @class tend.ui.MemoryForm.Handle
--- @field buf integer
--- @field win integer
--- @field submit fun() parse the buffer and submit, or reject an empty body
--- @field cancel fun() close without submitting

--- @class tend.ui.MemoryForm.Opts
--- @field on_submit fun(fields: tend.ui.MemoryForm.Fields) called with a valid form
--- @field on_invalid? fun(reason: string) called when submit is rejected (no body)
--- @field on_cancel? fun()
--- @field body? string seed the Body section (selection capture)
--- @field task_label? string a task id shown in the title when the note is task-bound

--- Open the authoring form. Returns a handle whose submit/cancel mirror the
--- buffer keymaps, so callers (and tests) can drive it without feeding keys.
--- @param opts tend.ui.MemoryForm.Opts
--- @return tend.ui.MemoryForm.Handle
function M.open(opts)
    local template = M.template({ body = opts.body })

    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = "markdown"
    vim.bo[buf].bufhidden = "wipe"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, template)
    pcall(vim.treesitter.start, buf, "markdown")

    local scope = opts.task_label and (" · task " .. opts.task_label) or ""
    local width = math.floor(vim.o.columns * 0.6)
    local height = math.min(#template + 2, math.floor(vim.o.lines * 0.8))
    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        row = math.floor((vim.o.lines - height) / 2),
        col = math.floor((vim.o.columns - width) / 2),
        style = "minimal",
        border = "rounded",
        title = " New memory note" .. scope .. "  (<C-s> submit · q cancel) ",
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
        if fields.body == "" then
            if opts.on_invalid then
                opts.on_invalid("a memory note needs a body")
            end
            return
        end
        close()
        opts.on_submit(fields)
    end

    --- @type tend.ui.MemoryForm.Handle
    local handle = { buf = buf, win = win, submit = submit, cancel = cancel }

    for _, mode in ipairs({ "n", "i" }) do
        BufHelpers.keymap_set(buf, mode, "<C-s>", submit)
    end
    BufHelpers.keymap_set(buf, "n", "q", cancel)
    BufHelpers.keymap_set(buf, "n", "<Esc>", cancel)

    -- Land the cursor on the title body line. The form rests in normal mode (not
    -- insert) so its cancel/submit keymaps fire on the first keypress: an
    -- insert-mode start would make `q` type a literal "q" and `<Esc>` merely
    -- leave insert, contradicting the documented cancel keys.
    vim.api.nvim_win_set_cursor(win, { 2, 0 })
    return handle
end

return M
