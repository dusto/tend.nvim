local assert = require("tests.helpers.assert")

describe("tend.daemon.file_provider", function()
    local FileProviderMod = require("tend.daemon.file_provider")
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

    describe("read_buffer", function()
        it(
            "returns live content and a changedtick for an open buffer",
            function()
                local prov = FileProviderMod.FileProvider.new()
                local buf, uri = make_file_buffer({ "a", "b" })
                local res = prov:read_buffer(uri)
                assert.is_true(res.open)
                assert.equal("a\nb\n", res.content)
                assert.equal(
                    vim.api.nvim_buf_get_changedtick(buf),
                    res.base.changedtick
                )
                assert.is_nil(res.base.content_hash)
            end
        )

        it("returns disk bytes and a content hash for a closed file", function()
            local prov = FileProviderMod.FileProvider.new()
            local path = write_temp("hello world\n")
            local res = prov:read_buffer(vim.uri_from_fname(path))
            assert.is_false(res.open)
            assert.equal("hello world\n", res.content)
            assert.equal(vim.fn.sha256("hello world\n"), res.base.content_hash)
        end)

        it(
            "reports open=false with empty content for an absent file",
            function()
                local prov = FileProviderMod.FileProvider.new()
                local res = prov:read_buffer("file:///no/such/file/xyz.lua")
                assert.is_false(res.open)
                assert.equal("", res.content)
            end
        )
    end)

    describe("write_buffer", function()
        it("replaces an open buffer and returns the new changedtick", function()
            local prov = FileProviderMod.FileProvider.new()
            local buf, uri = make_file_buffer({ "old" })
            local tick = vim.api.nvim_buf_get_changedtick(buf)
            local res, err = prov:write_buffer(uri, "new\nlines\n", {
                changedtick = tick,
            })
            --- @cast res -nil
            assert.is_nil(err)
            assert.same(
                { "new", "lines" },
                vim.api.nvim_buf_get_lines(buf, 0, -1, false)
            )
            assert.equal(
                vim.api.nvim_buf_get_changedtick(buf),
                res.base.changedtick
            )
        end)

        it("preserves a missing trailing newline via eol", function()
            local prov = FileProviderMod.FileProvider.new()
            local buf, uri = make_file_buffer({ "old" })
            local tick = vim.api.nvim_buf_get_changedtick(buf)
            prov:write_buffer(uri, "no-eol", { changedtick = tick })
            assert.is_false(vim.bo[buf].eol)
            assert.same(
                { "no-eol" },
                vim.api.nvim_buf_get_lines(buf, 0, -1, false)
            )
        end)

        it("refuses the write on a changedtick conflict", function()
            local prov = FileProviderMod.FileProvider.new()
            local buf, uri = make_file_buffer({ "old" })
            local stale = vim.api.nvim_buf_get_changedtick(buf) - 1
            local res, err = prov:write_buffer(uri, "new\n", {
                changedtick = stale,
            })
            assert.is_nil(res)
            assert.is_not_nil(err)
            -- The buffer is untouched.
            assert.same(
                { "old" },
                vim.api.nvim_buf_get_lines(buf, 0, -1, false)
            )
        end)

        it("refuses the write when the buffer is not open", function()
            local prov = FileProviderMod.FileProvider.new()
            local res, err = prov:write_buffer(
                "file:///no/such/open/buffer.lua",
                "x\n",
                { changedtick = 1 }
            )
            assert.is_nil(res)
            assert.is_not_nil(err)
        end)
    end)
end)
