local assert = require("tests.helpers.assert")

-- These tests exist to force LuaLS type checking and Selene linting on
-- PartialUserConfig usage. They are NOT testing runtime config behavior --
-- they validate that the (partial) type annotations allow incomplete
-- nested tables without triggering type errors or lint warnings.
describe("config_default", function()
    describe("tend.PartialUserConfig type", function()
        it("accepts a partial top-level config without warnings", function()
            --- @type tend.PartialUserConfig
            local cfg = {
                debug = true,
            }

            assert.equal(true, cfg.debug)
        end)

        it("accepts partial nested windows config", function()
            --- @type tend.PartialUserConfig
            local cfg = {
                windows = {
                    width = "50%",
                    position = "left",
                },
            }

            assert.equal("50%", cfg.windows.width)
            assert.equal("left", cfg.windows.position)
        end)

        it("accepts partial nested sub-window config", function()
            --- @type tend.PartialUserConfig
            local cfg = {
                windows = {
                    input = { height = 20 },
                    todos = { display = false },
                },
            }

            assert.equal(20, cfg.windows.input.height)
            assert.equal(false, cfg.windows.todos.display)
        end)

        it("accepts partial icon overrides", function()
            --- @type tend.PartialUserConfig
            local cfg = {
                status_icons = { pending = "?" },
                chat_icons = { user = "U" },
            }

            assert.equal("?", cfg.status_icons.pending)
            assert.equal("U", cfg.chat_icons.user)
        end)

        it("accepts partial keymaps", function()
            --- @type tend.PartialUserConfig
            local cfg = {
                keymaps = {
                    widget = { close = "x" },
                },
            }

            assert.equal("x", cfg.keymaps.widget.close)
        end)

        it("accepts partial diff_preview", function()
            --- @type tend.PartialUserConfig
            local cfg = {
                diff_preview = { enabled = false },
            }

            assert.equal(false, cfg.diff_preview.enabled)
        end)

        it("accepts partial tool call title config", function()
            --- @type tend.PartialUserConfig
            local cfg = {
                tool_calls = {
                    title = {
                        max_length = 80,
                        truncate_title_kinds = { "execute", "fetch" },
                    },
                },
            }

            assert.equal(80, cfg.tool_calls.title.max_length)
            assert.equal(
                "execute",
                cfg.tool_calls.title.truncate_title_kinds[1]
            )
        end)

        it("accepts partial settings", function()
            --- @type tend.PartialUserConfig
            local cfg = {
                settings = { move_cursor_to_chat_on_submit = false },
            }

            assert.equal(false, cfg.settings.move_cursor_to_chat_on_submit)
        end)

        it("accepts an empty config", function()
            --- @type tend.PartialUserConfig
            local cfg = {}

            assert.is_table(cfg)
        end)
    end)
end)
