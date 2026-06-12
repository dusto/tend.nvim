local assert = require("tests.helpers.assert")

describe("tend.persona.frontmatter", function()
    local Frontmatter = require("tend.persona.frontmatter")

    it("parses name and description scalars and returns the body", function()
        local meta, body = Frontmatter.parse(table.concat({
            "---",
            "name: Code Reviewer",
            "description: Reviews diffs for bugs",
            "---",
            "You are a careful reviewer.",
        }, "\n"))
        assert.equal("Code Reviewer", meta.name)
        assert.equal("Reviews diffs for bugs", meta.description)
        assert.equal("You are a careful reviewer.", body)
    end)

    it("strips matching quotes from values", function()
        local meta = Frontmatter.parse(table.concat({
            "---",
            'name: "Quoted Name"',
            "description: 'single quoted'",
            "---",
            "body",
        }, "\n"))
        assert.equal("Quoted Name", meta.name)
        assert.equal("single quoted", meta.description)
    end)

    it("treats text without frontmatter as all body", function()
        local meta, body = Frontmatter.parse("just a prompt\nwith lines")
        assert.same({}, meta)
        assert.equal("just a prompt\nwith lines", body)
    end)

    it("treats an unterminated frontmatter block as all body", function()
        local meta, body =
            Frontmatter.parse("---\nname: broken\nno closing delimiter")
        assert.same({}, meta)
        assert.equal("---\nname: broken\nno closing delimiter", body)
    end)

    it("ignores non-scalar frontmatter lines", function()
        local meta = Frontmatter.parse(table.concat({
            "---",
            "name: reviewer",
            "tools:",
            "  - read",
            "  - grep",
            "model: opus",
            "---",
            "body",
        }, "\n"))
        assert.equal("reviewer", meta.name)
        assert.equal("opus", meta.model)
        assert.is_nil(meta["- read"])
        assert.is_nil(meta.tools)
    end)

    it("drops blank lines between the delimiter and the body", function()
        local _, body = Frontmatter.parse(table.concat({
            "---",
            "name: x",
            "---",
            "",
            "",
            "the body",
        }, "\n"))
        assert.equal("the body", body)
    end)
end)
