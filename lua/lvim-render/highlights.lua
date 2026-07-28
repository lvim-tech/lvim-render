-- lvim-render.highlights: every group the plugin paints with, self-themed from the shared
-- lvim-utils palette through a bound factory — so a colorscheme change or a live palette retune
-- rebuilds them without this plugin knowing anything happened.
--
-- The tint canon: a coloured cell is its OWN accent blended toward the surface it sits on. Here the
-- surface is the editor background, because a heading band is the buffer's own line and a bullet is
-- a glyph over normal text. Specs with `bg = false` are foreground-only — a glyph, not a cell —
-- and specs with `fg = false` are BACKGROUND-only: a band that cannot wash out the colours drawn
-- on top of it (the §2a code-block invariant, enforced by construction, not by discipline).
--
-- The accents come from the LIVE config, so a repeat `setup()` re-registers with force rather than
-- no-opping — the bound factory alone only re-runs on a palette change. Dynamic families
-- (checkbox states, callout types) are rebuilt from the config each time for the same reason.
--
---@module "lvim-render.highlights"

local config = require("lvim-render.config")
local hl = require("lvim-utils.highlight")

local M = {}

---@type boolean  the factory is already bound
local bound = false

--- Resolve one config spec into a highlight definition.
---@param spec LvimRenderHighlightSpec
---@param c table  the live palette
---@return vim.api.keyset.highlight
local function group(spec, c)
    local color = c[spec.accent] or c.fg
    return {
        -- Both keys are omitted rather than set when switched off: an absent attribute lets
        -- whatever is behind (or on top) show through.
        fg = spec.fg ~= false and color or nil,
        bg = spec.bg ~= false and hl.blend(color, c.bg, spec.tint or 0.2) or nil,
        bold = spec.bold or false,
        italic = spec.italic or false,
        underline = spec.underline or false,
        strikethrough = spec.strikethrough or false,
    }
end

--- A callout key as a group-name suffix: letters/digits only, capitalised.
---@param key string
---@return string
local function callout_suffix(key)
    local word = key:gsub("%W", ""):lower()
    return (word:gsub("^%l", string.upper))
end

--- Build every group from the live palette and the live config.
---@param c table?  the live palette (defaults to lvim-utils.colors)
---@return table<string, vim.api.keyset.highlight>
local function build(c)
    c = c or require("lvim-utils.colors")
    local groups = {}
    for level = 1, 6 do
        local spec = config.highlights["h" .. level] or {}
        -- The STRONG variant of the level: the same accent, blended harder. It paints the fold
        -- line's count box, and the whole fold line while the cursor is on it — the tint canon's
        -- "active row is one solid tint of its own accent". Built even when the level names a
        -- custom `group`, because there is no strong variant of someone else's group to borrow.
        groups["LvimRenderFoldStrong" .. level] = group({
            accent = spec.accent,
            tint = config.fold.text.count_tint,
            bold = spec.bold,
        }, c)
        -- A spec naming an existing `group` is the user's own; nothing is built over it.
        if spec.group == nil then
            groups["LvimRenderH" .. level] = group(spec, c)
        end
    end
    for depth, spec in ipairs(config.highlights.bullets or {}) do
        groups["LvimRenderBullet" .. depth] = group(spec, c)
    end
    for depth, spec in ipairs(config.highlights.quotes or {}) do
        groups["LvimRenderQuote" .. depth] = group(spec, c)
    end
    for index, spec in ipairs(config.highlights.checkboxes or {}) do
        groups["LvimRenderCheckbox" .. index] = group(spec, c)
    end
    local callouts = (config.highlights.callouts or {}) --[[@as table<string, LvimRenderHighlightSpec>]]
    for key, spec in pairs(callouts) do
        groups["LvimRenderCallout" .. callout_suffix(key)] = group(spec, c)
    end
    groups["LvimRenderRule"] = group(config.highlights.rule or {}, c)
    groups["LvimRenderRuleIcon"] = group(config.highlights.rule_icon or {}, c)
    groups["LvimRenderFoldInfo"] = group(config.highlights.fold_info or {}, c)
    groups["LvimRenderCode"] = group(config.highlights.code or {}, c)
    groups["LvimRenderCodeLabel"] = group(config.highlights.code_label or {}, c)
    groups["LvimRenderCodeIcon"] = group(config.highlights.code_icon or {}, c)
    groups["LvimRenderCodeInline"] = group(config.highlights.code_inline or {}, c)
    groups["LvimRenderLink"] = group(config.highlights.link or {}, c)
    groups["LvimRenderTerm"] = group(config.highlights.term or {}, c)
    groups["LvimRenderTableBorder"] = group(config.highlights.table_border or {}, c)
    -- The CURSOR LINE inside a boxed table. The box is virtual lines, and Neovim paints no
    -- 'cursorline' over those — so the row the cursor is on is painted here instead, from the
    -- editor's OWN CursorLine background, so it looks like the cursor line everywhere else and
    -- follows a colorscheme change with it. Two groups: one for the cell text, one that keeps the
    -- border's foreground, so the highlight reaches the box edges instead of stopping at them.
    -- The row the cursor is on, inside a table drawn as a box. Both mark the CELLS only — the box
    -- keeps its frame on every row, exactly as the header band stops at the borders.
    local cursor_bg = vim.api.nvim_get_hl(0, { name = "CursorLine", link = false }).bg
    if cursor_bg ~= nil then
        groups["LvimRenderTableCursor"] = { bg = cursor_bg }
    end
    -- A HEADER row is already a coloured band, so it raises its OWN tint rather than being replaced
    -- by a foreign colour — the active-row half of the tint canon, the rule the fold line follows.
    groups["LvimRenderTableHeadCursor"] = group(config.highlights.table_head_cursor or {}, c)
    groups["LvimRenderTableHead"] = group(config.highlights.table_head or {}, c)
    groups["LvimRenderMath"] = group(config.highlights.math or {}, c)
    groups["LvimRenderMathLabel"] = group(config.highlights.math_label or {}, c)
    groups["LvimRenderMathSymbol"] = group(config.highlights.math_symbol or {}, c)
    groups["LvimRenderMark"] = group(config.highlights.mark or {}, c)
    groups["LvimRenderTag"] = group(config.highlights.tag or {}, c)
    groups["LvimRenderMetadata"] = group(config.highlights.metadata or {}, c)
    groups["LvimRenderHtmlBold"] = group(config.highlights.html_bold or {}, c)
    groups["LvimRenderHtmlItalic"] = group(config.highlights.html_italic or {}, c)
    groups["LvimRenderHtmlUnderline"] = group(config.highlights.html_underline or {}, c)
    groups["LvimRenderHtmlStrike"] = group(config.highlights.html_strike or {}, c)
    return groups
