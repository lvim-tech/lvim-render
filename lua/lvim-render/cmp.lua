-- lvim-render.cmp: completion for the two constructs whose vocabulary this plugin OWNS — callout
-- types and checkbox states.
--
-- Both are configurable sets. A user who adds `{ key = "danger", icon = "󰚌" }` to `callouts.types`
-- has changed what the renderer understands, and nothing else in the editor knows that: an LSP has
-- never heard of it, a buffer-word source can only offer what is already written somewhere. So the
-- completion is generated FROM THE LIVE CONFIG on every request — never from a table copied here,
-- which would drift the moment someone edits their config.
--
-- It offers only where the construct can legally appear, decided from the text to the LEFT of the
-- cursor rather than from treesitter: half-typed `> [!` is not yet a callout node, and a source
-- that waits for the grammar to agree completes nothing while you are still typing the thing.
--
-- REGISTRATION IS OPTIONAL AND SILENT. lvim-cmp is a sibling plugin, not a dependency; when it is
-- absent this module does nothing and says nothing. That is why the require is a pcall and why
-- `setup()` never fails on its account.
--
---@module "lvim-render.cmp"

local config = require("lvim-render.config")
local state = require("lvim-render.state")

local M = {}

-- LSP CompletionItemKind: the callout types read as an enum, the checkbox states as constants.
local KIND_ENUM = 13
local KIND_CONSTANT = 21

M.name = "render"

--- The format block driving `buf`, or nil when the buffer is not one of ours.
---@param buf integer
---@return table|nil
local function format_of(buf)
    local st = state.get(buf)
    if st == nil or st.inert ~= nil then
        return nil
    end
    return rawget(config, st.format)
end

--- What is being completed at the cursor, if anything.
---
--- `> [!NOTE]` — the callout marker must be the first thing on its line (after any quote nesting),
--- which is what distinguishes it from a link's `[` a few columns later. `- [ ]` — the checkbox
--- marker must follow a list bullet, for the same reason.
---@param line string  the text before the cursor
---@return "callout"|"checkbox"|nil kind
---@return string prefix  what the user has typed of it so far
local function what_at(line)
    -- `>`-nesting, then the callout opener. The `%[!` is the discriminator: nothing else in
    -- markdown starts a bracket with a bang.
    local callout = line:match("^%s*>[%s>]*%[!(%a*)$")
    if callout ~= nil then
        return "callout", callout
    end
    -- A list marker, then the box. `%[` with nothing but the box's own character inside it.
    local checkbox = line:match("^%s*[-+*]%s+%[(%S?)$") or line:match("^%s*%d+[.)]%s+%[(%S?)$")
    if checkbox ~= nil then
        return "checkbox", checkbox
    end
    return nil, ""
end

--- The callout candidates, from the live config.
---@param fconf table
---@param closed boolean  a `]` already stands right after the cursor (a pair plugin closed the
---   bracket the reader opened), so the candidate must not bring a second one
---@return table[]
local function callout_items(fconf, closed)
    local callouts = fconf.callouts or {}
    if not callouts.enabled then
        return {}
    end
    local items = {}
    for i, t in ipairs(callouts.types or {}) do
        local key = tostring(t.key or ""):upper()
        if key ~= "" then
            items[#items + 1] = {
                -- The ENGINE'S shape, not a raw LSP item: `raw` is the insert/resolve target and
                -- the flat fields are what the menu and the ranker read. A candidate that carried
                -- only `insertText`/`sortText` was a raw item in the engine's slot — it inserted
                -- its label instead of the text, and its missing `filter_text` misaligned the
                -- fuzzy set for every source that answered after it.
                raw = {
                    label = key,
                    -- The inserted text closes the bracket the reader opened, so accepting leaves
                    -- a complete `> [!NOTE]` rather than something that still needs a `]` — unless
                    -- a pair plugin already put one there, in which case a second would be one too
                    -- many (measured with lvim-pairs: `- [` becomes `- []` as it is typed).
                    insertText = key .. (closed and "" or "]"),
                    detail = tostring(t.label or t.key or ""),
                },
                source_name = M.name,
                label = key,
                filter_text = key,
                -- Config order, not alphabetical: the author ordered them by how often they are
                -- reached for, and re-sorting would discard that.
                sort_text = ("%02d"):format(i),
                kind = KIND_ENUM,
                icon = t.icon,
            }
        end
    end
    return items
