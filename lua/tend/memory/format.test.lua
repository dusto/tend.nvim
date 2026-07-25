local assert = require("tests.helpers.assert")

describe("tend.memory.format", function()
    local Format = require("tend.memory.format")

    describe("hit_label", function()
        it("renders title, kind, tags, and snippet", function()
            local label = Format.hit_label({
                id = "m1",
                title = "Auth flow",
                kind = "note",
                tags = { "auth", "api" },
                snippet = "the token is refreshed on 401",
            })
            assert.is_not_nil(label:find("Auth flow", 1, true))
            assert.is_not_nil(label:find("[note]", 1, true))
            assert.is_not_nil(label:find("#auth #api", 1, true))
            assert.is_not_nil(
                label:find("the token is refreshed on 401", 1, true)
            )
        end)

        it("falls back to (untitled) and omits empty parts", function()
            local label = Format.hit_label({ id = "m2", snippet = "" })
            assert.equal("(untitled)", label)
        end)
    end)

    describe("entry_lines", function()
        it("starts with a title heading and includes the body", function()
            local lines = Format.entry_lines({
                id = "m1",
                title = "Auth flow",
                kind = "note",
                tags = { "auth" },
                task = { id = "t-9" },
                text = "line one\nline two",
            })
            assert.equal("# Auth flow", lines[1])
            local joined = table.concat(lines, "\n")
            assert.is_not_nil(joined:find("`note`", 1, true))
            assert.is_not_nil(joined:find("#auth", 1, true))
            assert.is_not_nil(joined:find("task: t-9", 1, true))
            assert.is_not_nil(joined:find("line one", 1, true))
            assert.is_not_nil(joined:find("line two", 1, true))
        end)

        it("defaults kind to note and splits a multi-line body", function()
            local lines = Format.entry_lines({
                id = "m3",
                text = "a\nb\nc",
            })
            assert.equal("# (untitled)", lines[1])
            assert.is_not_nil(table.concat(lines, "\n"):find("`note`", 1, true))
            -- Each body line is its own entry, not one concatenated line.
            assert.equal("a", lines[#lines - 2])
            assert.equal("b", lines[#lines - 1])
            assert.equal("c", lines[#lines])
        end)
    end)
end)
