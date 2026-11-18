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

---@type table<string, string>  an icon's highlight group → the CHIP group built from its colour
local chips = {}

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
    -- The chips are derived from icon colours the palette can move; drop them so the next draw
    -- rebuilds each one against the new background.
    chips = {}
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
    groups["LvimRenderCodeHeader"] = group(config.highlights.code_header or {}, c)
    groups["LvimRenderLink"] = group(config.highlights.link or {}, c)
    groups["LvimRenderTerm"] = group(config.highlights.term or {}, c)
    groups["LvimRenderTableBorder"] = group(config.highlights.table_border or {}, c)
    -- Stacked on the row's own highlight, so it adds the line and takes no colour away from it.
    groups["LvimRenderTableRowEnd"] = { underline = true, sp = groups["LvimRenderTableBorder"].fg }
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

--- The CHIP group for a language icon: the glyph's OWN colour on a tinted version of itself, so
--- the cell reads as belonging to the icon rather than to the band under it. A devicon's colour is
--- only known once that language appears in a buffer, so the group is built on demand — and built
--- OUT of the redraw: defining a highlight while the screen is being painted is a mutation during
--- drawing, so the first pass draws with the plain icon group and the definition lands for the
--- redraw that setting it triggers.
---@param icon_hl string  the icon's own highlight group
---@return string  the chip group, or `icon_hl` itself until the definition lands
function M.chip(icon_hl)
    local cached = chips[icon_hl]
    if cached ~= nil then
        return cached
    end
    chips[icon_hl] = icon_hl
    vim.schedule(function()
        local spec = config.highlights.code_chip or {}
        local c = require("lvim-utils.colors")
        local fg = vim.api.nvim_get_hl(0, { name = icon_hl, link = false }).fg
        local color = type(fg) == "number" and ("#%06x"):format(fg) or c.blue
        local name = "LvimRenderCodeChip" .. icon_hl:gsub("%W", "")
        vim.api.nvim_set_hl(0, name, {
            fg = color,
            bg = hl.blend(color, c.bg, spec.tint or 0.4),
            bold = spec.bold or false,
        })
        chips[icon_hl] = name
    end)
    return icon_hl
end

-- ── UI icons as images ──────────────────────────────────────────────────────
-- With lvim-icons drawing UI icons as IMAGES ("material"), a Nerd glyph the renderer paints (heading,
-- link, callout, label icons …) becomes two kitty placeholder cells whose highlight foreground IS the image
-- id. Resolving one transmits the image and defines groups — a mutation that must not happen while the
-- screen is being drawn (the passes run inside the decoration provider), so a miss draws the glyph as text
-- for this frame, resolves OUT of the redraw and asks for one more.

---@type table<string, [string, string][]|false>  "<text>\0<group>" → its chunks; false = stays as given
local icon_cache = {}
---@type table<string, true>  keys whose resolution is already scheduled
local icon_pending = {}

-- A live lvim-icons mode switch: what each icon resolves to changed — forget it all and draw again.
vim.api.nvim_create_autocmd("User", {
    group = vim.api.nvim_create_augroup("LvimRenderIconsMode", { clear = true }),
    pattern = "LvimIconsMode",
    callback = function()
        icon_cache, icon_pending = {}, {}
        pcall(function()
            require("lvim-render.engine").icons_changed()
        end)
    end,
})

--- Whether `text` is ONE private-use (Nerd Font) glyph with optional blanks around it — only those are UI
--- icons; bullets, rules and other symbols a format config may hold stay text.
---@param text string
---@return boolean
local function is_icon(text)
    local glyph = text:match("^%s*([^%s]+)%s*$")
    if glyph == nil or vim.fn.strchars(glyph) ~= 1 then
        return false
    end
    local cp = vim.fn.char2nr(glyph)
    return (cp >= 0xE000 and cp <= 0xF8FF) or (cp >= 0xF0000 and cp <= 0x10FFFD)
end

--- Resolve one icon now (outside a redraw): its chunks, or false when it stays the text as given.
---@param text string
---@param group string?
---@return [string, string][]|false
local function resolve_icon(text, group)
    local ok, iconlib = pcall(require, "lvim-utils.icons")
    if not (ok and iconlib.ui_text) then
        return false
    end
    local t, h, img = iconlib.ui_text(text, group)
    if not img then
        -- a glyph with no image while the others are images comes back padded to their two cells
        return t ~= text and { { t, group } } or false
    end
    local lead, trail = t:match("^%s*"), t:match("%s*$")
    -- the image keeps the background of the cell it sits in (a heading band, a chip)
    local img_hl = group and iconlib.on_bg({ image = true, hl = h }, group) or h
    local chunks = {}
    if lead ~= "" then
        chunks[#chunks + 1] = { lead, group }
    end
    chunks[#chunks + 1] = { t:sub(#lead + 1, #t - #trail), img_hl }
    if trail ~= "" then
        chunks[#chunks + 1] = { trail, group }
    end
    return chunks
end

--- A UI icon (one glyph, optional blanks around it) as virt_text chunks: the glyph itself in `group`, or —
--- where lvim-icons draws UI icons as images — its image cells in the image's own group with the blanks kept
--- in `group`. Safe to call from inside a redraw (see above).
---@param text string
---@param group string?
---@return [string, string][]
function M.icon_chunks(text, group)
    local plain = { { text, group } }
    if text == nil or text == "" or not is_icon(text) then
        return plain
    end
    local key = text .. "\0" .. (group or "")
    local cached = icon_cache[key]
    if cached ~= nil then
        -- a copy: callers append their own chunks to the list
        return cached and vim.list_extend({}, cached) or plain
    end
    if not icon_pending[key] then
        icon_pending[key] = true
        vim.schedule(function()
            icon_pending[key] = nil
            local chunks = resolve_icon(text, group)
            icon_cache[key] = chunks
            if chunks then
                -- the frame that missed drew the glyph as text: draw again with the image
                pcall(vim.api.nvim__redraw, { valid = false })
            end
        end)
    end
    return plain
end

--- An icon followed by more text in the SAME group (a chip, a callout title): one chunk `text .. rest` while
--- the icon stays a glyph (exactly what was drawn before), the icon's chunks + `rest` when it is an image.
---@param text string
---@param rest string
---@param group string?
---@return [string, string][]
function M.icon_prefix(text, rest, group)
    local chunks = M.icon_chunks(text, group)
    if #chunks == 1 and chunks[1][1] == text then
        return { { text .. rest, group } }
    end
    chunks[#chunks + 1] = { rest, group }
    return chunks
end

--- The display cells `icon_chunks(text, group)` takes — for a pass that measures the line it decorates.
---@param text string
---@param group string?
---@return integer
function M.icon_width(text, group)
    local w = 0
    for _, c in ipairs(M.icon_chunks(text, group)) do
        w = w + vim.fn.strdisplaywidth(c[1])
    end
    return w
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
