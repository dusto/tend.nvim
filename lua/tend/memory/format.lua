--- Pure formatters for the memory browse UI: a one-line picker label for a
--- search hit, and the float body (markdown) for a full entry. No side effects,
--- so these are unit-tested directly without a child Neovim.
--- @class tend.memory.Format
local M = {}

--- @param s string|nil
--- @param fallback string
--- @return string
local function nonempty(s, fallback)
    if type(s) == "string" and s ~= "" then
        return s
    end
    return fallback
end

--- Tags rendered as space-separated #hashtags, or nil when there are none.
--- @param tags string[]|nil
--- @return string|nil
local function hashtags(tags)
    if type(tags) ~= "table" or #tags == 0 then
        return nil
    end
    return "#" .. table.concat(tags, " #")
end

--- A one-line picker label for a memory.search hit: title, kind, tags, then a
--- snippet of the body.
--- @param hit table api.MemoryHit
--- @return string label
function M.hit_label(hit)
    local parts = { nonempty(hit.title, "(untitled)") }
    if nonempty(hit.kind, "") ~= "" then
        table.insert(parts, "[" .. hit.kind .. "]")
    end
    local tags = hashtags(hit.tags)
    if tags then
        table.insert(parts, tags)
    end
    local label = table.concat(parts, "  ")
    if nonempty(hit.snippet, "") ~= "" then
        label = label .. "  — " .. hit.snippet
    end
    return label
end

--- The float body (markdown lines) for a full memory entry: a title heading, a
--- metadata line (kind · tags · task), then the entry body.
--- @param entry table api.MemoryEntry
--- @return string[] lines
function M.entry_lines(entry)
    --- @type string[]
    local lines = { "# " .. nonempty(entry.title, "(untitled)"), "" }

    local meta = { "`" .. nonempty(entry.kind, "note") .. "`" }
    local tags = hashtags(entry.tags)
    if tags then
        table.insert(meta, tags)
    end
    if type(entry.task) == "table" and nonempty(entry.task.id, "") ~= "" then
        table.insert(meta, "task: " .. entry.task.id)
    end
    table.insert(lines, table.concat(meta, " · "))
    table.insert(lines, "")

    vim.list_extend(
        lines,
        vim.split(nonempty(entry.text, ""), "\n", { plain = true })
    )
    return lines
end

return M
