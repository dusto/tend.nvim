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
--- Rendering is pluggable: the daemon's before/after snapshots are handed to a
--- configured renderer (see `Config.diff_review`). The native renderer — split
--- (two diff-mode buffers) or unified (one `diff` filetype buffer) — is the
--- default and the fallback. A `mini_diff` backend overlays the snapshots via
--- mini.diff when present, and a `custom` backend routes to a user callback;
--- both fall back to native when their dependency is unavailable.
--- @class tend.ui.DiffReview
local M = {}

local Config = require("tend.config")

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

--- Compute a unified diff of two snapshots, preferring the 0.12 `vim.text.diff`
--- and falling back to `vim.diff` on 0.11.x, where the former does not exist.
--- @param before string
--- @param after string
--- @return string unified
local function unified_diff(before, after)
    local out
    if vim.text and vim.text.diff then
        out = vim.text.diff(before, after)
    else
        -- vim.text.diff is unavailable on Neovim 0.11.x; vim.diff is the only
        -- option there despite being deprecated on 0.12+.
        --- @diagnostic disable-next-line: deprecated
        out = vim.diff(before, after)
    end
    -- The default result_type is "unified" (a string); narrow the union away.
    if type(out) == "string" then
        return out
    end
    return ""
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
--- @field before_bufnr? integer left buffer of the native split style
--- @field after_bufnr? integer right buffer of the native split style
--- @field bufnr? integer single buffer of the unified / mini_diff styles

--- A diff renderer consumes a change set's self-contained snapshots and returns
--- the per-file rendered views. Custom backends may return an empty list.
--- @alias tend.ui.DiffReview.RenderFn fun(change_set_id: string, files: tend.ui.DiffReview.File[]): tend.ui.DiffReview.Rendered[]

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

--- Native split style: one tab per file, the before content on the left and the
--- after on the right, both read-only and in `diff` mode.
--- @param change_set_id string
--- @param files tend.ui.DiffReview.File[]
--- @return tend.ui.DiffReview.Rendered[]
function M.render_split(change_set_id, files)
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

--- Native unified style: one tab per file, a single read-only `diff` buffer
--- holding the unified hunks computed from the snapshots (no disk reads).
--- @param change_set_id string
--- @param files tend.ui.DiffReview.File[]
--- @return tend.ui.DiffReview.Rendered[]
function M.render_unified(change_set_id, files)
    local rendered = {}
    for _, file in ipairs(files or {}) do
        local tag = NS_PREFIX .. change_set_id .. "/" .. file.uri
        local hunks = unified_diff(file.before or "", file.after or "")

        vim.cmd("tabnew")
        local tabpage = vim.api.nvim_get_current_tabpage()
        local lines = {
            "--- " .. file.uri .. " (before)",
            "+++ " .. file.uri .. " (after)",
        }
        for _, line in ipairs(to_lines(hunks)) do
            table.insert(lines, line)
        end

        local bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        pcall(vim.api.nvim_buf_set_name, bufnr, tag .. " (unified)")
        vim.bo[bufnr].filetype = "diff"
        vim.bo[bufnr].modifiable = false
        vim.api.nvim_set_current_buf(bufnr)

        table.insert(rendered, {
            uri = file.uri,
            tabpage = tabpage,
            bufnr = bufnr,
        })
    end
    return rendered
end

--- Native renderer: dispatch to the configured style, defaulting to split.
--- @param change_set_id string
--- @param files tend.ui.DiffReview.File[]
--- @return tend.ui.DiffReview.Rendered[]
function M.render_native(change_set_id, files)
    if Config.diff_review.style == "unified" then
        return M.render_unified(change_set_id, files)
    end
    return M.render_split(change_set_id, files)
end

--- Return the mini.diff module if it is installed, else nil. Split out so the
--- mini_diff backend's availability check is injectable in tests.
--- @return table|nil mini the mini.diff module, or nil when absent
function M.get_mini_diff()
    local ok, mini = pcall(require, "mini.diff")
    if ok then
        return mini
    end
    return nil
end

--- mini.diff backend: one tab per file, the after content in a read-only buffer
--- with the before content set as mini.diff's reference text so its overlay
--- renders the hunks. Falls back to native when mini.diff is not installed.
--- @param change_set_id string
--- @param files tend.ui.DiffReview.File[]
--- @return tend.ui.DiffReview.Rendered[]
function M.render_mini_diff(change_set_id, files)
    local mini = M.get_mini_diff()
    if not mini then
        return M.render_native(change_set_id, files)
    end

    local rendered = {}
    for _, file in ipairs(files or {}) do
        local ft = vim.filetype.match({ filename = uri_to_path(file.uri) })
            or ""
        local tag = NS_PREFIX .. change_set_id .. "/" .. file.uri

        vim.cmd("tabnew")
        local tabpage = vim.api.nvim_get_current_tabpage()
        local bufnr = snapshot_buf(tag .. " (after)", file.after, ft)
        vim.api.nvim_set_current_buf(bufnr)

        -- A scratch buffer is not auto-enabled by mini.diff, so enable it, seed
        -- the before content as its reference, and reveal the overlay.
        pcall(mini.enable, bufnr)
        pcall(mini.set_ref_text, bufnr, file.before or "")
        pcall(mini.toggle_overlay, bufnr)

        table.insert(rendered, {
            uri = file.uri,
            tabpage = tabpage,
            bufnr = bufnr,
        })
    end
    return rendered
end

--- Resolve the renderer for the configured backend. Unknown or unsatisfied
--- backends resolve to native (the plugin/callback backends fall back inside
--- their own renderer when their dependency is missing).
--- @return tend.ui.DiffReview.RenderFn renderer
function M.resolve_renderer()
    local cfg = Config.diff_review or {}
    if cfg.backend == "custom" and type(cfg.renderer) == "function" then
        return cfg.renderer
    end
    if cfg.backend == "mini_diff" then
        return M.render_mini_diff
    end
    return M.render_native
end

--- Render a change set's captured snapshots through the configured backend.
--- Returns the per-file rendered views (for tests/inspection).
--- @param change_set_id string
--- @param files tend.ui.DiffReview.File[]
--- @return tend.ui.DiffReview.Rendered[]
function M.show_snapshots(change_set_id, files)
    return M.resolve_renderer()(change_set_id, files or {})
end

return M