end

--- The checkbox candidates, from the live config.
---@param fconf table
---@param closed boolean  a `]` already stands right after the cursor — see `callout_items`
---@return table[]
local function checkbox_items(fconf, closed)
    local boxes = fconf.checkboxes or {}
    if not boxes.enabled then
        return {}
    end
    local items, seen = {}, {}
    for i, s in ipairs(boxes.states or {}) do
        local char = tostring(s.char or "")
        -- `x` and `X` render identically by design; offering both would be a menu of duplicates.
        local norm = char:lower()
        if char ~= "" and not seen[norm] then
            seen[norm] = true
            local label = char == " " and "[ ] unchecked" or ("[" .. char .. "]")
            items[#items + 1] = {
                raw = { label = label, insertText = char .. (closed and "" or "] "), detail = s.icon },
                source_name = M.name,
                label = label,
                filter_text = char == " " and "unchecked" or char,
                sort_text = ("%02d"):format(i),
                kind = KIND_CONSTANT,
                icon = s.icon,
            }
        end
    end
    return items
end

--- The lvim-cmp source contract.
---@type table
M.source = {
    name = M.name,

    ---@param ctx table
    ---@return boolean
    enabled = function(ctx)
        local fconf = format_of(ctx.bufnr)
        if fconf == nil then
            return false
        end
        local kind = what_at(ctx.line:sub(1, ctx.cursor[2]))
        -- The FORMAT must actually have the construct, not merely the line look like it. Typst
        -- has neither callouts nor checkboxes, so `- [` there is ordinary text — and a source
        -- that reports itself enabled only to return nothing is a menu that flickers for
        -- nothing.
        if kind == "callout" then
            return fconf.callouts ~= nil and fconf.callouts.enabled == true
        elseif kind == "checkbox" then
            return fconf.checkboxes ~= nil and fconf.checkboxes.enabled == true
        end
        return false
    end,

    ---@param _ integer
    ---@return table<string, boolean>
    trigger_chars = function(_)
        -- `!` opens the callout menu the moment the discriminator is typed; `[` opens the checkbox
        -- one. Both are cheap: `enabled` rejects every position where they mean something else.
        -- A SET, keyed by the character — the registry reads this table's KEYS, so a list would
        -- contribute the indices 1 and 2 and the source would never trigger at all.
        return { ["!"] = true, ["["] = true }
    end,

    ---@param ctx table
    ---@param cb fun(items: table[], incomplete: boolean)
    ---@return nil
    get = function(ctx, cb)
        local fconf = format_of(ctx.bufnr)
        if fconf == nil then
            cb({}, false)
            return
        end
        local kind = what_at(ctx.line:sub(1, ctx.cursor[2]))
        -- What already stands after the cursor decides whether the candidate closes the bracket.
        local closed = ctx.line:sub(ctx.cursor[2] + 1, ctx.cursor[2] + 1) == "]"
        local items = {}
        if kind == "callout" then
            items = callout_items(fconf, closed)
        elseif kind == "checkbox" then
            items = checkbox_items(fconf, closed)
        end
        cb(items, false)
    end,
}

--- Register with lvim-cmp when it is present. Idempotent, and silent when it is not: a sibling
--- plugin's absence is not this plugin's problem to report.
---@return boolean registered
function M.setup()
    if not config.completion.enabled then
        return false
    end
    local ok, cmp = pcall(require, "lvim-cmp")
    if not ok or type(cmp.register_source) ~= "function" then
        return false
    end
    local ok_reg = pcall(cmp.register_source, M.source, {
        priority = config.completion.priority,
        min_keyword_length = 0,
    })
    return ok_reg
end

return M
