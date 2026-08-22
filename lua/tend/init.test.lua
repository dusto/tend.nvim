local assert = require("tests.helpers.assert")

describe("tend init", function()
    local Tend = require("tend")

    describe("_set_plug_mappings", function()
        --- A mapping exists when maparg (dict form, so function rhs is reported)
        --- returns a non-empty table.
        --- @param lhs string
        --- @param mode string
        --- @return boolean
        local function mapped(lhs, mode)
            local m = vim.fn.maparg(lhs, mode, false, true)
            return type(m) == "table" and not vim.tbl_isempty(m)
        end

        it("defines the context-action <Plug> targets", function()
            --- @diagnostic disable-next-line: invisible
            Tend._set_plug_mappings()
            assert.is_true(mapped("<Plug>(tend-add-selection)", "x"))
            assert.is_true(mapped("<Plug>(tend-add-file)", "n"))
            assert.is_true(mapped("<Plug>(tend-add-line-diagnostics)", "n"))
            assert.is_true(mapped("<Plug>(tend-add-buffer-diagnostics)", "n"))
            assert.is_true(mapped("<Plug>(tend-stop)", "n"))
        end)
    end)
end)
