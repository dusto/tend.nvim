--- Shared file-state helpers for the editor.* reverse handlers: resolving a wire
--- URI to a buffer, reconstructing a loaded buffer's on-disk bytes, reading a
--- closed file's exact bytes, and stamping the FileBase the daemon's verifyBase
--- checks. Both the LSP provider (code-action change targets) and the
--- file-mutation provider (read_buffer/write_buffer) share this so the Base a
--- change set is computed against is stamped one way, in one place.
---
--- The FileBase mirrors the daemon (internal/files/files.go): a changedtick for
--- an open buffer, a SHA-256 content hash for a closed file. vim.fn.sha256 is
--- byte-identical to Go's crypto/sha256 hex over the same bytes.
local M = {}

--- Resolve a wire URI to a buffer. An empty URI means the active buffer.
--- @param uri string|nil
--- @return integer bufnr
--- @return boolean open whether the buffer is loaded (editor-fresh)
--- @return string buf_uri the buffer's own URI
function M.resolve(uri)
    local bufnr
    if uri == nil or uri == "" then
        bufnr = vim.api.nvim_get_current_buf()
    else
        bufnr = vim.uri_to_bufnr(uri)
    end
    return bufnr, vim.api.nvim_buf_is_loaded(bufnr), vim.uri_from_bufnr(bufnr)
end

--- Read a closed file's raw bytes (exactly, including a trailing newline) so a
--- content hash matches the daemon's crypto/sha256 over the same bytes.
--- @param path string
--- @return string|nil bytes
function M.read_bytes(path)
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local data = f:read("*a")
    f:close()
    return data
end

--- Reconstruct a loaded buffer's on-disk bytes: the lines joined by "\n", plus a
--- trailing newline when the buffer keeps one (endofline). This is what Neovim
--- would write to disk, so a patch computed against it round-trips.
--- @param bufnr integer
--- @return string bytes
function M.buffer_bytes(bufnr)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local content = table.concat(lines, "\n")
    if vim.bo[bufnr].eol then
        content = content .. "\n"
    end
    return content
end

--- The FileBase for a URI: a changedtick for an open buffer, else a SHA-256
--- content hash of the file's bytes — matching the daemon's verifyBase. A file
--- that is neither open nor on disk hashes the empty string.
--- @param uri string
--- @return table base wire FileBase
function M.base_of(uri)
    local bufnr = vim.uri_to_bufnr(uri)
    if vim.api.nvim_buf_is_loaded(bufnr) then
        return { changedtick = vim.api.nvim_buf_get_changedtick(bufnr) }
    end
    local bytes = M.read_bytes(vim.uri_to_fname(uri)) or ""
    return { content_hash = vim.fn.sha256(bytes) }
end

return M
