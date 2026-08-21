local assert = require("tests.helpers.assert")

describe("tend.approval.render", function()
    local Render = require("tend.approval.render")

    it(
        "renders a file_edit with prompt, expiry, target base, and diff",
        function()
            local lines, marks = Render.render({
                approval_id = "ap-1",
                session_id = "ses-1",
                kind = "file_edit",
                prompt = "Agent wants to edit main.go",
                expires_at = "2026-06-09T12:00:00Z",
                detail = {
                    change_set_id = "cs-1",
                    targets = {
                        {
                            uri = "file:///repo/main.go",
                            base = { changedtick = 42 },
                            diff = "--- a/main.go\n+++ b/main.go\n"
                                .. "@@ -1,2 +1,2 @@\n-old\n+new",
                        },
                    },
                },
            })
            assert.same({
                "file_edit · session ses-1",
                "Agent wants to edit main.go",
                "expires 2026-06-09T12:00:00Z",
                "",
                "── file:///repo/main.go · base changedtick 42",
                "--- a/main.go",
                "+++ b/main.go",
                "@@ -1,2 +1,2 @@",
                "-old",
                "+new",
            }, lines)
            assert.same({
                { row = 0, group = "Title" },
                { row = 2, group = "Comment" },
                { row = 4, group = "Directory" },
                { row = 5, group = "Title" },
                { row = 6, group = "Title" },
                { row = 7, group = "Changed" },
                { row = 8, group = "Removed" },
                { row = 9, group = "Added" },
            }, marks)
        end
    )

    it("renders every target of a multi-file edit", function()
        local lines = Render.render({
            approval_id = "ap-1",
            session_id = "ses-1",
            kind = "file_edit",
            detail = {
                change_set_id = "cs-1",
                targets = {
                    { uri = "a.go", base = { changedtick = 1 }, diff = "+a" },
                    {
                        uri = "b.go",
                        base = { content_hash = "deadbeefcafe1234567890" },
                        diff = "+b",
                    },
                },
            },
        })
        assert.same({
            "file_edit · session ses-1",
            "",
            "── a.go · base changedtick 1",
            "+a",
            "── b.go · base deadbeefcafe",
            "+b",
        }, lines)
    end)

    it("renders a pane_run command with cwd, env, and pane", function()
        local lines, marks = Render.render({
            approval_id = "ap-2",
            session_id = "ses-1",
            kind = "pane_run",
            detail = {
                pane_id = "pn-1",
                command = "make test",
                cwd = "/repo",
                env = { "CI=1", "DEBUG=0" },
            },
        })
        assert.same({
            "pane_run · session ses-1",
            "",
            "command: make test",
            "cwd: /repo",
            "env: CI=1 DEBUG=0",
            "pane: pn-1",
        }, lines)
        assert.same({ { row = 0, group = "Title" } }, marks)
    end)

    it("renders a pane_open cwd and workspace", function()
        local lines = Render.render({
            approval_id = "ap-3",
            session_id = "ses-1",
            kind = "pane_open",
            detail = { cwd = "/repo", workspace_id = "ws-1" },
        })
        assert.same({
            "pane_open · session ses-1",
            "",
            "cwd: /repo",
            "workspace: ws-1",
        }, lines)
    end)

    it("renders a filesystem_access read as access, not a diff", function()
        local lines, marks = Render.render({
            approval_id = "ap-fs",
            session_id = "ses-1",
            kind = "filesystem_access",
            detail = {
                requested_uri = "file:///etc/hosts",
                resolved_path = "/etc/hosts",
                mode = "read",
                tool = "file.read",
            },
        })
        assert.same({
            "filesystem_access · session ses-1",
            "",
            "Allow this session to read /etc/hosts?",
            "outside the worktree",
            "tool: file.read",
        }, lines)
        assert.same({
            { row = 0, group = "Title" },
            { row = 3, group = "WarningMsg" },
        }, marks)
    end)

    it(
        "renders a diagnostics read and surfaces a symlinked requested uri",
        function()
            local lines = Render.render({
                approval_id = "ap-fs2",
                session_id = "ses-1",
                kind = "filesystem_access",
                detail = {
                    requested_uri = "file:///repo/link/file.go",
                    resolved_path = "/other-repo/file.go",
                    mode = "diagnostics",
                    tool = "lsp.diagnostics",
                },
            })
            assert.same({
                "filesystem_access · session ses-1",
                "",
                "Allow this session to read diagnostics for /other-repo/file.go?",
                "outside the worktree",
                "requested: file:///repo/link/file.go",
                "tool: lsp.diagnostics",
            }, lines)
        end
    )

    it("renders a code_action title and file", function()
        local lines = Render.render({
            approval_id = "ap-4",
            session_id = "ses-1",
            kind = "code_action",
            detail = { title = "Organize imports", uri = "file:///x.go" },
        })
        assert.same({
            "code_action · session ses-1",
            "",
            "action: Organize imports",
            "file: file:///x.go",
        }, lines)
    end)

    it("splits a multi-line prompt into display lines", function()
        local lines = Render.render({
            approval_id = "ap-5",
            session_id = "ses-1",
            kind = "pane_open",
            prompt = "line one\nline two",
            detail = { cwd = "/repo" },
        })
        assert.same({
            "pane_open · session ses-1",
            "line one",
            "line two",
            "",
            "cwd: /repo",
        }, lines)
    end)

    it("falls back when the decision context is missing", function()
        local lines = Render.render({
            approval_id = "ap-6",
            session_id = "ses-1",
            kind = "mystery",
        })
        assert.same({
            "mystery · session ses-1",
            "",
            "(no decision context)",
        }, lines)
    end)
end)
