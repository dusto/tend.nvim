--- Rendering of a pending approval's decision context into display lines.
---
--- The approval payload is self-contained: it identifies the exact operation
--- and carries everything needed to decide — for a file edit, the per-target
--- unified diff and base revision; for a pane run, the command, cwd, and
--- environment. The diff preview renders straight from that payload, with no
--- daemon round trip.
---
--- render() returns the lines plus highlight marks (row + built-in highlight
--- group) so a view can paint them as extmarks.
local M = {}

--- @class tend.approval.Mark
--- @field row integer 0-based line index
--- @field group string highlight group name

--- @class tend.approval.RenderOut
--- @field lines string[]
--- @field marks tend.approval.Mark[]

--- @param out tend.approval.RenderOut
--- @param line string
--- @param group string|nil
local function put(out, line, group)
    table.insert(out.lines, line)
    if group then
        table.insert(out.marks, { row = #out.lines - 1, group = group })
    end
end

--- A short display form of a file-edit base revision (changedtick for an open
--- buffer, truncated content hash for a closed file).
--- @param base table|nil
--- @return string
local function base_label(base)
    if type(base) ~= "table" then
        return "?"
    end
    if base.changedtick ~= nil then
        return "changedtick " .. tostring(base.changedtick)
    end
    if type(base.content_hash) == "string" then
        return base.content_hash:sub(1, 12)
    end
    return "?"
end

--- The highlight group for one unified-diff line, or nil for context lines.
--- @param line string
--- @return string|nil
local function diff_group(line)
    if line:find("^%+%+%+ ") or line:find("^%-%-%- ") then
        return "Title"
    end
    if line:find("^@@") then
        return "Changed"
    end
    if line:find("^%+") then
        return "Added"
    end
    if line:find("^%-") then
        return "Removed"
    end
    return nil
end

--- @param out tend.approval.RenderOut
--- @param detail table
local function render_file_edit(out, detail)
    for _, target in ipairs(detail.targets or {}) do
        put(
            out,
            "── "
                .. tostring(target.uri)
                .. " · base "
                .. base_label(target.base),
            "Directory"
        )
        if type(target.diff) == "string" and target.diff ~= "" then
            for _, line in
                ipairs(vim.split(target.diff, "\n", { plain = true }))
            do
                put(out, line, diff_group(line))
            end
        end
    end
end

--- @param out tend.approval.RenderOut
--- @param detail table
local function render_pane_run(out, detail)
    put(out, "command: " .. tostring(detail.command))
    put(out, "cwd: " .. tostring(detail.cwd))
    if type(detail.env) == "table" and #detail.env > 0 then
        put(out, "env: " .. table.concat(detail.env, " "))
    end
    put(out, "pane: " .. tostring(detail.pane_id))
end

--- @param out tend.approval.RenderOut
--- @param detail table
local function render_pane_open(out, detail)
    put(out, "cwd: " .. tostring(detail.cwd))
    if detail.workspace_id ~= nil then
        put(out, "workspace: " .. tostring(detail.workspace_id))
    end
end

--- The path a file:// uri points at, or nil when it is not a file uri (so a
--- non-file requested_uri is compared verbatim rather than crashing uri_to_fname).
--- @param uri string
--- @return string|nil path
local function file_uri_path(uri)
    if type(uri) ~= "string" or uri:sub(1, 7) ~= "file://" then
        return nil
    end
    return vim.uri_to_fname(uri)
end

--- Render a filesystem_access approval as a read-consent decision, never a diff.
--- An outside-worktree read is a consent choice: the daemon resolved the path,
--- and the user is approving access to the RESOLVED target. So the resolved path
--- leads the prompt, "outside the worktree" is called out unmistakably, and the
--- requested uri is shown only when it resolves elsewhere (a symlink alias) so
--- the user consents to the real target, not the alias.
--- @param out tend.approval.RenderOut
--- @param detail table
local function render_filesystem_access(out, detail)
    local resolved = tostring(detail.resolved_path)
    local operation = detail.mode == "diagnostics"
            and ("read diagnostics for " .. resolved)
        or ("read " .. resolved)
    put(out, "Allow this session to " .. operation .. "?")
    put(out, "outside the worktree", "WarningMsg")
    if
        detail.requested_uri ~= nil
        and file_uri_path(detail.requested_uri) ~= resolved
    then
        put(out, "requested: " .. tostring(detail.requested_uri))
    end
    if type(detail.tool) == "string" and detail.tool ~= "" then
        put(out, "tool: " .. detail.tool)
    end
end

--- @param out tend.approval.RenderOut
--- @param detail table
local function render_code_action(out, detail)
    put(out, "action: " .. tostring(detail.title))
    put(out, "file: " .. tostring(detail.uri))
end

--- @type table<string, fun(out: tend.approval.RenderOut, detail: table)>
local detail_renderers = {
    file_edit = render_file_edit,
    filesystem_access = render_filesystem_access,
    pane_run = render_pane_run,
    pane_open = render_pane_open,
    code_action = render_code_action,
}

--- Render one approval into display lines and highlight marks.
--- @param approval tend.approval.Approval
--- @return string[] lines
--- @return tend.approval.Mark[] marks
function M.render(approval)
    --- @type tend.approval.RenderOut
    local out = { lines = {}, marks = {} }
    put(out, approval.kind .. " · session " .. approval.session_id, "Title")
    if type(approval.prompt) == "string" and approval.prompt ~= "" then
        for _, line in
            ipairs(vim.split(approval.prompt, "\n", { plain = true }))
        do
            put(out, line)
        end
    end
    if type(approval.expires_at) == "string" and approval.expires_at ~= "" then
        put(out, "expires " .. approval.expires_at, "Comment")
    end
    put(out, "")
    local renderer = detail_renderers[approval.kind]
    if renderer and type(approval.detail) == "table" then
        renderer(out, approval.detail)
    else
        put(out, "(no decision context)")
    end
    return out.lines, out.marks
end

return M
