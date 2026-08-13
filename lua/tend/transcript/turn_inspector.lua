--- Renders one turn's full detail (48d.36 layer 3) as a markdown document with
--- headed sections — Prompt, Context, Tokens, Tools & MCP — so a float can show
--- it with native markdown-heading folds. Pure: a turn record in, display lines
--- out; the float and keymap wiring live elsewhere.
local Usage = require("tend.session.usage")

local M = {}

--- Render a turn record as markdown display lines. Every section is always
--- present (with a placeholder when empty) so the folded layout is stable across
--- turns.
--- @param record tend.transcript.TurnRecord|nil
--- @return string[] lines
function M.render(record)
    record = record or { tools = {} }
    --- @type string[]
    local lines = {}
    local function add(s)
        table.insert(lines, s)
    end
    local function section(title)
        if #lines > 0 then
            add("")
        end
        add("## " .. title)
    end

    section("Prompt")
    local prompt = record.prompt
    if prompt and prompt.text and prompt.text ~= "" then
        for _, l in ipairs(vim.split(prompt.text, "\n", { plain = true })) do
            add(l)
        end
    else
        add("_(no prompt text)_")
    end
    if prompt and (prompt.attachments or 0) > 0 then
        add(("Attachments: %d"):format(prompt.attachments))
    end
    local est = record.prompt_usage
    if est then
        add(
            ("Estimated: ~%s tokens · %s bytes"):format(
                Usage.humanize(est.tokens_approx),
                Usage.humanize(est.text_bytes)
            )
        )
    end

    section("Context")
    local ctx = record.context
    if ctx then
        local used = ctx.used_tokens or 0
        local window = ctx.window_tokens or 0
        local line = "Window: " .. Usage.humanize(used)
        if window > 0 then
            local pct = math.floor((used / window) * 100 + 0.5)
            line = line .. (" / %s (~%d%%)"):format(Usage.humanize(window), pct)
        end
        add(line)
        if ctx.cost and ctx.cost.amount then
            add(
                ("Cost: %.2f %s"):format(
                    ctx.cost.amount,
                    ctx.cost.currency or ""
                )
            )
        end
    else
        add("_(not reported)_")
    end

    section("Tokens")
    local tokens = record.tokens
    if tokens then
        add(
            ("In %s · Out %s · Total %s"):format(
                Usage.humanize(tokens.input_tokens),
                Usage.humanize(tokens.output_tokens),
                Usage.humanize(tokens.total_tokens)
            )
        )
        if (tokens.cached_read_tokens or 0) > 0 then
            add("Cached read: " .. Usage.humanize(tokens.cached_read_tokens))
        end
        if (tokens.reasoning_tokens or 0) > 0 then
            add("Reasoning: " .. Usage.humanize(tokens.reasoning_tokens))
        end
    else
        add("_(not reported)_")
    end

    section("Tools & MCP")
    local tools = record.tools or {}
    if #tools > 0 then
        for _, tc in ipairs(tools) do
            add(
                ("- %s — %s"):format(
                    tc.name or tc.id or "?",
                    tc.status or "?"
                )
            )
        end
    else
        add("_(none)_")
    end

    return lines
end

return M
