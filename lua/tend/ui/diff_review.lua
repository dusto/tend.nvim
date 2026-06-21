--- Read-only review affordances for daemon change sets: open the changed files
--- in buffers, or show a change set's captured before/after snapshots in a
--- native diff view.
---
--- These render from self-contained snapshots — the daemon's editor.diff
--- request (and file.diff result) carry the full before/after content — so this
--- never reads disk or reconstructs a file. That is deliberate: a denied or
--- still-pending proposal was never written, so the live file does not match
--- the snapshot. Each file is reviewed as its own diff tab (two read-only
--- scratch buffers in `diff` mode), independent of whether the file is open.
--- @class tend.ui.DiffReview
local M = {}

local NS_PREFIX = "tend://review/"

--- @param uri string a file:// uri
--- @return string path
local function uri_to_path(uri)
    return vim.uri_to_fname(uri)
end

--- @param text string
--- @return string[] lines
local function to_lines(text)
    return vim.split(text or "", "\n", { plain = true })
end

--- @param uri string
--- @return boolean
local function is_file_uri(uri)
    return type(uri) == "string" and uri:sub(1, 7) == "file://"
end

--- Open each file in a buffer for in-place review. Only the first is focused —
--- opening a set must not yank the cursor through every file. file:// uris are
--- resolved to paths; anything else is skipped. Returns the buffers opened.
--- @param uris string[]
--- @return integer[] bufnrs
function M.open_files(uris)
    local bufnrs = {}
    for _, uri in ipairs(uris or {}) do
        if is_file_uri(uri) then
            local bufnr = vim.fn.bufadd(uri_to_path(uri))
            vim.fn.bufload(bufnr)
            if #bufnrs == 0 then
                -- Focus only the first; the rest are loaded for review.
                vim.api.nvim_set_current_buf(bufnr)
            end
            table.insert(bufnrs, bufnr)
        end
    end
    return bufnrs
end

--- @class tend.ui.DiffReview.File
--- @field uri string
--- @field before string
--- @field after string

--- @class tend.ui.DiffReview.Rendered
--- @field uri string
--- @field tabpage integer
--- @field before_bufnr integer
--- @field after_bufnr integer

--- @param name string buffer display name
--- @param text string snapshot content
--- @param ft string filetype to mirror onto the scratch buffer
--- @return integer bufnr
local function snapshot_buf(name, text, ft)
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, to_lines(text))
    pcall(vim.api.nvim_buf_set_name, bufnr, name)
    if ft and ft ~= "" then
        vim.bo[bufnr].filetype = ft
    end
    vim.bo[bufnr].modifiable = false
    return bufnr
end

--- Show a change set's captured snapshots as native diffs: one tab per file,
--- the before content on the left and the after on the right, both read-only.
--- Returns the per-file rendered views (for tests/inspection).
--- @param change_set_id string
--- @param files tend.ui.DiffReview.File[]
--- @return tend.ui.DiffReview.Rendered[]
function M.show_snapshots(change_set_id, files)
    local rendered = {}
    for _, file in ipairs(files or {}) do
        local ft = vim.filetype.match({ filename = uri_to_path(file.uri) })
            or ""
        local tag = NS_PREFIX .. change_set_id .. "/" .. file.uri

        vim.cmd("tabnew")
        local tabpage = vim.api.nvim_get_current_tabpage()
        local before = snapshot_buf(tag .. " (before)", file.before, ft)
        local after = snapshot_buf(tag .. " (after)", file.after, ft)

        -- before on the left (current window of the new tab), after on the right.
        local left = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(left, before)
        local right = vim.api.nvim_open_win(after, true, {
            split = "right",
            win = left,
        })
        vim.api.nvim_win_call(left, function()
            vim.cmd("diffthis")
        end)
        vim.api.nvim_win_call(right, function()
            vim.cmd("diffthis")
        end)

        table.insert(rendered, {
            uri = file.uri,
            tabpage = tabpage,
            before_bufnr = before,
            after_bufnr = after,
        })
    end
    return rendered
end

return M
