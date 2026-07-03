--- Compose a daemon agent.prompt content-block array from editor context.
---
--- The daemon's agent.prompt accepts a `content` array of ACP-style blocks
--- (text, resource_link, image, audio); this module turns the user's prompt plus
--- the attached context — code selections, referenced files, buffer diagnostics —
--- into that array. It is pure and daemon-shaped (snake_case fields matching the
--- daemon API), with no dependency on the legacy in-plugin ACP layer.
local FileSystem = require("tend.utils.file_system")

local M = {}

--- One agent.prompt content block, in the daemon's wire shape.
--- @class tend.PromptContentBlock
--- @field type "text"|"resource_link"|"image"|"audio"
--- @field text? string block text (type "text")
--- @field uri? string file:// URL (resource_link) or source uri (image/audio)
--- @field name? string display name (resource_link)
--- @field mime_type? string media type (image/audio)
--- @field data? string base64 bytes (image/audio)

-- Prepended once when any code selection is attached: the snippet is a line
-- range, not the whole file, so the agent must respect the given line numbers.
local SELECTION_GUIDANCE = table.concat({
    "IMPORTANT: Focus and respect the line numbers provided in the <line_start> and <line_end> tags for each <selected_code> tag.",
    "The selection shows ONLY the specified line range, not the entire file!",
    "The file may contain duplicated content of the selected snippet.",
    "When using edit tools, on the referenced files, MAKE SURE your changes target the correct lines by including sufficient surrounding context to make the match unique.",
    "After you make edits to the referenced files, go back and read the file to verify your changes were applied correctly.",
}, "\n")

--- Build a content block for a file: an image/audio block (base64 inlined) for a
--- media file, else a resource_link the provider can fetch.
--- @param path string
--- @return tend.PromptContentBlock
function M.file_block(path)
    local abs = FileSystem.to_absolute_path(path)
    local uri = "file://" .. abs
    local ext = FileSystem.get_file_extension(path)

    local image = FileSystem.IMAGE_MIMES[ext]
    if image then
        return {
            type = "image",
            mime_type = image,
            uri = uri,
            data = FileSystem.read_file_base64(abs),
        }
    end

    local audio = FileSystem.AUDIO_MIMES[ext]
    if audio then
        return {
            type = "audio",
            mime_type = audio,
            uri = uri,
            data = FileSystem.read_file_base64(abs),
        }
    end

    return {
        type = "resource_link",
        uri = uri,
        name = FileSystem.base_name(path),
    }
end

--- Build a text block for one code selection: its path, line range, and the
--- snippet with absolute line numbers.
--- @param selection tend.Selection
--- @return tend.PromptContentBlock
function M.selection_block(selection)
    local numbered = {}
    for i, line in ipairs(selection.lines) do
        table.insert(
            numbered,
            string.format("Line %d: %s", selection.start_line + i - 1, line)
        )
    end
    local text = string.format(
        table.concat({
            "<selected_code>",
            "<path>%s</path>",
            "<line_start>%s</line_start>",
            "<line_end>%s</line_end>",
            "<snippet>",
            "%s",
            "</snippet>",
            "</selected_code>",
        }, "\n"),
        FileSystem.to_absolute_path(selection.file_path),
        selection.start_line,
        selection.end_line,
        table.concat(numbered, "\n")
    )
    return { type = "text", text = text }
end

--- Compose the content-block array for a turn: the prompt text first, then the
--- selection guidance and each non-empty selection, then referenced files, then
--- diagnostic blocks. Empty selections are dropped (and their guidance omitted).
--- @param opts { text: string, selections?: tend.Selection[], files?: string[], diagnostics?: tend.PromptContentBlock[] }
--- @return tend.PromptContentBlock[]
function M.build(opts)
    --- @type tend.PromptContentBlock[]
    local blocks = { { type = "text", text = opts.text } }

    local selections = {}
    for _, s in ipairs(opts.selections or {}) do
        if s and s.lines and #s.lines > 0 then
            table.insert(selections, s)
        end
    end
    if #selections > 0 then
        table.insert(blocks, { type = "text", text = SELECTION_GUIDANCE })
        for _, s in ipairs(selections) do
            table.insert(blocks, M.selection_block(s))
        end
    end

    for _, path in ipairs(opts.files or {}) do
        table.insert(blocks, M.file_block(path))
    end

    for _, diagnostic in ipairs(opts.diagnostics or {}) do
        table.insert(blocks, diagnostic)
    end

    return blocks
end

return M
