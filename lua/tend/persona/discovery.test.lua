local assert = require("tests.helpers.assert")

describe("tend.persona.discovery", function()
    local Discovery = require("tend.persona.discovery")

    --- @type string
    local root

    --- @param rel string
    --- @param lines string[]
    local function write(rel, lines)
        local path = root .. "/" .. rel
        vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
        vim.fn.writefile(lines, path)
    end

    before_each(function()
        root = vim.fn.tempname()
        vim.fn.mkdir(root, "p")
    end)

    after_each(function()
        vim.fn.delete(root, "rf")
    end)

    it("discovers user personas with stem ids and file bodies", function()
        write("user/reviewer.md", { "Review code carefully." })
        local personas = Discovery.discover({ user_dirs = { root .. "/user" } })
        assert.equal(1, #personas)
        assert.equal("reviewer", personas[1].id)
        assert.equal("reviewer", personas[1].name)
        assert.equal("user", personas[1].source)
        assert.is_false(personas[1].imported)
        assert.equal("Review code carefully.", personas[1].prompt)
    end)

    it("honors frontmatter name and description", function()
        write("user/reviewer.md", {
            "---",
            "name: Code Reviewer",
            "description: Reviews diffs",
            "---",
            "You review code.",
        })
        local personas = Discovery.discover({ user_dirs = { root .. "/user" } })
        assert.equal("Code Reviewer", personas[1].name)
        assert.equal("Reviews diffs", personas[1].description)
        assert.equal("You review code.", personas[1].prompt)
    end)

    it("discovers workspace personas under .tend/personas", function()
        write(".tend/personas/planner.md", { "Plan the work." })
        local personas = Discovery.discover({ workspace_root = root })
        assert.equal(1, #personas)
        assert.equal("planner", personas[1].id)
        assert.equal("workspace", personas[1].source)
        assert.is_false(personas[1].imported)
    end)

    it("imports harness agents with namespaced ids", function()
        write(".claude/agents/reviewer.md", {
            "---",
            "name: reviewer",
            "description: PR review agent",
            "---",
            "Review the diff.",
        })
        local personas = Discovery.discover({ workspace_root = root })
        assert.equal(1, #personas)
        assert.equal("claude:reviewer", personas[1].id)
        assert.equal("claude", personas[1].source)
        assert.is_true(personas[1].imported)
        assert.equal("PR review agent", personas[1].description)
        assert.equal("Review the diff.", personas[1].prompt)
    end)

    it("dedupes by stem: workspace shadows imported shadows user", function()
        write("user/reviewer.md", { "user version" })
        write("user/helper.md", { "user helper" })
        write(".claude/agents/reviewer.md", { "imported version" })
        write(".claude/agents/planner.md", { "imported planner" })
        write(".tend/personas/reviewer.md", { "workspace version" })
        local personas = Discovery.discover({
            user_dirs = { root .. "/user" },
            workspace_root = root,
        })
        local by_id = {}
        for _, p in ipairs(personas) do
            by_id[p.id] = p
        end
        assert.equal(3, #personas)
        assert.equal("workspace version", by_id["reviewer"].prompt)
        assert.equal("imported planner", by_id["claude:planner"].prompt)
        assert.equal("user helper", by_id["helper"].prompt)
        assert.is_nil(by_id["claude:reviewer"])
    end)

    it("keeps same-stem agents from different import sources", function()
        write(".claude/agents/reviewer.md", { "claude reviewer" })
        write(".opencode/agent/reviewer.md", { "opencode reviewer" })
        write("user/reviewer.md", { "user reviewer" })
        local personas = Discovery.discover({
            user_dirs = { root .. "/user" },
            workspace_root = root,
        })
        local by_id = {}
        for _, p in ipairs(personas) do
            by_id[p.id] = p.prompt
        end
        -- Namespacing exists so harnesses cannot collide; both survive. The
        -- user persona on the same stem is still shadowed by the imports.
        assert.equal(2, #personas)
        assert.equal("claude reviewer", by_id["claude:reviewer"])
        assert.equal("opencode reviewer", by_id["opencode:reviewer"])
        assert.is_nil(by_id["reviewer"])
    end)

    it("dedupes the same stem across user dirs, first dir winning", function()
        write("user-a/helper.md", { "from a" })
        write("user-b/helper.md", { "from b" })
        local personas = Discovery.discover({
            user_dirs = { root .. "/user-a", root .. "/user-b" },
        })
        assert.equal(1, #personas)
        assert.equal("from a", personas[1].prompt)
    end)

    it("orders tiers workspace, imported, user", function()
        write("user/zeta.md", { "u" })
        write(".claude/agents/alpha.md", { "i" })
        write(".tend/personas/omega.md", { "w" })
        local personas = Discovery.discover({
            user_dirs = { root .. "/user" },
            workspace_root = root,
        })
        assert.same(
            { "omega", "claude:alpha", "zeta" },
            vim.tbl_map(function(p)
                return p.id
            end, personas)
        )
    end)

    it("respects custom import sources", function()
        write("custom/agents/bot.md", { "custom bot" })
        local personas = Discovery.discover({
            workspace_root = root,
            sources = { { source = "x", dir = "custom/agents" } },
        })
        assert.equal(1, #personas)
        assert.equal("x:bot", personas[1].id)
        assert.equal("x", personas[1].source)
    end)

    it("returns empty for missing dirs and no workspace", function()
        local personas = Discovery.discover({
            user_dirs = { root .. "/nope" },
        })
        assert.same({}, personas)
    end)
end)
