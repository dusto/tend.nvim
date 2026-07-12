local assert = require("tests.helpers.assert")

describe("tend.daemon.lsp_provider", function()
    local LspProviderMod = require("tend.daemon.lsp_provider")
    local ns = vim.api.nvim_create_namespace("tend_lsp_provider_test")
    local scratch = {}

    local function make_file_buffer(lines)
        -- A uniquely-named, loaded, file-backed buffer so uri_from_bufnr and
        -- uri_to_bufnr round-trip to the same buffer.
        local path = vim.fn.tempname() .. ".lua"
        local bufnr = vim.fn.bufadd(path)
        vim.fn.bufload(bufnr)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines or {})
        table.insert(scratch, bufnr)
        return bufnr, vim.uri_from_bufnr(bufnr)
    end

    after_each(function()
        for _, b in ipairs(scratch) do
            vim.diagnostic.reset(ns, b)
            if vim.api.nvim_buf_is_valid(b) then
                vim.api.nvim_buf_delete(b, { force = true })
            end
        end
        scratch = {}
    end)

    it("current_buffer reports empty for a special (no-file) buffer", function()
        local prov = LspProviderMod.LspProvider.new()
        local buf = vim.api.nvim_create_buf(false, true) -- scratch, buftype=nofile
        table.insert(scratch, buf)
        vim.api.nvim_set_current_buf(buf)
        assert.equal("", prov:current_buffer().uri)
    end)

    it("current_buffer reports the URI of a file-backed buffer", function()
        local prov = LspProviderMod.LspProvider.new()
        local buf, uri = make_file_buffer({ "local x = 1" })
        vim.api.nvim_set_current_buf(buf)
        assert.equal(uri, prov:current_buffer().uri)
    end)

    it("diagnostics reports open=false for an unloaded file", function()
        local prov = LspProviderMod.LspProvider.new()
        local res = prov:diagnostics("file:///no/such/file/here.lua")
        assert.is_false(res.open)
        assert.same({}, res.diagnostics)
    end)

    it("diagnostics maps a set diagnostic from an open buffer", function()
        local prov = LspProviderMod.LspProvider.new()
        local buf, uri = make_file_buffer({ "local x = undefined_name" })
        vim.diagnostic.set(ns, buf, {
            {
                lnum = 0,
                col = 10,
                end_lnum = 0,
                end_col = 24,
                severity = vim.diagnostic.severity.ERROR,
                message = "undefined global",
                source = "lua_ls",
            },
        })
        local res = prov:diagnostics(uri)
        assert.is_true(res.open)
        assert.equal(1, #res.diagnostics)
        assert.equal("error", res.diagnostics[1].severity)
        assert.equal("undefined global", res.diagnostics[1].message)
        assert.equal(10, res.diagnostics[1].range.start.byte_col)
    end)
end)
