local assert = require("tests.helpers.assert")

describe("tend.daemon.file_base", function()
    local FileBase = require("tend.daemon.file_base")
    local scratch = {}
    local tempfiles = {}

    local function make_file_buffer(lines)
        local path = vim.fn.tempname() .. ".lua"
        local bufnr = vim.fn.bufadd(path)
        vim.fn.bufload(bufnr)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines or {})
        table.insert(scratch, bufnr)
        return bufnr, vim.uri_from_bufnr(bufnr)
    end

    local function write_temp(bytes)
        local path = vim.fn.tempname()
        local f = io.open(path, "wb")
        if not f then
            error("write_temp: could not open " .. path)
        end
        f:write(bytes)
        f:close()
        table.insert(tempfiles, path)
        return path
    end

    after_each(function()
        for _, b in ipairs(scratch) do
            if vim.api.nvim_buf_is_valid(b) then
                vim.api.nvim_buf_delete(b, { force = true })
            end
        end
        for _, p in ipairs(tempfiles) do
            os.remove(p)
        end
        scratch = {}
        tempfiles = {}
    end)

    it("resolve returns the current buffer for an empty URI", function()
        local buf = make_file_buffer({ "x" })
        vim.api.nvim_set_current_buf(buf)
        local bufnr, open = FileBase.resolve("")
        assert.equal(buf, bufnr)
        assert.is_true(open)
    end)

    it("resolve reports open=false for an unloaded file URI", function()
        local _, open = FileBase.resolve("file:///no/such/path/here.lua")
        assert.is_false(open)
    end)

    it("read_bytes returns exact bytes including trailing newline", function()
        local path = write_temp("hello world\n")
        assert.equal("hello world\n", FileBase.read_bytes(path))
    end)

    it("read_bytes returns nil for a missing file", function()
        assert.is_nil(FileBase.read_bytes("/no/such/file/at/all"))
    end)

    it("buffer_bytes appends a trailing newline when eol is set", function()
        local buf = make_file_buffer({ "a", "b" })
        vim.bo[buf].eol = true
        assert.equal("a\nb\n", FileBase.buffer_bytes(buf))
    end)

    it("buffer_bytes omits the trailing newline when eol is unset", function()
        local buf = make_file_buffer({ "a", "b" })
        vim.bo[buf].eol = false
        assert.equal("a\nb", FileBase.buffer_bytes(buf))
    end)

    it("base_of uses the changedtick for an open buffer", function()
        local buf, uri = make_file_buffer({ "x" })
        local base = FileBase.base_of(uri)
        assert.equal(vim.api.nvim_buf_get_changedtick(buf), base.changedtick)
        assert.is_nil(base.content_hash)
    end)

    it("base_of hashes disk bytes for a closed file", function()
        local path = write_temp("hello world\n")
        local uri = vim.uri_from_fname(path)
        local base = FileBase.base_of(uri)
        assert.equal(vim.fn.sha256("hello world\n"), base.content_hash)
        assert.is_nil(base.changedtick)
    end)
end)
