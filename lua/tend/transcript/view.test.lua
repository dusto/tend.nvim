local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")

-- The view drives nvim_buf_set_lines, so it runs in a child Neovim process; the
-- parent reads the buffer back over RPC and asserts on it.
describe("tend.transcript.view", function()
    local child = Child.new()

    before_each(function()
        child.setup()
        child.lua([[
            local View = require("tend.transcript.view")
            -- Deterministic renderer: one line per event/summary.
            local function render(event)
                if event.kind == "summary" then
                    local info = event.summary
                    return { "S" .. info.from_seq .. "-" .. info.to_seq }
                end
                return { event.seq .. ":" .. (event.payload.text or "") }
            end
            _G.buf = vim.api.nvim_create_buf(false, true)
            _G.view = View.new(_G.buf, { render = render })
            _G.ev = function(seq, text)
                return {
                    kind = "event",
                    type = "agent_message_chunk",
                    seq = seq,
                    cursor_seq = seq,
                    payload = { text = text or "x" },
                }
            end
            _G.summary = function(from, to)
                return {
                    kind = "summary",
                    type = "summary",
                    seq = from,
                    cursor_seq = to,
                    summary = { from_seq = from, to_seq = to },
                    payload = {},
                }
            end
        ]])
    end)

    after_each(function()
        child.stop()
    end)

    local function buf_lines()
        return child.lua_get("vim.api.nvim_buf_get_lines(_G.buf, 0, -1, false)")
    end

    it(
        "renders appended events into the buffer with no phantom line",
        function()
            child.lua([[
            _G.view:apply(_G.ev(1, "a"))
            _G.view:apply(_G.ev(2, "b"))
        ]])
            assert.same(buf_lines(), { "1:a", "2:b" })
        end
    )

    it("collapses a summary range in place", function()
        child.lua([[
            for s = 1, 4 do _G.view:apply(_G.ev(s)) end
            _G.view:apply(_G.summary(2, 3))
            _G.view:apply(_G.ev(5))
        ]])
        assert.same(buf_lines(), { "1:x", "S2-3", "4:x", "5:x" })
    end)

    it("keeps the buffer in sync across a multi-line edit", function()
        child.lua([[
            local View = require("tend.transcript.view")
            _G.mbuf = vim.api.nvim_create_buf(false, true)
            _G.mview = View.new(_G.mbuf, {
                render = function(e)
                    if e.kind == "summary" then return { "SUM" } end
                    return vim.split(e.payload.text, "\n", { plain = true })
                end,
            })
            _G.mview:apply(_G.ev(1, "a\nb"))
            _G.mview:apply(_G.ev(2, "c"))
            _G.mview:apply(_G.summary(1, 2))
        ]])
        assert.same(
            child.lua_get("vim.api.nvim_buf_get_lines(_G.mbuf, 0, -1, false)"),
            { "SUM" }
        )
    end)

    it("strands no phantom line after a hidden first event", function()
        child.lua([[
            local View = require("tend.transcript.view")
            _G.hbuf = vim.api.nvim_create_buf(false, true)
            -- A renderer where turn_end is hidden (renders no lines).
            _G.hview = View.new(_G.hbuf, {
                render = function(e)
                    if e.type == "turn_end" then return {} end
                    return { e.seq .. ":" .. (e.payload.text or "") }
                end,
            })
            _G.hview:apply({
                kind = "event",
                type = "turn_end",
                seq = 1,
                cursor_seq = 1,
                payload = {},
            })
            _G.hview:apply(_G.ev(2, "hello"))
        ]])
        assert.same(
            child.lua_get("vim.api.nvim_buf_get_lines(_G.hbuf, 0, -1, false)"),
            { "2:hello" }
        )
    end)

    it("restores a non-modifiable buffer after writing", function()
        child.lua([[
            vim.bo[_G.buf].modifiable = false
            _G.view:apply(_G.ev(1, "a"))
        ]])
        assert.same(buf_lines(), { "1:a" })
        assert.is_false(child.lua_get("vim.bo[_G.buf].modifiable"))
    end)
end)
