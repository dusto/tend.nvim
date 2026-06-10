local assert = require("tests.helpers.assert")

describe("tend.approval.model", function()
    --- @type tend.approval.Model
    local Model = require("tend.approval.model")

    --- @param id string
    --- @param kind string|nil
    --- @return tend.approval.Approval
    local function appr(id, kind)
        return {
            approval_id = id,
            session_id = "ses-1",
            kind = kind or "file_edit",
            detail = {},
        }
    end

    --- @return tend.approval.Model
    local function with_three()
        local m = Model.new()
        m:add(appr("a1"))
        m:add(appr("a2"))
        m:add(appr("a3"))
        return m
    end

    it("adds in arrival order and dedupes by approval_id", function()
        local m = Model.new()
        assert.is_true(m:add(appr("a1")))
        assert.is_true(m:add(appr("a2")))
        assert.is_false(m:add(appr("a1")))
        assert.same({ "a1", "a2" }, m:ids())
        assert.equal(2, m:count())
        assert.equal("a2", m:get("a2").approval_id)
    end)

    it("focuses the first pending approval by default", function()
        local m = with_three()
        assert.equal("a1", m:focused().approval_id)
        assert.equal(1, m:focused_index())
    end)

    it("cycles focus with wrap in both directions", function()
        local m = with_three()
        m:cycle(1)
        assert.equal("a2", m:focused().approval_id)
        m:cycle(1)
        m:cycle(1)
        assert.equal("a1", m:focused().approval_id)
        m:cycle(-1)
        assert.equal("a3", m:focused().approval_id)
    end)

    it("cycle is a no-op when empty", function()
        local m = Model.new()
        m:cycle(1)
        assert.is_nil(m:focused())
        assert.equal(0, m:focused_index())
    end)

    it(
        "keeps focus on the same approval when an earlier one resolves",
        function()
            local m = with_three()
            m:cycle(1) -- focus a2
            local removed = m:resolve("a1") --[[@as tend.approval.Approval]]
            assert.equal("a1", removed.approval_id)
            assert.equal("a2", m:focused().approval_id)
            assert.equal(2, m:count())
        end
    )

    it(
        "moves focus to the next pending when the focused approval resolves",
        function()
            local m = with_three()
            m:cycle(1) -- focus a2
            m:resolve("a2")
            assert.equal("a3", m:focused().approval_id)
        end
    )

    it(
        "clamps focus to the new last when the focused last approval resolves",
        function()
            local m = with_three()
            m:cycle(-1) -- focus a3
            m:resolve("a3")
            assert.equal("a2", m:focused().approval_id)
        end
    )

    it("resolve returns nil for an unknown id", function()
        local m = with_three()
        assert.is_nil(m:resolve("zz"))
        assert.equal(3, m:count())
    end)

    it("replace keeps focus by id when it survives", function()
        local m = with_three()
        m:cycle(1) -- focus a2
        m:replace({ appr("a2"), appr("a4") })
        assert.same({ "a2", "a4" }, m:ids())
        assert.equal("a2", m:focused().approval_id)
    end)

    it("replace resets focus when the focused approval is gone", function()
        local m = with_three()
        m:cycle(1) -- focus a2
        m:replace({ appr("a4"), appr("a5") })
        assert.equal("a4", m:focused().approval_id)
        assert.equal(1, m:focused_index())
    end)

    it("replace with an empty list empties the model", function()
        local m = with_three()
        m:replace({})
        assert.equal(0, m:count())
        assert.is_nil(m:focused())
        assert.same({}, m:ids())
    end)
end)
