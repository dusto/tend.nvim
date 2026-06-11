--- Minimal YAML-frontmatter parsing for persona/agent definition files.
---
--- Harness agent files (and native personas) are markdown with an optional
--- frontmatter block delimited by `---` lines. Only simple `key: value`
--- scalars are read — that covers the fields the persona shape needs (name,
--- description) — and everything else (lists, nested maps, multi-line
--- scalars) is deliberately ignored: unknown or unsupported fields must not
--- break import. Text without a complete frontmatter block is all body.
local M = {}

--- Split a definition file into its frontmatter scalars and prompt body.
--- @param text string
--- @return table<string, string> meta
--- @return string body
function M.parse(text)
    local lines = vim.split(text, "\n", { plain = true })
    if lines[1] ~= "---" then
        return {}, text
    end
    local closing
    for i = 2, #lines do
        if lines[i] == "---" then
            closing = i
            break
        end
    end
    if not closing then
        return {}, text
    end

    local meta = {}
    for i = 2, closing - 1 do
        -- Scalar `key: value` lines only; lists, nested maps, and multi-line
        -- scalars fall through unparsed.
        local key, value = lines[i]:match("^([%w_-]+):%s*(.+)$")
        if key then
            local unquoted = value:match('^"(.*)"$') or value:match("^'(.*)'$")
            meta[key] = unquoted or value
        end
    end

    local body_start = closing + 1
    while lines[body_start] == "" do
        body_start = body_start + 1
    end
    return meta, table.concat(lines, "\n", body_start)
end

return M
