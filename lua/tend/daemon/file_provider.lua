--- The real backend behind the editor.read_buffer / editor.write_buffer reverse
--- handlers: the daemon's file tools (file.apply_change_set / file.read /
--- file.write) resolve live file state and write open buffers through the bound
--- editor (internal/files/files.go readCurrent/apply), so the plugin — as the
--- editor — must answer both. Base logic (changedtick for an open buffer,
--- content hash for a closed file) is shared with the LSP provider via
--- `tend.daemon.file_base` so a change set is stamped one way in one place.
---
--- read_buffer prefers a live buffer (open=true) and falls back to disk bytes
--- (open=false); the daemon re-reads disk itself for a closed file, so the
--- closed content is informational. write_buffer replaces an open buffer and is
--- conflict-guarded: the cited base changedtick must still match, otherwise the
--- write is refused so a stale edit never clobbers a moved-on buffer.
local FileBase = require("tend.daemon.file_base")
local rpc = require("tend.rpc.client")

local M = {}

--- A conflict error reply for a refused write. The daemon surfaces the message
--- (it does not branch on the code), so a stale write reads as a real conflict.
--- @param message string
--- @return tend.rpc.Error err
local function conflict(message)
    return { code = rpc.ERR_INVALID_REQUEST, message = message }
end

--- @class tend.daemon.FileProvider
local FileProvider = {}
FileProvider.__index = FileProvider
M.FileProvider = FileProvider

--- @return tend.daemon.FileProvider
function FileProvider.new()
    return setmetatable({}, FileProvider)
end

--- Read a file's editor-aware state: a live buffer's content + changedtick when
--- open, else the file's disk bytes + content hash. A file that is neither open
--- nor on disk reports open=false with empty content and no base, so the daemon
--- falls back to disk (an absent file).
--- @param uri string|nil
--- @return table result EditorReadBufferResult { content, base, open }
function FileProvider:read_buffer(uri)
    local bufnr, open, buf_uri = FileBase.resolve(uri)
    if open then
        return {
            content = FileBase.buffer_bytes(bufnr),
            base = { changedtick = vim.api.nvim_buf_get_changedtick(bufnr) },
            open = true,
        }
    end
    local bytes = FileBase.read_bytes(vim.uri_to_fname(buf_uri))
    if bytes == nil then
        return { content = "", base = vim.empty_dict(), open = false }
    end
    return {
        content = bytes,
        base = { content_hash = vim.fn.sha256(bytes) },
        open = false,
    }
end

--- Replace an open buffer's whole content, conflict-checked against the cited
--- base. Returns the buffer's new base on success, or a conflict error when the
--- buffer is not open or its changedtick has moved on since the cited base.
--- @param uri string|nil
--- @param content string|nil
--- @param base table|nil wire FileBase the write expects
--- @return table|nil result EditorWriteBufferResult { base }
--- @return tend.rpc.Error|nil err on conflict
function FileProvider:write_buffer(uri, content, base)
    local bufnr, open = FileBase.resolve(uri)
    if not open then
        return nil, conflict("write_buffer: buffer is not open")
    end
    local want = type(base) == "table" and base.changedtick or nil
    if want == nil or want ~= vim.api.nvim_buf_get_changedtick(bufnr) then
        return nil, conflict("write_buffer: buffer changedtick mismatch")
    end

    -- A trailing newline is the buffer's endofline, not a stored empty line:
    -- strip it and mirror it in 'eol'/'fixeol' so the file round-trips.
    local text = content or ""
    local has_eol = text:sub(-1) == "\n"
    local body = has_eol and text:sub(1, -2) or text
    vim.api.nvim_buf_set_lines(
        bufnr,
        0,
        -1,
        false,
        vim.split(body, "\n", { plain = true })
    )
    vim.bo[bufnr].eol = has_eol
    vim.bo[bufnr].fixeol = has_eol
    return { base = { changedtick = vim.api.nvim_buf_get_changedtick(bufnr) } }
end

return M
