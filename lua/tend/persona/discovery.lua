--- Persona discovery across native and imported sources.
---
--- Three tiers, merged by filename stem with this precedence (plan: Prompt And
--- Persona Model): workspace TEND personas > imported repo agents > user-scoped
--- TEND personas. Native personas live as `*.md` files — user-scoped in the
--- configured persona dirs, workspace-scoped under `.tend/personas/` in the
--- worktree. Imported personas come from harness agent dirs inside the repo
--- (for example `.claude/agents/`); each source maps its files through the
--- shared frontmatter adapter and its ids are namespaced `<source>:<stem>` so
--- harnesses cannot silently collide with each other. Missing dirs are simply
--- empty; discovery never errors on the filesystem.
local Frontmatter = require("tend.persona.frontmatter")

local M = {}

-- Workspace-scoped native personas, relative to the worktree root.
M.WORKSPACE_DIR = ".tend/personas"

--- Built-in import sources for common harnesses; overridable via opts.sources.
--- @type tend.persona.Source[]
M.BUILTIN_SOURCES = {
    { source = "claude", dir = ".claude/agents" },
    { source = "opencode", dir = ".opencode/agent" },
}

--- @class tend.persona.Persona
--- @field id string stem for native, "<source>:<stem>" for imported
--- @field name string display name (frontmatter name, or the stem)
--- @field description? string
--- @field prompt string the file body
--- @field source string "workspace" | "user" | an import source id
--- @field imported boolean
--- @field path string

--- @class tend.persona.Source
--- @field source string namespace id, e.g. "claude"
--- @field dir string agent dir relative to the workspace root

--- @class tend.persona.DiscoverOpts
--- @field user_dirs? string[] user-scoped native persona dirs
--- @field workspace_root? string worktree root; nil scans user dirs only
--- @field sources? tend.persona.Source[] import sources (default: built-ins)

--- @param path string
--- @return string|nil text
local function read_file(path)
    local f = io.open(path, "r")
    if not f then
        return nil
    end
    local text = f:read("*a")
    f:close()
    return text
end

--- Load every `*.md` definition in dir (sorted by stem) as a persona.
--- @param dir string
--- @param source string
--- @param imported boolean
--- @return tend.persona.Persona[]
local function scan_dir(dir, source, imported)
    local personas = {}
    for _, path in ipairs(vim.fn.glob(dir .. "/*.md", false, true)) do
        local text = read_file(path)
        if text then
            local stem = vim.fn.fnamemodify(path, ":t:r")
            local meta, body = Frontmatter.parse(text)
            -- A file's trailing newline is an artifact, not prompt content.
            body = body:gsub("\n+$", "")
            --- @type tend.persona.Persona
            local persona = {
                id = imported and (source .. ":" .. stem) or stem,
                name = meta.name or stem,
                description = meta.description,
                prompt = body,
                source = source,
                imported = imported,
                path = path,
            }
            table.insert(personas, persona)
        end
    end
    return personas
end

--- Discover personas from every tier, deduped by stem with workspace >
--- imported > user precedence. Tiers keep that order in the result; each tier
--- is sorted by stem.
--- @param opts? tend.persona.DiscoverOpts
--- @return tend.persona.Persona[]
function M.discover(opts)
    opts = opts or {}

    -- Each scan carries its precedence rank: workspace (1) > imported (2) >
    -- user (3). Every import source shares rank 2 — sources are peers.
    --- @type { rank: integer, personas: tend.persona.Persona[] }[]
    local tiers = {}
    if opts.workspace_root then
        table.insert(tiers, {
            rank = 1,
            personas = scan_dir(
                opts.workspace_root .. "/" .. M.WORKSPACE_DIR,
                "workspace",
                false
            ),
        })
        for _, src in ipairs(opts.sources or M.BUILTIN_SOURCES) do
            table.insert(tiers, {
                rank = 2,
                personas = scan_dir(
                    opts.workspace_root .. "/" .. src.dir,
                    src.source,
                    true
                ),
            })
        end
    end
    for _, dir in ipairs(opts.user_dirs or {}) do
        table.insert(
            tiers,
            { rank = 3, personas = scan_dir(dir, "user", false) }
        )
    end

    -- A stem is claimed by the highest rank that defines it: lower-ranked
    -- tiers' duplicates drop. Within a rank the namespaced id decides, so
    -- same-stem agents from different import sources all survive (that is
    -- what the namespace is for) while the same stem across two user dirs
    -- (identical id) keeps only the first dir's file.
    local out = {}
    local claimed = {}
    local seen_ids = {}
    for _, tier in ipairs(tiers) do
        for _, persona in ipairs(tier.personas) do
            local stem = vim.fn.fnamemodify(persona.path, ":t:r")
            local holder = claimed[stem]
            if
                (holder == nil or holder == tier.rank)
                and not seen_ids[persona.id]
            then
                claimed[stem] = tier.rank
                seen_ids[persona.id] = true
                table.insert(out, persona)
            end
        end
    end
    return out
end

return M