end

--- The STRONG counterpart of a level's group: the count box on a collapsed line, and the whole
--- line while the cursor is on it.
---@param level integer  1..6
---@return string
function M.fold_strong_group(level)
    return "LvimRenderFoldStrong" .. math.max(1, math.min(level, 6))
end

--- The heading group for a level: the user's own `group` when the spec names one, the built
--- LvimRenderH<n> otherwise. Render and foldtext both answer through this, so a custom group
--- follows the heading everywhere — band, icon, collapsed fold line.
---@param level integer  1..6
---@return string
function M.heading_group(level)
    local spec = config.highlights["h" .. level]
    if spec ~= nil and type(spec.group) == "string" and spec.group ~= "" then
        return spec.group
    end
    return "LvimRenderH" .. level
end

--- The bullet group for a nesting depth, cycling through the configured specs.
---@param depth integer  1-based nesting depth
---@return string
function M.bullet_group(depth)
    local n = #(config.highlights.bullets or {})
    if n == 0 then
        return "LvimRenderRule"
    end
    return "LvimRenderBullet" .. (((depth - 1) % n) + 1)
end

--- The quote-border group for a nesting depth, cycling like the bullets.
---@param depth integer  1-based nesting depth
---@return string
function M.quote_group(depth)
    local n = #(config.highlights.quotes or {})
    if n == 0 then
        return "LvimRenderRule"
    end
    return "LvimRenderQuote" .. (((depth - 1) % n) + 1)
end

--- The checkbox group for a state INDEX (the order of `checkboxes.states`).
---@param index integer
---@return string
function M.checkbox_group(index)
    if (config.highlights.checkboxes or {})[index] == nil then
        return "LvimRenderRule"
    end
    return "LvimRenderCheckbox" .. index
end

--- The callout group for a type key, or nil when no accent is configured for it (the caller
--- falls back to the quote depth accent).
---@param key string
---@return string|nil
function M.callout_group(key)
    if (config.highlights.callouts or {})[key] == nil then
        return nil
    end
    return "LvimRenderCallout" .. callout_suffix(key)
end

--- Bind the palette factory. Idempotent; a repeat call re-derives from the current config.
---@return nil
function M.setup()
    if bound then
        hl.register(build(), true)
        return
    end
    bound = true
    hl.bind(build)
end

return M
