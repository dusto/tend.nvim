local assert = require("tests.helpers.assert")

describe("tend.session.usage", function()
    local Usage = require("tend.session.usage")

    local function ev(type_, payload)
        return { type = type_, payload = payload }
    end

    describe("humanize", function()
        it("passes through small counts and groups thousands", function()
            assert.equal("0", Usage.humanize(0))
            assert.equal("999", Usage.humanize(999))
            assert.equal("1,234", Usage.humanize(1234))
            assert.equal("9,999", Usage.humanize(9999))
        end)

        it("abbreviates thousands and millions", function()
            assert.equal("18.2k", Usage.humanize(18240))
            assert.equal("200.0k", Usage.humanize(200000))
            assert.equal("2.0M", Usage.humanize(2000000))
        end)

        it("treats nil as zero", function()
            assert.equal("0", Usage.humanize(nil))
        end)
    end)

    describe("apply", function()
        it("records the prompt estimate", function()
            local u = Usage.Usage.new()
            assert.is_true(u:apply(ev("agent_prompt_usage", {
                text_bytes = 4900,
                tokens_approx = 1180,
            })))
            assert.equal(1180, u.prompt.tokens_approx)
        end)

        it("records context-window fullness", function()
            local u = Usage.Usage.new()
            u:apply(ev("agent_context_usage", {
                used_tokens = 18240,
                window_tokens = 200000,
            }))
            assert.equal(18240, u.context.used_tokens)
        end)

        it("sums authoritative token usage across turns", function()
            local u = Usage.Usage.new()
            u:apply(ev("agent_token_usage", {
                input_tokens = 1000,
                output_tokens = 200,
                total_tokens = 1200,
            }))
            u:apply(ev("agent_token_usage", {
                input_tokens = 500,
                output_tokens = 100,
                total_tokens = 620,
            }))
            assert.equal(2, u.turns)
            assert.equal(1500, u.total_input)
            assert.equal(300, u.total_output)
            assert.equal(1820, u.total_tokens)
            assert.equal(620, u.last_turn.total_tokens)
        end)

        it("ignores unrelated and malformed events", function()
            local u = Usage.Usage.new()
            assert.is_false(u:apply(ev("agent_plan", {})))
            --- @diagnostic disable-next-line: param-type-mismatch
            assert.is_false(u:apply("nope"))
            assert.is_true(u:is_empty())
        end)
    end)

    describe("render_lines", function()
        local header = {
            session_id = "sess-1",
            provider_id = "claude",
            model_id = "sonnet",
            task = "auth-refactor",
            status = "running",
        }

        it("shows a not-yet line when empty", function()
            local lines = Usage.render_lines(Usage.Usage.new(), header)
            assert.equal("# auth-refactor", lines[1])
            assert.equal("claude · sonnet · running", lines[2])
            assert.truthy(
                table.concat(lines, "\n"):find("No usage reported yet", 1, true)
            )
        end)

        it(
            "renders context, last turn, session total, and approx prompt",
            function()
                local u = Usage.Usage.new()
                u:apply(ev("agent_context_usage", {
                    used_tokens = 18240,
                    window_tokens = 200000,
                }))
                u:apply(ev("agent_token_usage", {
                    input_tokens = 1240,
                    output_tokens = 380,
                    total_tokens = 1620,
                }))
                u:apply(ev("agent_prompt_usage", {
                    text_bytes = 4900,
                    tokens_approx = 1180,
                }))
                local text = table.concat(Usage.render_lines(u, header), "\n")
                assert.truthy(
                    text:find("Context window: 18.2k / 200.0k  (~9%)", 1, true)
                )
                assert.truthy(
                    text:find(
                        "Last turn: 1,240 in · 380 out · 1,620 total",
                        1,
                        true
                    )
                )
                assert.truthy(
                    text:find(
                        "Session total: 1,620 tokens across 1 turn",
                        1,
                        true
                    )
                )
                assert.truthy(
                    text:find("Prompt (composed): ~1,180 tokens", 1, true)
                )
                assert.truthy(text:find("[approx]", 1, true))
            end
        )

        it(
            "omits the context percent when the window size is unknown",
            function()
                local u = Usage.Usage.new()
                u:apply(ev("agent_context_usage", {
                    used_tokens = 500,
                    window_tokens = 0,
                }))
                local text = table.concat(Usage.render_lines(u, header), "\n")
                assert.truthy(text:find("Context window: 500", 1, true))
                assert.is_nil(text:find("%", 1, true))
            end
        )

        it("shows cost when the provider reports it", function()
            local u = Usage.Usage.new()
            u:apply(ev("agent_context_usage", {
                used_tokens = 10,
                window_tokens = 100,
                cost = { amount = 0.42, currency = "USD" },
            }))
            local text = table.concat(Usage.render_lines(u, header), "\n")
            assert.truthy(text:find("Cost: 0.42 USD", 1, true))
        end)

        it("falls back to the session id when no label or task", function()
            local lines = Usage.render_lines(Usage.Usage.new(), {
                session_id = "sess-9",
                provider_id = "codex",
            })
            assert.equal("# sess-9", lines[1])
            assert.equal("Task: none", lines[3])
        end)
    end)

    describe("render_turn_annotation", function()
        it("returns nil when no authoritative turn tokens yet", function()
            local u = Usage.Usage.new()
            assert.is_nil(Usage.render_turn_annotation(u))
            -- A prompt estimate alone is not an authoritative turn.
            u:apply(ev("agent_prompt_usage", { tokens_approx = 100 }))
            assert.is_nil(Usage.render_turn_annotation(u))
        end)

        it("renders up/down tokens for the last turn", function()
            local u = Usage.Usage.new()
            u:apply(ev("agent_token_usage", {
                input_tokens = 1200,
                output_tokens = 18240,
                total_tokens = 19440,
            }))
            local a = Usage.render_turn_annotation(u)
            assert.is_not_nil(a)
            --- @cast a string
            assert.is_not_nil(a:find("1,200", 1, true))
            assert.is_not_nil(a:find("18.2k", 1, true))
        end)

        it("appends context-window percent when the window is known", function()
            local u = Usage.Usage.new()
            u:apply(ev("agent_token_usage", {
                input_tokens = 10,
                output_tokens = 20,
                total_tokens = 30,
            }))
            u:apply(ev("agent_context_usage", {
                used_tokens = 18000,
                window_tokens = 100000,
            }))
            assert.is_not_nil(
                Usage.render_turn_annotation(u):find("18%", 1, true)
            )
        end)

        it("omits context percent when the window is unknown", function()
            local u = Usage.Usage.new()
            u:apply(ev("agent_token_usage", {
                input_tokens = 10,
                output_tokens = 20,
                total_tokens = 30,
            }))
            u:apply(ev("agent_context_usage", {
                used_tokens = 18000,
                window_tokens = 0,
            }))
            assert.is_nil(Usage.render_turn_annotation(u):find("ctx", 1, true))
        end)
    end)
end)
