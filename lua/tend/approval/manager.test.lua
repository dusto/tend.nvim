local assert = require("tests.helpers.assert")
local rpc = require("tend.rpc.client")

describe("tend.approval.manager", function()
    local ManagerMod = require("tend.approval.manager")

    -- A fake transport: captures every framed message the manager sends.
    local function fake_client()
        local sent = {}
        local client = rpc.Client.new({
            writer = function(data)
                table.insert(sent, vim.json.decode(vim.trim(data)))
            end,
        })
        return client, sent
    end

    -- Encode a peer->client message the way the daemon would frame it.
    local function frame(msg)
        return vim.json.encode(msg) .. "\n"
    end

    -- A view stub recording how the manager drives it.
    local function fake_view()
        return {
            shows = 0,
            refreshes = 0,
            show = function(self)
                self.shows = self.shows + 1
            end,
            refresh = function(self)
                self.refreshes = self.refreshes + 1
            end,
        }
    end

    --- @return tend.approval.Manager manager
    --- @return table view
    --- @return string[] errors
    local function new_manager()
        local view = fake_view()
        local errors = {}
        local manager = ManagerMod.Manager.new({
            view = view,
            on_error = function(msg)
                table.insert(errors, msg)
            end,
        })
        return manager, view, errors
    end

    local raise_params = {
        session_id = "ses-1",
        kind = "approval",
        approval_id = "ap-2",
        prompt = "run make?",
        expires_at = "2026-06-09T12:00:00Z",
        detail = {
            kind = "pane_run",
            pane_run = { pane_id = "pn-1", command = "make", cwd = "/repo" },
        },
    }

    -- Bootstrap a manager and complete its initial sync with the given pending
    -- summaries, returning the wired client + captured frames.
    local function bootstrapped(manager, approvals)
        local client, sent = fake_client()
        manager:bootstrap(client)
        client:feed(frame({
            jsonrpc = "2.0",
            id = sent[#sent].id,
            result = { approvals = approvals },
        }))
        return client, sent
    end

    it("bootstrap syncs pending approvals from approval.list", function()
        local manager, view = new_manager()
        local _, sent = bootstrapped(manager, {
            {
                approval_id = "ap-1",
                session_id = "ses-1",
                kind = "file_edit",
                expires_at = "2026-06-09T12:00:00Z",
                detail = {
                    kind = "file_edit",
                    file_edit = {
                        change_set_id = "cs-1",
                        targets = {
                            {
                                uri = "a.go",
                                base = { changedtick = 1 },
                                diff = "+a",
                            },
                        },
                    },
                },
            },
        })
        assert.equal(ManagerMod.METHOD_LIST, sent[1].method)
        assert.equal(1, manager.model:count())
        local focused = manager.model:focused() --[[@as table]]
        assert.equal("file_edit", focused.kind)
        assert.equal("ses-1", focused.session_id)
        assert.equal("2026-06-09T12:00:00Z", focused.expires_at)
        assert.equal("cs-1", focused.detail.change_set_id)
        assert.equal(1, view.shows)
    end)

    it("bootstrap with nothing pending refreshes instead of showing", function()
        local manager, view = new_manager()
        bootstrapped(manager, {})
        assert.equal(0, manager.model:count())
        assert.equal(0, view.shows)
        assert.equal(1, view.refreshes)
    end)

    it("prompt.raise adds the approval and shows the view", function()
        local manager, view = new_manager()
        local client = bootstrapped(manager, {})
        client:feed(frame({
            jsonrpc = "2.0",
            method = ManagerMod.METHOD_PROMPT_RAISE,
            params = raise_params,
        }))
        assert.equal(1, manager.model:count())
        local focused = manager.model:focused() --[[@as table]]
        assert.equal("ap-2", focused.approval_id)
        assert.equal("pane_run", focused.kind)
        assert.equal("run make?", focused.prompt)
        assert.equal("make", focused.detail.command)
        assert.equal(1, view.shows)
    end)

    it("ignores clarification prompts", function()
        local manager, view = new_manager()
        local client = bootstrapped(manager, {})
        client:feed(frame({
            jsonrpc = "2.0",
            method = ManagerMod.METHOD_PROMPT_RAISE,
            params = {
                session_id = "ses-1",
                kind = "clarification",
                prompt = "which file?",
            },
        }))
        assert.equal(0, manager.model:count())
        assert.equal(0, view.shows)
    end)

    it("a duplicate prompt.raise does not re-show the view", function()
        local manager, view = new_manager()
        local client = bootstrapped(manager, {})
        local raise = frame({
            jsonrpc = "2.0",
            method = ManagerMod.METHOD_PROMPT_RAISE,
            params = raise_params,
        })
        client:feed(raise)
        client:feed(raise)
        assert.equal(1, manager.model:count())
        assert.equal(1, view.shows)
    end)

    it("respond approves and clears the pending approval", function()
        local manager, view = new_manager()
        local client, sent = bootstrapped(manager, {})
        client:feed(frame({
            jsonrpc = "2.0",
            method = ManagerMod.METHOD_PROMPT_RAISE,
            params = raise_params,
        }))
        manager:respond("ap-2", true)
        local respond = sent[#sent]
        assert.equal(ManagerMod.METHOD_RESPOND, respond.method)
        assert.same({ approval_id = "ap-2", approved = true }, respond.params)
        client:feed(frame({
            jsonrpc = "2.0",
            id = respond.id,
            result = vim.empty_dict(),
        }))
        assert.equal(0, manager.model:count())
        assert.is_true(view.refreshes > 0)
    end)

    it("a respond error is reported and the pending set re-synced", function()
        local manager, _, errors = new_manager()
        local client, sent = bootstrapped(manager, {})
        client:feed(frame({
            jsonrpc = "2.0",
            method = ManagerMod.METHOD_PROMPT_RAISE,
            params = raise_params,
        }))
        manager:respond("ap-2", false)
        local respond = sent[#sent]
        client:feed(frame({
            jsonrpc = "2.0",
            id = respond.id,
            error = { code = -32000, message = "approval is stale" },
        }))
        assert.equal(1, #errors)
        assert.is_not_nil(errors[1]:find("approval is stale", 1, true))
        local resync = sent[#sent]
        assert.equal(ManagerMod.METHOD_LIST, resync.method)
        client:feed(frame({
            jsonrpc = "2.0",
            id = resync.id,
            result = { approvals = {} },
        }))
        assert.equal(0, manager.model:count())
    end)

    it("respond without a connection reports an error", function()
        local manager, _, errors = new_manager()
        manager:respond("ap-2", true)
        assert.equal(1, #errors)
    end)

    it("an approval_resolved event clears the entry", function()
        local manager, view = new_manager()
        local client = bootstrapped(manager, {})
        client:feed(frame({
            jsonrpc = "2.0",
            method = ManagerMod.METHOD_PROMPT_RAISE,
            params = raise_params,
        }))
        local refreshes = view.refreshes
        manager:handle_event({
            type = ManagerMod.EVENT_RESOLVED,
            payload = { approval_id = "ap-2", approved = false },
        })
        assert.equal(0, manager.model:count())
        assert.equal(refreshes + 1, view.refreshes)
    end)

    it("an approval_resolved event for an unknown id is ignored", function()
        local manager, view = new_manager()
        bootstrapped(manager, {})
        local refreshes = view.refreshes
        manager:handle_event({
            type = ManagerMod.EVENT_RESOLVED,
            payload = { approval_id = "zz", approved = true },
        })
        assert.equal(refreshes, view.refreshes)
    end)

    it("an approval_requested event for an unknown id syncs", function()
        local manager = new_manager()
        local _, sent = bootstrapped(manager, {})
        local before = #sent
        manager:handle_event({
            type = ManagerMod.EVENT_REQUESTED,
            payload = { approval_id = "zz", kind = "file_edit" },
        })
        assert.equal(before + 1, #sent)
        assert.equal(ManagerMod.METHOD_LIST, sent[#sent].method)
    end)

    it("sync reports the pending count to its callback", function()
        local manager = new_manager()
        local client, sent = bootstrapped(manager, {})
        local got_err, got_count
        manager:sync(function(err, count)
            got_err, got_count = err, count
        end)
        client:feed(frame({
            jsonrpc = "2.0",
            id = sent[#sent].id,
            result = {
                approvals = {
                    {
                        approval_id = "ap-1",
                        session_id = "ses-1",
                        kind = "pane_open",
                        detail = {
                            kind = "pane_open",
                            pane_open = { cwd = "/r" },
                        },
                    },
                },
            },
        }))
        assert.is_nil(got_err)
        assert.equal(1, got_count)
    end)

    it("sync reports a list error to its callback", function()
        local manager = new_manager()
        local client, sent = bootstrapped(manager, {})
        local got_err
        manager:sync(function(err)
            got_err = err
        end)
        client:feed(frame({
            jsonrpc = "2.0",
            id = sent[#sent].id,
            error = { code = -32000, message = "boom" },
        }))
        assert.is_not_nil(got_err)
        assert.is_not_nil(got_err:find("boom", 1, true))
    end)

    it("an approval_requested event for a known id does not sync", function()
        local manager = new_manager()
        local client, sent = bootstrapped(manager, {})
        client:feed(frame({
            jsonrpc = "2.0",
            method = ManagerMod.METHOD_PROMPT_RAISE,
            params = raise_params,
        }))
        local before = #sent
        manager:handle_event({
            type = ManagerMod.EVENT_REQUESTED,
            payload = { approval_id = "ap-2", kind = "pane_run" },
        })
        assert.equal(before, #sent)
    end)
end)
