-- lvim-render.render: the windowed walk — parse exactly the rows a window shows, run the compiled
-- element queries (block AND inline) over them, and return DECORATION OPS (row, col, extmark
-- opts) for the engine to emit.
--
-- WHY OPS AND NOT EXTMARKS. Ephemeral extmarks may only be created inside a decoration provider
-- callback (measured: `nvim_buf_set_extmark` with `ephemeral = true` errors anywhere else). Split
-- the computation from the emission and the whole walk becomes callable from a fixture, from a
-- benchmark, from anywhere — the provider is just one consumer that adds `ephemeral = true`.
--
-- THE REVEAL LIVES HERE because it is a property of the walk: an element whose rows intersect the
-- reveal span is not decorated, so the text being edited is exactly what is in the file. Raw only
-- in the reveal modes (insert/replace by default). Small elements reveal WHOLE; a block quote
-- reveals PER ROW (its border is per-row anyway, and stripping a ten-line quote because one line
-- is being edited would flicker the whole paragraph).
--
-- CONCEAL AS THE WORKHORSE: wherever a token must become one glyph (a checkbox, an entity, a
-- backtick that becomes pill padding), the extmark `conceal` char does it in a single EPHEMERAL
-- op — no virtual text, no persistent mark, native cursor-line behaviour via 'concealcursor'.
-- The persistent inline lane exists only for text that ADDS width (heading icons, link icons).
--
---@module "lvim-render.render"

local config = require("lvim-render.config")
local highlights = require("lvim-render.highlights")
local state = require("lvim-render.state")
local entities = require("lvim-render.data.entities")
local emoji = require("lvim-render.data.emoji")

local api = vim.api
local fn = vim.fn
local ts = vim.treesitter

local M = {}

---@type integer  the ephemeral namespace: everything re-emitted per redraw at zero cleanup cost
M.ns = api.nvim_create_namespace("LvimRender")

---@type integer  the PERSISTENT inline lane. Inline virt_text cannot be ephemeral — it right-
--- shifts the buffer text, which the redraw must know before drawing, and an ephemeral mark
--- arrives during drawing (measured: the icon simply never appeared; Neovim's own inlay hints
--- emit inline marks with `ephemeral = false` from on_win for the same reason). The engine
--- reconciles these against the marks actually in the buffer.
M.ns_inline = api.nvim_create_namespace("LvimRenderInline")

---@type integer  rows of slack around every windowed range: the widest multi-row element is
--- still walked (and redrawn) whole when it straddles a boundary. Grows with the widest element
--- a phase ships (setext heading = 2 rows today; code blocks/quotes are handled per row).
M.SLACK = 2

---@class LvimRenderOp
---@field row integer  0-based
---@field col integer  0-based
---@field opts vim.api.keyset.set_extmark

---@type table<string, vim.treesitter.Query|false>  format → compiled BLOCK query
local block_queries = {}
---@type table<string, vim.treesitter.Query|false>  format → compiled INLINE query
local inline_queries = {}

--- The per-format element queries. Captures name OUR element types; the walk switches on them.
---@type table<string, string>
local BLOCK_SRC = {
    markdown = [[
        (atx_heading) @heading
        (setext_heading) @heading_setext
        (thematic_break) @rule
        (list_marker_minus) @bullet
        (list_marker_star) @bullet
        (list_marker_plus) @bullet
        (fenced_code_block) @codeblock
        (block_quote) @quote
        (pipe_table) @table
        (minus_metadata) @meta
        (plus_metadata) @meta
        (link_reference_definition) @refdef
    ]],
    -- Typst has NO injected inline layer: one grammar carries block and inline alike, so every
    -- capture below comes from this single query (INLINE_SRC has no typst entry).
    --
    -- `(item "-" @bullet)` matches BOTH markers: the grammar gives the `+` token the node type
    -- `-` as well (measured), and telling them apart is the marker TEXT's job, in the emitter.
    typst = [[
        (heading) @heading
        (item "-" @bullet)
        (term) @term
        (raw_blck) @codeblock
        (raw_span) @code
        (strong) @emphasis
        (emph) @emphasis
        (math) @math
        (url) @autolink
        (label) @label
        (ref) @ref
        (escape) @escape
    ]],
    -- Org, like typst, has ONE tree. Unlike either of the others it has no nodes for its inline
    -- markup at all: `*bold*` is a `str` between two bare `*` tokens inside an `expr` (the
    -- grammar's own `markup.scm` is written exactly that way, pairing a start token with an end
    -- one). So the paragraph and the headline title are captured WHOLE and scanned for pairs —
    -- see `emit_org_markup`, which is that scan.
    org = [[
        (headline) @heading
        (listitem (bullet) @bullet)
        (checkbox) @checkbox
        (block) @block
        (drawer) @meta
        (property_drawer) @meta
        (directive) @meta
        (paragraph) @markup
        (item) @markup
    ]],
}

---@type table<string, { lang: string, src: string }>  the inline layer is an INJECTED grammar,
--- so its query compiles against the injection language, not the format's block language
local INLINE_SRC = {
    markdown = {
        lang = "markdown_inline",
        src = [[
            (code_span) @code
            (emphasis) @emphasis
            (strong_emphasis) @emphasis
            (strikethrough) @emphasis
            (inline_link) @link
            (full_reference_link) @link
            (collapsed_reference_link) @link
            (shortcut_link) @link_shortcut
            (image) @image
            (entity_reference) @entity
            (latex_block) @math
            (html_tag) @html
            (uri_autolink) @autolink
            (backslash_escape) @escape
        ]],
    },
}

--- Compile (once) and return a query from a cache.
---@param cache table<string, vim.treesitter.Query|false>
---@param key string
---@param lang string|nil
---@param src string|nil
---@return vim.treesitter.Query|nil
local function query_for(cache, key, lang, src)
    if cache[key] == nil then
        if src == nil or lang == nil then
            cache[key] = false
        else
            local ok, q = pcall(ts.query.parse, lang, src)
            cache[key] = ok and q or false
        end
    end
    return cache[key] or nil
end

--- Heading level of a heading node, read from its marker child. Every format spells that marker
--- differently — markdown names the level in the node TYPE (`atx_h2_marker`), typst counts the
--- `=` run — so the level is decoded here, once, rather than in the emitter.
---@param node TSNode
---@return integer|nil level
---@return TSNode|nil marker  the marker node (atx/typst) or the underline node (setext)
local function heading_level(node)
    for child in node:iter_children() do
        local kind = child:type()
        local atx = kind:match("^atx_h(%d)_marker$")
        if atx then
            return tonumber(atx), child
        end
        local setext = kind:match("^setext_h(%d)_underline$")
        if setext then
            return tonumber(setext), child
        end
        -- Typst: the marker IS the run of `=`, and its length is the level. Safe to read on any
        -- node, because this function is only ever called on a captured heading.
        local eq = kind:match("^(=+)$")
        if eq then
            return #eq, child
        end
        -- Org: the level is the number of leading stars, in a node of its own.
        if kind == "stars" then
            local _, sc, _, ec = child:range()
            return ec - sc, child
        end
    end
    return nil, nil
end

---@class LvimRenderShape
---@field list_ancestor string   the node type whose nesting counts as list DEPTH
---@field emphasis_delims table<string, true>  child types that are emphasis delimiters
---@field code_delims table<string, true>      child types that are code-span delimiters
---@field code_parts fun(node: TSNode, buf: integer): TSNode[], TSNode|nil, TSNode|nil, string|nil

--- How each format spells the same PART. Only the parts that genuinely differ live here; where
--- two formats build an element the same way (an escape is a backslash before a character in
--- both), the emitter is shared outright and there is nothing to describe.
---@type table<string, LvimRenderShape>
local SHAPE = {
    markdown = {
        list_ancestor = "list",
        emphasis_delims = { emphasis_delimiter = true },
        code_delims = { code_span_delimiter = true },
        code_parts = function(node, buf)
            ---@type TSNode[], TSNode|nil, TSNode|nil, string|nil
            local delimiters, content, lang_node, lang = {}, nil, nil, nil
            for child in node:iter_children() do
                local kind = child:type()
                if kind == "fenced_code_block_delimiter" then
                    delimiters[#delimiters + 1] = child
                elseif kind == "code_fence_content" then
                    content = child
                elseif kind == "info_string" then
                    for sub in child:iter_children() do
                        if sub:type() == "language" then
                            lang_node = sub
                            lang = ts.get_node_text(sub, buf)
                        end
                    end
                end
            end
            return delimiters, content, lang_node, lang
        end,
    },
    typst = {
        -- Typst nests `item` inside `item` directly; there is no list wrapper to count.
        list_ancestor = "item",
        emphasis_delims = { ["*"] = true, ["_"] = true },
        code_delims = { ["`"] = true },
        code_parts = function(node, buf)
            ---@type TSNode[], TSNode|nil, TSNode|nil, string|nil
            local delimiters, content, lang_node, lang = {}, nil, nil, nil
            for child in node:iter_children() do
                local kind = child:type()
                if kind == "```" then
                    delimiters[#delimiters + 1] = child
                elseif kind == "blob" then
                    content = child
                elseif kind == "ident" then
                    -- The language sits on the opening fence as a bare identifier, with no
                    -- info-string wrapper of its own.
                    lang_node = child
                    lang = ts.get_node_text(child, buf)
                end
            end
            return delimiters, content, lang_node, lang
        end,
    },
    org = {
        list_ancestor = "list",
        -- Org names none of its inline markup: the delimiters are bare tokens inside an `expr`,
        -- and pairing them is `emit_org_markup`'s job rather than a per-child predicate's. These
        -- two tables therefore stay empty and the shared emitters are never called for org.
        emphasis_delims = {},
        code_delims = {},
        code_parts = function(node, buf)
            ---@type TSNode[], TSNode|nil, TSNode|nil, string|nil
            local delimiters, content, lang_node, lang = {}, nil, nil, nil
            -- Org's markers are TWO tokens each: `#+begin_` + the block kind, `#+end_` + the kind
            -- again. Both halves are marker text — the kind belongs to the delimiter, not to the
            -- content — so both conceal. The LANGUAGE is the one expr that is neither: the second
            -- one on the opening row.
            local seen_kind = false
            for child in node:iter_children() do
                local kind = child:type()
                if kind == "#+begin_" or kind == "#+end_" then
                    delimiters[#delimiters + 1] = child
                elseif kind == "contents" then
                    content = child
                elseif kind == "expr" then
                    if not seen_kind then
                        seen_kind = true
                        delimiters[#delimiters + 1] = child
                    elseif lang_node == nil and content == nil then
                        lang_node = child
                        lang = ts.get_node_text(child, buf)
                    else
                        -- Past the content: this is the closing marker's kind.
                        delimiters[#delimiters + 1] = child
                    end
                end
            end
            return delimiters, content, lang_node, lang
        end,
    },
}

--- The KIND of an org `#+begin_…` block (`src`, `quote`, `example`, …), lowercased.
---@param node TSNode
---@param buf integer
---@return string
local function org_block_kind(node, buf)
    for child in node:iter_children() do
        if child:type() == "expr" then
            return ts.get_node_text(child, buf):lower()
        end
    end
    return ""
end

--- Render a chunk template through its placeholder map. TABLE replacement, so a `%` in a value is
--- never read back as a gsub capture. (The fold line has its own copy of this three-line helper;
--- a module for one `gsub` would cost more to follow than it saves.)
---@param tpl string
---@param values table<string, string>
---@return string
local function fill(tpl, values)
    return (tpl:gsub("{(%w+)}", values))
end

--- The position of an auto-numbered list marker within its RUN — the number typst itself would
--- print. Counted over preceding siblings of the marker's item: a `-` item, a paragraph break or
--- any other node ends the run, exactly as it ends typst's numbering. The marker is compared by
--- TEXT, not by node type: this grammar gives `+` and `-` the same type (measured).
---@param marker TSNode  the marker token
---@param buf integer
---@return integer
local function enum_position(marker, buf)
    local item = marker:parent()
    if item == nil then
        return 1
    end
    local n = 1
    local prev = item:prev_sibling()
    while prev ~= nil and prev:type() == "item" do
        local first = prev:child(0)
        if first == nil or ts.get_node_text(first, buf):sub(1, 1) ~= "+" then
            break
        end
        n = n + 1
        prev = prev:prev_sibling()
    end
    return n
end

--- How many ancestors of `kind` sit above a node.
---@param node TSNode
---@param kind string
---@return integer
local function ancestor_count(node, kind)
    local depth = 0
    local parent = node:parent()
    while parent ~= nil do
        if parent:type() == kind then
            depth = depth + 1
        end
        parent = parent:parent()
    end
    return depth
end

--- Is `mode` in `list`? Matched exactly or by first character, so `"n"` covers `niI` without
--- the config having to enumerate every sub-mode.
---@param mode string  a `nvim_get_mode().mode` value
---@param list string[]
---@return boolean
local function mode_in(mode, list)
    for _, m in ipairs(list) do
        if mode == m or mode:sub(1, #m) == m then
            return true
        end
    end
    return false
end

--- Does a mode render at all? Public: the engine asks it about the two sides of a ModeChanged
--- to decide whether a repaint is owed.
---@param mode string
---@return boolean
function M.mode_allowed(mode)
    return mode_in(mode, config.render.modes)
end

--- Does a mode REVEAL at the cursor? Raw-only-in-insert is this list's default; outside it the
--- document renders fully, cursor line included.
---@param mode string
---@return boolean
function M.mode_reveals(mode)
    return mode_in(mode, config.reveal.modes)
end

---@class LvimRenderWalkCtx
---@field buf integer
---@field win integer
---@field fconf LvimRenderFormatConfig
---@field shape LvimRenderShape  how this format spells the parts the emitters read
---@field first integer  0-based first walked row
---@field last integer   0-based last walked row (inclusive)
---@field ops LvimRenderOp[]
---@field reveal { first: integer, last: integer }|nil
---@field eff_first integer
---@field eff_last integer
---@field lines table<integer, string>  lazily fetched buffer lines, 0-based row → text
---@field text_width integer|nil
---@field protect table<integer, [integer, integer][]>  per-row byte ranges the ROW SCANS must
---   not decorate inside (code spans, math spans, autolinks)
---@field skip_rows table<integer, true>  rows the scans skip whole (code blocks, frontmatter)
---@field extend { first: integer, last: integer }|nil  rows OUTSIDE the visible range whose
---   persistent marks this pass still owns. A boxed table hangs one block of virtual lines off the
---   row above it and hides every row below with `conceal_lines`; the lane that reconciles those
---   marks looks only at the rows the walk SAW, so a table crossing the viewport edge must widen
---   that window or half its marks can never be created — nor taken down again

--- Append one op.
---@param ctx LvimRenderWalkCtx
---@param row integer
---@param col integer
---@param opts vim.api.keyset.set_extmark
local function op(ctx, row, col, opts)
    ctx.ops[#ctx.ops + 1] = { row = row, col = col, opts = opts }
end

--- One buffer line, cached for the pass.
---@param ctx LvimRenderWalkCtx
---@param row integer  0-based
---@return string
local function line_at(ctx, row)
    if ctx.lines[row] == nil then
        ctx.lines[row] = api.nvim_buf_get_lines(ctx.buf, row, row + 1, false)[1] or ""
    end
    return ctx.lines[row]
end

--- Does an element intersect the reveal span? A hit extends the EFFECTIVE raw extent, so the
--- engine's later redraws repaint every row that was raw.
---@param ctx LvimRenderWalkCtx
---@param sr integer
---@param er integer  inclusive end row
---@return boolean
local function revealed(ctx, sr, er)
    local r = ctx.reveal
    if r == nil or sr > r.last or er < r.first then
        return false
    end
    ctx.eff_first = math.min(ctx.eff_first, sr)
    ctx.eff_last = math.max(ctx.eff_last, er)
    return true
end

--- A row-only reveal check (for per-row decorations like quote borders): no extent growth
--- beyond the row itself.
---@param ctx LvimRenderWalkCtx
---@param row integer
---@return boolean
local function row_revealed(ctx, row)
    local r = ctx.reveal
    return r ~= nil and row >= r.first and row <= r.last
end

--- The window's usable text width, computed once per pass.
---@param ctx LvimRenderWalkCtx
---@return integer
local function text_width(ctx)
    if ctx.text_width == nil then
        local info = fn.getwininfo(ctx.win)[1]
        ctx.text_width = api.nvim_win_get_width(ctx.win) - (info and info.textoff or 0)
    end
    return ctx.text_width
end

---@type table<string, string>  html tag name → the attribute group it styles its span with
local HTML_TAGS = {
    b = "LvimRenderHtmlBold",
    strong = "LvimRenderHtmlBold",
    i = "LvimRenderHtmlItalic",
    em = "LvimRenderHtmlItalic",
    u = "LvimRenderHtmlUnderline",
    s = "LvimRenderHtmlStrike",
    del = "LvimRenderHtmlStrike",
    strike = "LvimRenderHtmlStrike",
    mark = "LvimRenderMark",
}

--- Record a protected single-row range for the row scans.
---@param ctx LvimRenderWalkCtx
---@param node TSNode
local function protect_node(ctx, node)
    local sr, sc, er, ec = node:range()
    if sr == er then
        local list = ctx.protect[sr]
        if list == nil then
            list = {}
            ctx.protect[sr] = list
        end
        list[#list + 1] = { sc, ec }
    end
end

--- The matching CLOSING basic tag for an opening html_tag, with its style group. Shared by the
--- emitter and the table-width mirror so the two agree on what renders.
---@param node TSNode
---@param buf integer
---@return TSNode|nil close
---@return string|nil grp
local function html_pair(node, buf)
    local text = vim.treesitter.get_node_text(node, buf)
    local name = text:match("^<(%w+)>$")
    local grp = name ~= nil and HTML_TAGS[name:lower()] or nil
    if grp == nil then
        return nil, nil
    end
    local sib = node:next_sibling()
    while sib ~= nil do
        if sib:type() == "html_tag" then
            local close = vim.treesitter.get_node_text(sib, buf):match("^</(%w+)>$")
            if close ~= nil and close:lower() == name:lower() then
                return sib, grp
            end
        end
        sib = sib:next_sibling()
    end
    return nil, nil
end

-- ── block emitters ───────────────────────────────────────────────────────────

---@param ctx LvimRenderWalkCtx
---@param node TSNode
---@param setext boolean
local function emit_heading(ctx, node, setext)
    local hconf = ctx.fconf.headings
    if not hconf.enabled then
        return
    end
    local level, marker = heading_level(node)
    if level == nil then
        return
    end
    local sr, _, er, ec = node:range()
    local end_row = ec == 0 and er - 1 or er
    local raw = revealed(ctx, sr, end_row)
    local grp = highlights.heading_group(level)
    local spec = hconf.levels[level] or {}

    if hconf.band and not raw then
        for row = sr, end_row do
            -- A RANGE highlight with hl_eol, not line_hl_group: an ephemeral line_hl_group is
            -- silently not drawn (measured in tmux). With `text = "accent"` the op sits ABOVE
            -- treesitter, so the level's own colour paints the title — six visibly different
            -- headings whatever the theme's markup.heading groups do; with "theme" it drops
            -- below and only band + icon carry the accent.
            op(ctx, row, 0, {
                end_row = row + 1,
                end_col = 0,
                hl_group = grp,
                hl_eol = true,
                hl_mode = "combine",
                priority = hconf.text == "theme" and config.priorities.band or config.priorities.heading_text,
            })
        end
    end

    -- The icon is anchored at the END of the marker, never at column 0: inline virt_text
    -- anchored inside a concealed range is concealed WITH it (measured — the icon vanished),
    -- and the marker's own trailing space then provides the gap between icon and title.
    local msr, msc, mec = sr, 0, 0
    if not setext and marker ~= nil then
        msr, msc, _, mec = marker:range()
    end
    local icon = spec.icon or ""
    if icon ~= "" and not raw then
        op(ctx, msr, setext and 0 or mec, {
            virt_text = { { string.rep(" ", spec.pad or 0) .. icon, grp } },
            virt_text_pos = "inline",
        })
    end
    if not setext and hconf.conceal_markers and marker ~= nil and not raw then
        -- Only the `#` run itself; its trailing space stays visible as the gap.
        op(ctx, msr, msc, { end_col = mec, conceal = "", hl_group = grp })
    end
    if setext and hconf.setext_underline ~= "" and marker ~= nil and not raw then
        local usr, usc, _, uec = marker:range()
        op(ctx, usr, usc, {
            virt_text = { { hconf.setext_underline:rep(uec - usc), grp } },
            virt_text_pos = "overlay",
            hl_mode = "combine",
        })
    end
end

--- Fill exactly `cells` display cells by repeating a glyph PATTERN — one char (`─`), a double
--- line (`═`), a wavy one (`∿`), or a multi-char pattern (`·─`); the repeat is cut to the exact
--- cell count so the line always meets the window edge.
---@param pattern string
---@param cells integer
---@return string
local function fill_line(pattern, cells)
    local unit = fn.strdisplaywidth(pattern)
    if unit <= 0 then
        return ""
    end
    local out = pattern:rep(math.ceil(cells / unit))
    while fn.strdisplaywidth(out) > cells do
        out = fn.strcharpart(out, 0, fn.strchars(out) - 1)
    end
    -- A double-width char cut mid-pattern can land one short; pad with a space to stay exact.
    return out .. string.rep(" ", cells - fn.strdisplaywidth(out))
end

---@param ctx LvimRenderWalkCtx
---@param node TSNode
local function emit_rule(ctx, node)
    -- A format without a horizontal rule has no `rule` block at all (typst): the query never
    -- captures one there, but the guard keeps the emitter honest about its own precondition.
    local rconf = ctx.fconf.rule
    if rconf == nil or not rconf.enabled or rconf.glyph == "" then
        return
    end
    local sr = node:range()
    if revealed(ctx, sr, sr) then
        return
    end
    local width = math.max(text_width(ctx), 1)
    ---@type [string, string][]
    local chunks
    local icon = rconf.icon or ""
    local icon_cells = icon ~= "" and fn.strdisplaywidth(icon) + 2 or 0
    if icon ~= "" and width > icon_cells + 2 then
        -- A full-width line with the icon CENTRED in it: `─── ◆ ───`.
        local left = math.floor((width - icon_cells) / 2)
        local right = width - icon_cells - left
        chunks = {
            { fill_line(rconf.glyph, left), "LvimRenderRule" },
            { " " .. icon .. " ", "LvimRenderRuleIcon" },
            { fill_line(rconf.glyph, right), "LvimRenderRule" },
        }
    else
        chunks = { { fill_line(rconf.glyph, width), "LvimRenderRule" } }
    end
    op(ctx, sr, 0, {
        virt_text = chunks,
        virt_text_pos = "overlay",
        virt_text_win_col = 0,
        hl_mode = "combine",
    })
end

--- A list marker: either a plain bullet glyph, or — when a checkbox token follows — the whole
--- `[c]` token concealed TO the state's icon (one ephemeral op, no virtual text at all).
---@param ctx LvimRenderWalkCtx
---@param node TSNode
local function emit_bullet(ctx, node)
    local lconf = ctx.fconf.lists
    local msr, msc, _, mec = node:range()
    if revealed(ctx, msr, msr) then
        return
    end
    -- The glyph overlays the marker CHARACTER, not the node's first column: a marker node may
    -- swallow part of the item's indentation (measured — for the FIRST item of a four-space
    -- sublist the grammar reports `  - ` as one [r,2-r,6] node, while its sibling below gets
    -- [r,4-r,6]), so anchoring at the node start painted the glyph two columns early and left
    -- the raw `-` visible beside it.
    local mtext = ts.get_node_text(node, ctx.buf)
    local offset = mtext:find("[^%s]") or 1
    local marker_col = msc + offset - 1

    local cconf = ctx.fconf.checkboxes
    if cconf ~= nil and cconf.enabled then
        local rest = line_at(ctx, msr):sub(mec + 1)
        local char = rest:match("^%[(.)%]%s") or rest:match("^%[(.)%]$")
        if char ~= nil then
            for index, spec in ipairs(cconf.states) do
                if spec.char == char and spec.icon ~= "" then
                    local grp = highlights.checkbox_group(index)
                    -- Hide the list marker (its char through its trailing space)…
                    op(ctx, msr, marker_col, { end_col = mec, conceal = "" })
                    -- …and render the 3-char token as the state icon.
                    op(ctx, msr, mec, { end_col = mec + 3, conceal = spec.icon, hl_group = grp })
                    return
                end
            end
        end
    end

    if not lconf.enabled then
        return
    end
    local depth = math.max(ancestor_count(node, ctx.shape.list_ancestor), 1)

    -- An AUTO-NUMBERED marker (typst's `+`) renders as its ordinal, not as a bullet: the two
    -- markers mean different things and a dot for both would say they are the same list.
    local enum = lconf.enum
    if enum ~= nil and enum.enabled and mtext:match("^%s*%+") ~= nil then
        local text = fill(enum.format, { n = tostring(enum_position(node, ctx.buf)) })
        if text ~= "" then
            -- CONCEAL the marker and insert the ordinal INLINE, rather than overlaying it: an
            -- ordinal is wider than the one cell `+` occupies, and an overlay of `1.` swallowed
            -- the marker's trailing space with it (measured — the item read `1.едно`). Inline
            -- lets the row shift by the real width, which is what typst itself prints.
            op(ctx, msr, marker_col, { end_col = mec, conceal = "" })
            op(ctx, msr, marker_col, {
                virt_text = { { text, highlights.bullet_group(depth) } },
                virt_text_pos = "inline",
                hl_mode = "combine",
            })
        end
        return
    end

    if #lconf.bullets == 0 then
        return
    end
    -- An ORDERED marker keeps what the file says. Org writes its own numbers (`1.`, `2.`) — they
    -- are already the ordinal a reader wants, and a one-cell glyph overlaid on a two-cell marker
    -- left the `.` behind (measured: the item read `●. номерирано`). Typst's `+` is different and
    -- is handled above: there the number exists nowhere in the source.
    if mtext:match("^%s*[%-%+%*]%s*$") == nil then
        return
    end
    local glyph = lconf.bullets[((depth - 1) % #lconf.bullets) + 1]
    if glyph == "" then
        return
    end
    op(ctx, msr, marker_col, {
        virt_text = { { glyph, highlights.bullet_group(depth) } },
        virt_text_pos = "overlay",
        hl_mode = "combine",
    })
end

---@param ctx LvimRenderWalkCtx
---@param node TSNode
local function emit_codeblock(ctx, node)
    local cconf = ctx.fconf.code
    if cconf == nil or not cconf.enabled then
        return
    end
    local sr, _, er, ec = node:range()
    local end_row = ec == 0 and er - 1 or er
    -- Whole-element reveal: a half-banded code block with one raw fence is unreadable.
    if revealed(ctx, sr, end_row) then
        return
    end

    local delimiters, content, lang_node, lang = ctx.shape.code_parts(node, ctx.buf)

    -- THE HEADER ROW. The opening fence's text is concealed whole, which leaves the row free: it
    -- becomes the band that carries the language chip. Only with `fences = "show"` — "hide"
    -- removes the row from the display and nothing can be drawn on a row that is not there
    -- (measured: virt_lines on a `conceal_lines` row do not draw either).
    -- The block's FIRST row, not the first delimiter's: org writes its opening marker as two
    -- tokens and the order they arrive in is the query's business, not this one's. The opening
    -- fence is the block's first line in every format that has one.
    local header_row = nil
    if cconf.header and cconf.fences == "show" and delimiters[1] ~= nil then
        header_row = sr
    end

    -- THE BODY'S WIDTH. "content" makes the code a BOX — as wide as its longest line plus the
    -- padding on both sides — under a header band that stays full width; "full" reaches the window
    -- edge on every row, which is what a plain band always did.
    local pad = math.max(0, cconf.pad or 0)
    local box = text_width(ctx)
    local boxed = cconf.band and cconf.width == "content"
    -- The rows are read when EITHER the box needs measuring or the inset needs placing at the end
    -- of each line — one call for the block, not one per row.
    local body_lines = (cconf.band and (boxed or pad > 0)) and api.nvim_buf_get_lines(ctx.buf, sr, end_row + 1, false)
        or nil
    if boxed and body_lines ~= nil then
        -- Measured over the WHOLE block, not the visible part: a box whose width changed as it
        -- scrolled would breathe in and out under the reader.
        local widest = 0
        for i, line in ipairs(body_lines) do
            local row = sr + i - 1
            if row ~= header_row then
                widest = math.max(widest, fn.strdisplaywidth(line))
            end
        end
        box = math.min(box, widest + pad * 2)
    end

    if cconf.band then
        for row = math.max(sr, ctx.first), math.min(end_row, ctx.last) do
            if row == header_row then
                -- END TO END, whatever the body does: the band is the block's chrome, and chrome
                -- that stopped where the code stops would read as one more line of it.
                op(ctx, row, 0, {
                    end_row = row + 1,
                    end_col = 0,
                    hl_group = "LvimRenderCodeHeader",
                    hl_eol = true,
                    hl_mode = "combine",
                    priority = config.priorities.band,
                })
            else
                -- BACKGROUND-only group (fg = false in its spec), priority below treesitter: the
                -- injected language's own colours always win on top of the band — §2a.
                op(ctx, row, 0, {
                    end_row = row + 1,
                    end_col = 0,
                    hl_group = "LvimRenderCode",
                    hl_eol = not boxed,
                    hl_mode = "combine",
                    priority = config.priorities.band,
                })
                if body_lines ~= nil then
                    -- The INSET, and — when the body is a box — the fill that carries its
                    -- background out to the box's edge. A full-width body needs no fill: `hl_eol`
                    -- already paints to the window's edge, and the trailing space is only there so
                    -- a line that reaches the edge does not touch it.
                    local line = body_lines[row - sr + 1] or ""
                    local fill = boxed and math.max(0, box - pad - fn.strdisplaywidth(line)) or pad
                    if #line == 0 then
                        op(ctx, row, 0, {
                            virt_text = { { string.rep(" ", pad + fill), "LvimRenderCode" } },
                            virt_text_pos = "inline",
                        })
                    else
                        if pad > 0 then
                            op(ctx, row, 0, {
                                virt_text = { { string.rep(" ", pad), "LvimRenderCode" } },
                                virt_text_pos = "inline",
                            })
                        end
                        if fill > 0 then
                            op(ctx, row, #line, {
                                virt_text = { { string.rep(" ", fill), "LvimRenderCode" } },
                                virt_text_pos = "inline",
                            })
                        end
                    end
                end
            end
        end
    end

    -- AIR under the band: the same blank row a framed window puts below its title, in the body's
    -- own colour so it reads as the top of the code box rather than a gap in the document.
    if header_row ~= nil and (cconf.air or 0) > 0 and header_row >= ctx.first and header_row <= ctx.last then
        ---@type [string, string][][]
        local air = {}
        for _ = 1, cconf.air do
            air[#air + 1] = { { string.rep(" ", box), "LvimRenderCode" } }
        end
        op(ctx, header_row, 0, { virt_lines = air })
    end

    -- The chip icon's colour: "accent" (default) is the plugin's own distinct group;
    -- "devicon" takes the language's lvim-icons colour when available, accent as fallback.
    local icon, icon_hl = cconf.icon, "LvimRenderCodeIcon"
    if lang ~= nil and cconf.icon_color == "devicon" then
        -- Inline require: optional cross-plugin dependency (the devicon per language).
        local ok_icons, icons = pcall(require, "lvim-icons")
        if ok_icons then
            local result = icons.by_filetype(lang)
            if result ~= nil and type(result.glyph) == "string" and result.width == 1 then
                icon = result.glyph
                icon_hl = result.hl or icon_hl
            end
        end
    elseif lang ~= nil then
        local ok_icons, icons = pcall(require, "lvim-icons")
        if ok_icons then
            local result = icons.by_filetype(lang)
            if result ~= nil and type(result.glyph) == "string" and result.width == 1 then
                icon = result.glyph
            end
        end
    end

    if cconf.fences == "show" then
        -- The fence LINES stay visible (the owner's rule; queries.lua strips the native
        -- `conceal_lines` that would hide them whole): only the backtick runs conceal. Where
        -- the chip sits on that line is `position`: "left" keeps the language text in place
        -- behind an inline icon; "center"/"right" conceal the language text too and draw
        -- icon + name there.
        -- The chip anchors after the LAST concealed marker on the opening row, not after the
        -- first: markdown writes one delimiter per row, but org's opening marker is two tokens
        -- (`#+begin_` plus the block kind), and anchoring after the first drew the chip in the
        -- middle of what was about to disappear.
        local open_row = header_row or (delimiters[1] ~= nil and delimiters[1]:range() or 0)
        local anchor = 0
        for _, delim in ipairs(delimiters) do
            local dr, _, _, dec = delim:range()
            if dr == open_row then
                anchor = math.max(anchor, dec)
            end
        end
        for _, delim in ipairs(delimiters) do
            local dr, dc, _, dec = delim:range()
            op(ctx, dr, dc, { end_col = dec, conceal = "" })
        end

        -- THE CHIP: icon and language in ONE cell, a space on either side, painted in the icon's
        -- own colour on a tinted version of it — so the band says which language this is in the
        -- colour that language already has everywhere else in the editor.
        if cconf.label and lang ~= nil and icon ~= "" and header_row ~= nil then
            if lang_node ~= nil then
                local lsr, lsc, _, lec = lang_node:range()
                op(ctx, lsr, lsc, { end_col = lec, conceal = "" })
            end
            local chip = (" %s %s "):format(icon, lang)
            local cells = fn.strdisplaywidth(chip)
            ---@type vim.api.keyset.set_extmark
            local opts = {
                virt_text = { { chip, highlights.chip(icon_hl) } },
                hl_mode = "combine",
                priority = config.priorities.band + 1,
            }
            if cconf.position == "right" then
                opts.virt_text_pos = "right_align"
            else
                -- OVERLAY, not inline: the row's own text is concealed to nothing, so an inline
                -- chunk would still sit at column 0 and "center" would mean nothing. Overlay puts
                -- it at a screen column of its own choosing.
                opts.virt_text_pos = "overlay"
                opts.virt_text_win_col = cconf.position == "left" and 0
                    or math.max(math.floor((text_width(ctx) - cells) / 2), 0)
            end
            op(ctx, header_row, anchor, opts)
        end
        return
    end

    -- fences = "hide": the native behaviour — the fence lines are conceal_lines-hidden by the
    -- markdown query, so a chip there would be invisible (measured); it rides the first CONTENT
    -- row instead, right-aligned. It does not assume it owns that space: other right/eol
    -- virtual text on that row wins or shares by priority, and the chip merely follows.
    if not cconf.label or content == nil or lang == nil then
        return
    end
    local csr = content:range()
    op(ctx, csr, 0, {
        virt_text = { { icon, icon_hl }, { " " .. lang, "LvimRenderCodeLabel" } },
        virt_text_pos = "right_align",
        hl_mode = "combine",
    })
end

---@param ctx LvimRenderWalkCtx
---@param node TSNode
local function emit_quote(ctx, node)
    local qconf = ctx.fconf.quotes
    if qconf == nil or not qconf.enabled or qconf.border == "" then
        return
    end
    local sr, _, er, ec = node:range()
    local end_row = ec == 0 and er - 1 or er
    -- Whole-element reveal by default (one element, one reveal — a callout with live borders
    -- around a raw title row is half-rendered); "row" keeps the phase-3 per-row behaviour for
    -- very long quotes. The span GROWS like the table's, so the inline pass reveals the quote's
    -- contents too.
    if
        config.reveal.quotes ~= "row"
        and ctx.reveal ~= nil
        and sr <= ctx.reveal.last
        and end_row >= ctx.reveal.first
    then
        revealed(ctx, sr, end_row)
        ctx.reveal.first = math.min(ctx.reveal.first, sr)
        ctx.reveal.last = math.max(ctx.reveal.last, end_row)
        return
    end
    local depth = ancestor_count(node, "block_quote") + 1

    -- Callout: a quote whose first content starts with `[!type]` takes the type's accent and
    -- renders the token as icon + label. Matched case-insensitively, like the ecosystems that
    -- write them do.
    local grp = highlights.quote_group(depth)
    local callout, token_s, token_e = nil, nil, nil
    local cconf = ctx.fconf.callouts
    if cconf ~= nil and cconf.enabled then
        local first_line = line_at(ctx, sr)
        -- Anchored probe first (the token must be the quote's first content), then the token's
        -- own 1-based span taken DIRECTLY from a second find — computed offsets off the outer
        -- match were an off-by-one that ate the character after the token (measured in tmux).
        local word = first_line:match("^[%s>]*%[!(%w+)%]")
        if word ~= nil then
            for _, t in ipairs(cconf.types) do
                if t.key:lower() == word:lower() then
                    callout = t
                    token_s, token_e = first_line:find("%[!%w+%]")
                    grp = highlights.callout_group(t.key:lower()) or grp
                    break
                end
            end
        end
    end

    -- The border, per row: this quote owns the DEPTH-th `>` of each line's marker prefix
    -- (`block_quote_marker` covers only the first line; continuation rows carry their `>` in
    -- block_continuation nodes — measured — so the line text is the one uniform source).
    for row = math.max(sr, ctx.first), math.min(end_row, ctx.last) do
        if not row_revealed(ctx, row) then
            local line = ctx.lines[row] == nil and line_at(ctx, row) or ctx.lines[row]
            local count, col = 0, nil
            for i = 1, #line do
                local c = line:sub(i, i)
                if c == ">" then
                    count = count + 1
                    if count == depth then
                        col = i - 1
                        break
                    end
                elseif c ~= " " and c ~= "\t" then
                    break
                end
            end
            if col ~= nil then
                ---@type vim.api.keyset.set_extmark
                local opts = {
                    virt_text = { { qconf.border, grp } },
                    virt_text_pos = "overlay",
                    hl_mode = "combine",
                }
                if qconf.repeat_on_wrap then
                    -- Repeats the border on every wrapped row — which paints over that row's
                    -- first text cell unless 'breakindent'/'showbreak' keep the column free
                    -- (measured); off by default for exactly that reason.
                    opts.virt_text_win_col = col
                    opts.virt_text_repeat_linebreak = true
                end
                op(ctx, row, col, opts)
            end
        end
    end

    if callout ~= nil and token_s ~= nil and token_e ~= nil and not row_revealed(ctx, sr) then
        -- The token is CONCEALED whole and the chip INSERTED after it — never overlaid: the
        -- runtime markdown_inline queries already conceal the token's brackets (it parses as a
        -- shortcut link), so the line is 2 cells narrower right there and a raw-width overlay
        -- eats the characters that follow (measured cell by cell in tmux). Owning the whole
        -- token makes the chip immune to whatever else conceals inside it. The chip anchors at
        -- the token's END column — inline text anchored inside a concealed range is concealed
        -- with it (the heading-icon lesson).
        op(ctx, sr, token_s - 1, { end_col = token_e, conceal = "" })
        op(ctx, sr, token_e, {
            virt_text = { { callout.icon .. " " .. callout.label, grp } },
            virt_text_pos = "inline",
        })
    end
end

-- ── math: the shared symbol data and the linear tokenizer ───────────────────
--
-- THE SYMBOL MAP IS lvim-tex's (conceal/data.lua — the plan's "one table, exported from
-- whichever ships first"; lvim-tex shipped first and its module is data-only). Consumed as an
-- optional cross-plugin dependency; user maps merge OVER a copy. Without lvim-tex the math
-- substitution is inert and health says exactly that.
--
-- THE HONESTY CEILING, by construction: `conceal` replaces a range with ONE character, so only
-- tokens with a single-char rendering substitute — a bare command (`\alpha` → α) or a
-- single-char script (`^2` → ², `_i` → ᵢ). `\frac{a}{b}`, multi-char exponents, matrices and
-- environments stay RAW text (inside the block band), readable and honest, never mangled. No
-- latex grammar is injected here (measured: the runtime injections carry only yaml and
-- markdown_inline), so the tokenizer is a plain scan of the span's own text.

---@type { symbols: table<string, string>, sup: table<string, string>, sub: table<string, string> }|nil
local math_maps = nil
---@type boolean  lvim-tex's data module was found (health reads this through M.math_available)
local math_source = false

--- Drop the built maps (a repeat setup() may have changed config.math.*.maps).
function M.invalidate_math()
    math_maps = nil
end

--- The merged math maps, built lazily.
---@return { symbols: table<string, string>, sup: table<string, string>, sub: table<string, string> }
local function get_math_maps()
    if math_maps ~= nil then
        return math_maps
    end
    local symbols, sup, sub = {}, {}, {}
    -- Inline require: optional cross-plugin data dependency.
    local ok, data = pcall(require, "lvim-tex.conceal.data")
    math_source = ok
    if ok then
        for k, v in pairs(data.math_symbols or {}) do
            symbols[k] = v
        end
        local scripts = data.scripts or {}
        for k, v in pairs(scripts.superscript or {}) do
            sup[k] = v
        end
        for k, v in pairs(scripts.subscript or {}) do
            sub[k] = v
        end
    end
    for k, v in pairs(config.math.inline.maps or {}) do
        symbols[k] = v
    end
    for k, v in pairs(config.math.block.maps or {}) do
        symbols[k] = v
    end
    math_maps = { symbols = symbols, sup = sup, sub = sub }
    return math_maps
end

--- Is the shared symbol source present?
---@return boolean
function M.math_available()
    get_math_maps()
    return math_source
end

--- Tokenise one line SEGMENT of math into single-char substitutions. Shared by the emitter and
--- the table-width mirror, so the two can never drift.
---@param text string   the segment (no delimiters)
---@param base integer  byte col of the segment start
---@return { s: integer, e: integer, repl: string }[]  absolute byte ranges → one glyph
local function math_tokens(text, base)
    local maps = get_math_maps()
    ---@type { s: integer, e: integer, repl: string }[]
    local out = {}
    -- Commands: \word (longest match wins by construction — %a+ is greedy).
    for s0, cmd in text:gmatch("()(\\%a+)") do
        local repl = maps.symbols[cmd]
        if repl ~= nil and fn.strchars(repl) == 1 then
            out[#out + 1] = { s = base + s0 - 1, e = base + s0 - 1 + #cmd, repl = repl }
        end
    end
    -- Scripts: ^x / _x and ^{x} / _{x} with a SINGLE mappable char; anything longer is the
    -- ceiling and stays raw.
    for s0, op, ch in text:gmatch("()([%^_])(%w)") do
        local map = op == "^" and maps.sup or maps.sub
        local repl = map[ch]
        if repl ~= nil then
            out[#out + 1] = { s = base + s0 - 1, e = base + s0 + 1, repl = repl }
        end
    end
    for s0, op, ch, e0 in text:gmatch("()([%^_]){(%w)}()") do
        local map = op == "^" and maps.sup or maps.sub
        local repl = map[ch]
        if repl ~= nil then
            out[#out + 1] = { s = base + s0 - 1, e = base + e0 - 1, repl = repl }
        end
    end
    return out
end

-- ── tables ───────────────────────────────────────────────────────────────────
--
-- THE WIDTH TRAP, addressed head on: by paint time the inline layer has already concealed link
-- syntax, turned backticks into padding and inserted icons — a column measured on RAW text is
-- wrong by the full URL per link cell. Every cell is therefore measured as RENDERED width:
-- display width of its text, minus every concealed interval (merged, so overlapping conceals
-- count once), plus every inline insertion anchored OUTSIDE a concealed interval (one anchored
-- inside is hidden with it — the heading-icon lesson). `strdisplaywidth` throughout, so `≥`,
-- Cyrillic and CJK measure as cells, never bytes. The fixture cross-pins this arithmetic
-- against the real collect() ops for the same cells.

--- The inline-layer adjustments for one buffer ROW: merged conceal intervals (with their
--- replacement widths) and inline insertions, mirroring exactly what the emitters produce.
---@param ctx LvimRenderWalkCtx
---@param ichild vim.treesitter.LanguageTree  the inline injection child
---@param iq vim.treesitter.Query
---@param row integer
---@return { s: integer, e: integer, repl: integer }[] intervals  byte-col ranges, merged
---@return { col: integer, width: integer }[] inserts
local function row_adjustments(ctx, ichild, iq, row)
    ---@type { s: integer, e: integer, repl: integer }[]
    local raw = {}
    ---@type { col: integer, width: integer }[]
    local inserts = {}
    local fconf = ctx.fconf

    -- Every inline tree touching the row: table cells are separate injection regions, and a
    -- single-root shortcut missed them (caught by the fixture's ops cross-pin).
    ---@type TSNode[]
    local roots = {}
    for _, tree in pairs(ichild:trees()) do
        local ir = tree:root()
        local isr, _, ier = ir:range()
        if row >= isr and row <= ier then
            roots[#roots + 1] = ir
        end
    end

    for _, iroot in ipairs(roots) do
        for id, node in iq:iter_captures(iroot, ctx.buf, row, row + 1) do
            local name = iq.captures[id]
            local sr, sc, er, ec = node:range()
            if sr == row and er == row then
                if name == "code" and fconf.inline_code ~= nil and fconf.inline_code.enabled then
                    for child in node:iter_children() do
                        if child:type() == "code_span_delimiter" then
                            local _, dc, _, dec = child:range()
                            raw[#raw + 1] = {
                                s = dc,
                                e = dec,
                                repl = fconf.inline_code.pad == "" and 0 or 1,
                                rtext = fconf.inline_code.pad,
                            }
                        end
                    end
                elseif name == "emphasis" and fconf.emphasis ~= nil and fconf.emphasis.enabled then
                    for child in node:iter_children() do
                        if child:type() == "emphasis_delimiter" then
                            local _, dc, _, dec = child:range()
                            raw[#raw + 1] = { s = dc, e = dec, repl = 0 }
                        end
                    end
                elseif
                    (name == "link" or name == "image" or name == "link_shortcut")
                    and fconf.links ~= nil
                    and fconf.links.enabled
                then
                    ---@type TSNode|nil
                    local label = nil
                    for child in node:iter_children() do
                        local kind = child:type()
                        if kind == "link_text" or kind == "image_description" then
                            label = child
                        end
                    end
                    if label ~= nil then
                        local _, lsc, _, lec = label:range()
                        -- Shortcut "links" (`[word]` — checkboxes, callout tokens, plain brackets)
                        -- get NO ops of ours, but the RUNTIME query conceals their brackets, so the
                        -- width arithmetic must count them all the same.
                        if fconf.links.conceal or name == "link_shortcut" then
                            raw[#raw + 1] = { s = sc, e = lsc, repl = 0 }
                            raw[#raw + 1] = { s = lec, e = ec, repl = 0 }
                        end
                        if name == "link_shortcut" then
                            -- A WIKILINK (outer brackets around the shortcut) mirrors the
                            -- emitter: outer pair + `target|` conceal + the wiki icon. An
                            -- embed's inner shortcut belongs to the image emitter (same parent
                            -- guard as there).
                            local parent = node:parent()
                            local wiki_line = line_at(ctx, row)
                            if
                                (parent == nil or parent:type() ~= "image_description")
                                and wiki_line:sub(sc, sc) == "["
                                and wiki_line:sub(ec + 1, ec + 1) == "]"
                                and fconf.links.conceal
                            then
                                raw[#raw + 1] = { s = sc - 1, e = sc, repl = 0 }
                                raw[#raw + 1] = { s = ec, e = ec + 1, repl = 0 }
                                local wtext = wiki_line:sub(lsc + 1, lec)
                                local pipe = wtext:find("|", 1, true)
                                if pipe ~= nil then
                                    raw[#raw + 1] = { s = lsc, e = lsc + pipe, repl = 0 }
                                end
                                if fconf.links.icons.wiki ~= "" then
                                    inserts[#inserts + 1] = {
                                        col = pipe ~= nil and (lsc + pipe) or lsc,
                                        width = fn.strdisplaywidth(fconf.links.icons.wiki),
                                        text = fconf.links.icons.wiki,
                                    }
                                end
                            end
                        else
                            local icon = name == "image" and fconf.links.icons.image or fconf.links.icons.link
                            if icon ~= "" then
                                inserts[#inserts + 1] = { col = lsc, width = fn.strdisplaywidth(icon), text = icon }
                            end
                        end
                    end
                elseif name == "entity" and fconf.entities ~= nil and fconf.entities.enabled then
                    local ename = ts.get_node_text(node, ctx.buf):match("^&(%w+);$")
                    local glyph = ename ~= nil and (fconf.entities.extra[ename] or entities[ename]) or nil
                    if glyph ~= nil and fn.strchars(glyph) == 1 then
                        raw[#raw + 1] = { s = sc, e = ec, repl = fn.strdisplaywidth(glyph), rtext = glyph }
                    end
                elseif name == "math" and config.math.inline.enabled then
                    ---@type TSNode[]
                    local delims = {}
                    for child in node:iter_children() do
                        if child:type() == "latex_span_delimiter" then
                            delims[#delims + 1] = child
                        end
                    end
                    if #delims >= 2 then
                        local _, d1s, _, d1e = delims[1]:range()
                        local _, d2s, _, d2e = delims[#delims]:range()
                        raw[#raw + 1] = { s = d1s, e = d1e, repl = 0 }
                        raw[#raw + 1] = { s = d2s, e = d2e, repl = 0 }
                        local mline = line_at(ctx, row)
                        for _, t in ipairs(math_tokens(mline:sub(d1e + 1, d2s), d1e)) do
                            raw[#raw + 1] = { s = t.s, e = t.e, repl = fn.strdisplaywidth(t.repl), rtext = t.repl }
                        end
                    end
                elseif name == "html" and fconf.html ~= nil and fconf.html.enabled then
                    local close = select(1, html_pair(node, ctx.buf))
                    if close ~= nil then
                        local csr2, csc2, _, cec2 = close:range()
                        raw[#raw + 1] = { s = sc, e = ec, repl = 0 }
                        if csr2 == row then
                            raw[#raw + 1] = { s = csc2, e = cec2, repl = 0 }
                        end
                    end
                elseif name == "autolink" and fconf.links ~= nil and fconf.links.enabled then
                    raw[#raw + 1] = { s = sc, e = sc + 1, repl = 0 }
                    raw[#raw + 1] = { s = ec - 1, e = ec, repl = 0 }
                    if fconf.links.icons.auto ~= "" then
                        inserts[#inserts + 1] = {
                            col = sc + 1,
                            width = fn.strdisplaywidth(fconf.links.icons.auto),
                            text = fconf.links.icons.auto,
                        }
                    end
                elseif name == "escape" and fconf.escapes ~= nil and fconf.escapes.enabled then
                    raw[#raw + 1] = { s = sc, e = sc + 1, repl = 0 }
                end
            end
        end
    end

    -- The grammarless scans, mirrored: `==mark==` loses its four cells, `:emoji:` collapses to
    -- one double-width char. Protected by the code/math/autolink ranges already collected.
    do
        local line = line_at(ctx, row)
        local function scan_protected(s0, e0)
            for _, iv in ipairs(raw) do
                if s0 < iv.e and e0 > iv.s then
                    return true
                end
            end
            return false
        end
        if fconf.mark ~= nil and fconf.mark.enabled then
            for s0, _, e0 in line:gmatch("()==([^=]+)==()") do
                if not scan_protected(s0 - 1, e0 - 1) then
                    raw[#raw + 1] = { s = s0 - 1, e = s0 + 1, repl = 0 }
                    raw[#raw + 1] = { s = e0 - 3, e = e0 - 1, repl = 0 }
                end
            end
        end
        if fconf.emoji ~= nil and fconf.emoji.enabled then
            for s0, ename, e0 in line:gmatch("():([%w_%+%-]+):()") do
                local glyph = fconf.emoji.extra[ename] or emoji[ename]
                if glyph ~= nil and fn.strchars(glyph) == 1 and not scan_protected(s0 - 1, e0 - 1) then
                    raw[#raw + 1] = { s = s0 - 1, e = e0 - 1, repl = fn.strdisplaywidth(glyph), rtext = glyph }
                end
            end
        end
    end

    table.sort(raw, function(a, b)
        return a.s < b.s
    end)
    ---@type { s: integer, e: integer, repl: integer }[]
    local merged = {}
    for _, iv in ipairs(raw) do
        local last = merged[#merged]
        if last ~= nil and iv.s < last.e then
            -- Overlapping conceals collapse into one displayed region; the widest wins, the
            -- replacement chars stack at most once each.
            last.e = math.max(last.e, iv.e)
            last.repl = math.max(last.repl, iv.repl)
            last.rtext = last.rtext or iv.rtext
        else
            merged[#merged + 1] = { s = iv.s, e = iv.e, repl = iv.repl, rtext = iv.rtext }
        end
    end
    return merged, inserts
end

--- The rendered TEXT of one single-row span: the source with every concealed interval replaced by
--- what it conceals TO and every inline insertion put where it lands. The same data `span_width`
--- measures, assembled instead of counted — so a wrapped cell shows `󰌷 label`, exactly what the
--- unwrapped one shows, and never the raw `[label](url)`.
---@param line string
---@param scol integer  0-based byte start
---@param ecol integer  0-based byte end (exclusive)
---@param intervals { s: integer, e: integer, repl: integer, rtext: string? }[]
---@param inserts { col: integer, width: integer, text: string? }[]
---@return string
local function span_text(line, scol, ecol, intervals, inserts)
    ---@type string[]
    local out = {}
    local col = scol
    while col < ecol do
        local hit = nil
        for _, iv in ipairs(intervals) do
            if iv.s == col and iv.e > col then
                hit = iv
                break
            end
        end
        for _, ins in ipairs(inserts) do
            if ins.col == col and ins.text ~= nil then
                out[#out + 1] = ins.text
            end
        end
        if hit ~= nil then
            out[#out + 1] = hit.rtext or ""
            col = math.min(hit.e, ecol)
        else
            -- One CHARACTER at a time, not one byte: a Cyrillic or CJK character is several bytes
            -- and slicing it in half would produce mojibake in the box.
            local nxt = vim.str_utfindex(line, "utf-8", col, false)
            local step = vim.str_byteindex(line, "utf-8", nxt + 1, false) - col
            out[#out + 1] = line:sub(col + 1, col + math.max(step, 1))
            col = col + math.max(step, 1)
        end
    end
    return table.concat(out)
end

--- Split `text` into lines no wider than `width` display cells, breaking at spaces where it can
--- and mid-word only when a single word does not fit at all. Returns at least one line.
---@param text string
---@param width integer
---@return string[]
local function wrap_text(text, width)
    if width < 1 then
        return { text }
    end
    ---@type string[]
    local lines, current = {}, ""
    local function flush()
        lines[#lines + 1] = current
        current = ""
    end
    for word in text:gmatch("%S+") do
        local candidate = current == "" and word or (current .. " " .. word)
        if fn.strdisplaywidth(candidate) <= width then
            current = candidate
        else
            if current ~= "" then
                flush()
            end
            -- A word longer than the column is cut at the last character that still fits, and the
            -- remainder continues on the next line — the alternative is a box that silently grows.
            while fn.strdisplaywidth(word) > width do
                local take = width
                while take > 0 and fn.strdisplaywidth(fn.strcharpart(word, 0, take)) > width do
                    take = take - 1
                end
                lines[#lines + 1] = fn.strcharpart(word, 0, take)
                word = fn.strcharpart(word, take)
            end
            current = word
        end
    end
    if current ~= "" or #lines == 0 then
        flush()
    end
    return lines
end

--- Rendered display width of one single-row span, given its row's adjustments.
---@param line string
---@param scol integer
---@param ecol integer
---@param intervals { s: integer, e: integer, repl: integer }[]
---@param inserts { col: integer, width: integer }[]
---@return integer
local function span_width(line, scol, ecol, intervals, inserts)
    local width = fn.strdisplaywidth(line:sub(scol + 1, ecol))
    for _, iv in ipairs(intervals) do
        local s, e = math.max(iv.s, scol), math.min(iv.e, ecol)
        if s < e then
            width = width - fn.strdisplaywidth(line:sub(s + 1, e)) + iv.repl
        end
    end
    for _, ins in ipairs(inserts) do
        if ins.col >= scol and ins.col < ecol then
            local hidden = false
            for _, iv in ipairs(intervals) do
                if ins.col > iv.s and ins.col < iv.e then
                    hidden = true
                end
            end
            if not hidden then
                width = width + ins.width
            end
        end
    end
    return width
end

--- One horizontal border line: left + ─(width+2) + mid + … + right, as virt chunks.
---@param borders LvimRenderTableBorders
---@param cols integer[]
---@param left string
---@param mid string
---@param right string
---@return [string, string][]
local function border_line(borders, cols, left, mid, right)
    local parts = { left }
    for i, w in ipairs(cols) do
        parts[#parts + 1] = borders.horizontal:rep(w + 2)
        parts[#parts + 1] = i < #cols and mid or right
    end
    return { { table.concat(parts), "LvimRenderTableBorder" } }
end

--- Shrink the columns until the assembled box fits `avail`, then split every cell across as many
--- lines as its column now needs. WHY SHRINK THE WIDEST: taking a cell from the widest column
--- costs the least readability per cell removed, and it converges on columns of similar width
--- rather than starving one of them. `min_col` is the floor — below it a column holds nothing.
---@param info LvimRenderTableInfo
---@param avail integer
---@param tconf LvimRenderTablesConfig
---@return { cols: integer[], rows: table<integer, string[][]>, total: integer }|nil
local function fit_layout(info, avail, tconf)
    local cols = {}
    for i, w in ipairs(info.cols) do
        cols[i] = w
    end
    if #cols == 0 then
        return nil
    end
    -- The width is MEASURED off the border this very renderer draws, never recomputed from a
    -- formula: an arithmetic that drifts from the drawing by one cell is a box that wraps.
    local function box_width()
        return fn.strdisplaywidth(
            border_line(tconf.borders, cols, tconf.borders.top_left, tconf.borders.top_mid, tconf.borders.top_right)[1][1]
        )
    end
    local total = box_width()
    while total > avail do
        local widest, at = 0, nil
        for i, w in ipairs(cols) do
            if w > widest then
                widest, at = w, i
            end
        end
        -- Every column is already at the floor: the window is too narrow for a box at all, and
        -- the caller falls back to the degraded form rather than drawing a broken one.
        if at == nil or widest <= tconf.min_col then
            return nil
        end
        cols[at] = cols[at] - 1
        total = box_width()
    end

    ---@type table<integer, string[][]>
    local rows = {}
    for offset, texts in pairs(info.text) do
        local cells = {}
        for i = 1, #cols do
            cells[i] = wrap_text(texts[i] or "", cols[i])
        end
        rows[offset] = cells
    end
    return { cols = cols, rows = rows, total = total }
end

---@class LvimRenderTableInfo
---@field gen integer
---@field degraded boolean
---@field cols integer[]           column widths (rendered cells, the widest wins)
---@field aligns ("left"|"center"|"right")[]
---@field cells table<integer, integer[]>  row offset from table start → that row's cell widths
---@field total integer            the assembled box width
---@field text table<integer, string[]>  row offset → that row's RENDERED cell texts, kept only
---   when the box may have to be re-laid out narrower (the wrapped mode below)
---@field fit { cols: integer[], rows: table<integer, string[][]>, total: integer }|nil  the
---   WRAPPED layout: columns shrunk to the window and each cell split across as many lines as it
---   needs. Present only when the natural box does not fit and the window wraps
---@field fit_width integer|nil   the available width `fit` was computed FOR. The analysis proper
---   is window-independent and cached per edit; this one is not — it is recomputed whenever the
---   text area's width differs from the value it was built for

--- Analyse a table: every cell's RENDERED width, column maxima, alignment. Cached per buffer
--- generation — the full scan runs once per edit, not once per redraw (the 200×10 benchmark's
--- whole point).
---@param ctx LvimRenderWalkCtx
---@param node TSNode
---@param ichild vim.treesitter.LanguageTree|nil
---@param iq vim.treesitter.Query|nil
---@return LvimRenderTableInfo
local function analyze_table(ctx, node, ichild, iq)
    local st = state.get(ctx.buf)
    local tconf = ctx.fconf.tables --[[@as LvimRenderTablesConfig]]
    local sr = node:range()
    local key = tostring(sr)
    ---@type LvimRenderTableInfo|nil
    local cached = st ~= nil and st.tables[key] or nil
    if cached ~= nil and cached.gen == (st and st.generation or -1) then
        return cached
    end

    ---@type LvimRenderTableInfo
    local info =
        { gen = st and st.generation or 0, degraded = false, cols = {}, aligns = {}, cells = {}, text = {}, total = 0 }

    ---@type TSNode[]
    local row_nodes = {}
    ---@type TSNode|nil
    local delimiter = nil
    for child in node:iter_children() do
        local kind = child:type()
        if kind == "pipe_table_header" or kind == "pipe_table_row" then
            row_nodes[#row_nodes + 1] = child
        elseif kind == "pipe_table_delimiter_row" then
            delimiter = child
        end
    end

    if #row_nodes > tconf.max_rows then
        info.degraded = true
    else
        -- The walk's own parse is WINDOWED, but this analysis is whole-table: the injections
        -- for rows below the viewport may not exist yet (measured live: a table opened with its
        -- tail off screen cached RAW widths for the unparsed rows — 55-column links). Parse the
        -- table's own range before measuring; the cap above bounds the cost.
        do
            local sr0, _, er0 = node:range()
            local okp, parser = pcall(ts.get_parser, ctx.buf, (st and st.lang) or "markdown")
            if okp and parser ~= nil then
                parser:parse({ sr0, er0 })
            end
        end
        for _, row_node in ipairs(row_nodes) do
            local row = row_node:range()
            local line = line_at(ctx, row)
            local intervals, inserts = {}, {}
            if ichild ~= nil and iq ~= nil then
                intervals, inserts = row_adjustments(ctx, ichild, iq, row)
            end
            local widths, texts = {}, {}
            local col_index = 0
            for cell in row_node:iter_children() do
                if cell:type() == "pipe_table_cell" then
                    col_index = col_index + 1
                    local _, sc, _, ec = cell:range()
                    -- TRIMMED content: a manually space-padded source table must reflow to
                    -- content-sized columns (the emitter conceals the trailing run), or the raw
                    -- padding would inflate every column it touches.
                    local cell_text = line:sub(sc + 1, ec)
                    local content_len = #(cell_text:gsub("%s+$", ""))
                    local w = span_width(line, sc, sc + content_len, intervals, inserts)
                    widths[col_index] = w
                    texts[col_index] = span_text(line, sc, sc + content_len, intervals, inserts)
                    info.cols[col_index] = math.max(info.cols[col_index] or tconf.min_col, w)
                end
            end
            info.cells[row - sr] = widths
            info.text[row - sr] = texts
        end
        if delimiter ~= nil then
            local col_index = 0
            for cell in delimiter:iter_children() do
                if cell:type() == "pipe_table_delimiter_cell" then
                    col_index = col_index + 1
                    local has_left, has_right = false, false
                    for mark in cell:iter_children() do
                        local kind = mark:type()
                        if kind == "pipe_table_align_left" then
                            has_left = true
                        elseif kind == "pipe_table_align_right" then
                            has_right = true
                        end
                    end
                    info.aligns[col_index] = (has_left and has_right) and "center" or (has_right and "right") or "left"
                end
            end
        end
        info.total = 1
        for _, w in ipairs(info.cols) do
            info.total = info.total + 1 + w + 1
        end
        if info.total > tconf.max_width then
            info.degraded = true
        end
    end

    if st ~= nil then
        st.tables[key] = info
    end
    return info
end

--- One row of the wrapped box: `│ cell │ cell │`, every cell padded to its column and aligned.
---@param fit { cols: integer[], rows: table<integer, string[][]>, total: integer }
---@param borders LvimRenderTableBorders
---@param cells string[][]  per column, its wrapped lines
---@param line integer      which wrapped line to draw (1 = the first)
---@param aligns ("left"|"center"|"right")[]
---@param body_hl string    the highlight for the cell TEXT (the header row differs)
---@param cursor boolean?   this is the row the cursor is on — paint it like the cursor line
---@return [string, string][]
local function wrapped_row(fit, borders, cells, line, aligns, body_hl, cursor)
    -- The BORDERS are never tinted — the mark lives in the CELLS, exactly like the header band
    -- does. A highlight drawn across the whole row would paint over the box's own glyphs and the
    -- table would lose its frame on whichever row you happen to be on.
    local border_hl = "LvimRenderTableBorder"
    if cursor then
        -- A HEADER row is already a coloured band: it raises its own tint rather than taking the
        -- editor's CursorLine, which would swap its colour instead of marking it. A body row has
        -- no colour of its own, so there the cursor line IS the mark.
        body_hl = body_hl == "LvimRenderTableHead" and "LvimRenderTableHeadCursor" or "LvimRenderTableCursor"
    end
    ---@type [string, string][]
    local chunks = { { borders.vertical, border_hl } }
    for i, width in ipairs(fit.cols) do
        local text = (cells[i] or {})[line] or ""
        local slack = width - fn.strdisplaywidth(text)
        local align = aligns[i] or "left"
        local head = align == "right" and slack or align == "center" and math.floor(slack / 2) or 0
        chunks[#chunks + 1] = { " " .. string.rep(" ", head) .. text .. string.rep(" ", slack - head) .. " ", body_hl }
        chunks[#chunks + 1] = { borders.vertical, border_hl }
    end
    return chunks
end

--- Draw the table with its columns shrunk to the window and its cells wrapped. Returns false when
--- it declines, so the caller falls back to the ordinary rendering.
---
--- WHY THE WHOLE BOX IS VIRTUAL, and hangs off ONE row. Two measured facts leave no other shape:
---
---   * A range `conceal` hides a line's CHARACTERS but not its screen rows — a 94-column line in a
---     70-column window still occupies two rows with every character concealed. So the source rows
---     cannot be overlaid one-for-one: each would keep its own wrapped height and the box would
---     grow a blank row under every line of it.
---   * `conceal_lines` DOES remove a line from the display — and virtual lines attached to such a
---     row do not draw at all. So the rows are hidden with `conceal_lines` and the box hangs from
---     a row that is still there: the blank line above the table, which every table is written
---     after and which nothing else writes to.
---
--- THE CURSOR INSIDE THE TABLE PUTS THE BOX AWAY. You then edit the table's own lines, in their own
--- place, exactly as if it were never boxed — the same bargain the reveal makes for every other
--- element. Showing only the cursor's row instead was tried and is worse: the box occupies the
--- anchor row's virtual space, so the un-hidden row appears BELOW the whole box rather than at its
--- place inside it, and you edit a line detached from the table it belongs to.
---@param ctx LvimRenderWalkCtx
---@param node TSNode
---@param info LvimRenderTableInfo
---@return boolean drawn
local function emit_table_wrapped(ctx, node, info)
    local tconf = ctx.fconf.tables --[[@as LvimRenderTablesConfig]]
    local sr, _, er, ec = node:range()
    local end_row = ec == 0 and er - 1 or er

    -- The recorded span is this table's own entry, cleared and set BY THIS TABLE — never a
    -- wholesale reset per pass. The walk is windowed and runs many times per second; a reset
    -- would leave the record depending on whichever pass happened to run last, and the cursor
    -- hiding that reads it would flicker with it.
    local bst = state.get(ctx.buf)
    local function record(last)
        if bst == nil then
            return
        end
        bst.boxed = bst.boxed or {}
        bst.boxed[sr] = last
    end

    local fit = info.fit
    if fit == nil then
        record(nil)
        return false
    end
    -- No row above to hang from: this shape cannot draw there, so the ordinary rendering takes it.
    if sr == 0 then
        record(nil)
        return false
    end

    ---@type TSNode[]
    local rows = {}
    ---@type TSNode|nil
    local delimiter = nil
    for child in node:iter_children() do
        local kind = child:type()
        if kind == "pipe_table_header" or kind == "pipe_table_row" then
            rows[#rows + 1] = child
        elseif kind == "pipe_table_delimiter_row" then
            delimiter = child
        end
    end
    if #rows == 0 then
        record(nil)
        return false
    end

    -- THE WHOLE TABLE IS CLAIMED, however little of it is on screen. Neovim draws a virtual block
    -- whose anchor has scrolled above the viewport — measured: with the anchor on line 10 and the
    -- window top at 11, rows 14..19 of a 30-line block were on screen, and Ctrl-E moved through it
    -- one row at a time. So the box needs no "fully visible" rule; what it needs is for the lane
    -- that reconciles its marks to look at every row it owns, which is what this span asks for.
    ctx.extend = ctx.extend or { first = sr - 1, last = end_row }
    ctx.extend.first = math.min(ctx.extend.first, sr - 1)
    ctx.extend.last = math.max(ctx.extend.last, end_row)

    -- WHICH ROW READS AS ACTIVE. Two sources, in order: the WIDGET index when the reader is
    -- walking this table (the real cursor is parked on the displayed row above it, so there is no
    -- cursor row to read), and otherwise the real cursor's own row — it can still land inside by a
    -- search or a `:N`. Neovim draws no 'cursorline' over virtual lines either way, so the box
    -- paints its own active row or none is visible at all.
    local bst = state.get(ctx.buf)
    local active = bst ~= nil and bst.box_active or nil
    local widget_index = (active ~= nil and active.first == sr) and active.index or nil
    local cursor = ctx.win == api.nvim_get_current_win() and (api.nvim_win_get_cursor(ctx.win)[1] - 1) or -1

    ---@type [string, string][][]
    local lines = {}
    ---@type integer|nil  which entry of `lines` carries the active row
    local active_at = nil
    if tconf.box then
        lines[#lines + 1] =
            border_line(tconf.borders, fit.cols, tconf.borders.top_left, tconf.borders.top_mid, tconf.borders.top_right)
    end
    for index, row_node in ipairs(rows) do
        local row = row_node:range()
        local cells = fit.rows[row - sr] or {}
        local height = 1
        for _, wrapped in pairs(cells) do
            height = math.max(height, #wrapped)
        end
        local body_hl = (index == 1 and tconf.head) and "LvimRenderTableHead" or "Normal"
        local on_cursor = widget_index ~= nil and index == widget_index or (widget_index == nil and row == cursor)
        for line = 1, height do
            lines[#lines + 1] = wrapped_row(fit, tconf.borders, cells, line, info.aligns, body_hl, on_cursor)
            if on_cursor and active_at == nil then
                active_at = #lines
            end
        end
        if index == 1 and delimiter ~= nil then
            lines[#lines + 1] = border_line(
                tconf.borders,
                fit.cols,
                tconf.borders.mid_left,
                tconf.borders.cross,
                tconf.borders.mid_right
            )
        end
    end
    if tconf.box then
        lines[#lines + 1] = border_line(
            tconf.borders,
            fit.cols,
            tconf.borders.bottom_left,
            tconf.borders.bottom_mid,
            tconf.borders.bottom_right
        )
    end

    -- PAGINATION. The block is one extmark's worth of virtual lines and Neovim scrolls it as part
    -- of the anchor row, which the cursor never leaves — so a table taller than the window would
    -- walk its active row straight off the bottom with nothing to scroll. A widget paginates
    -- itself: when the block does not fit, only a WINDOW of it is drawn, positioned so the active
    -- row is always inside, and walking the index is what moves that window. The borders are kept
    -- at both ends, since a box whose frame scrolls away stops reading as a box.
    --
    -- ONLY WHILE IT IS BEING WALKED. A box nobody is walking is drawn WHOLE however tall it is:
    -- its rows scroll with the buffer like any other virtual lines, so paginating one would do
    -- nothing but cut its last rows off the document (measured — a 34-row table read as ending at
    -- "Nginx"). The window is a navigation aid, not a rendering limit.
    local budget = math.max(4, (active ~= nil and active.avail) or (api.nvim_win_get_height(ctx.win) - 3))
    if widget_index ~= nil and #lines > budget then
        local body_first = tconf.box and 2 or 1
        local body_last = tconf.box and (#lines - 1) or #lines
        local room = budget - (tconf.box and 2 or 0)
        local centre = active_at or body_first
        local first = math.max(body_first, math.min(centre - math.floor(room / 2), body_last - room + 1))
        ---@type [string, string][][]
        local paged = {}
        if tconf.box then
            paged[#paged + 1] = lines[1]
        end
        for i = first, math.min(first + room - 1, body_last) do
            paged[#paged + 1] = lines[i]
        end
        if tconf.box then
            paged[#paged + 1] = lines[#lines]
        end
        lines = paged
    end

    op(ctx, sr - 1, 0, { virt_lines = lines })
    -- Its rows are hidden, so the hardware cursor standing in them has nothing to stand ON: the
    -- engine reads this span and hides it while the cursor is inside (the box paints the active
    -- row itself, which is what you actually navigate by). The ROW COUNT rides along, because the
    -- widget index needs to know where the table ends and the buffer resumes.
    record(end_row)
    if bst ~= nil then
        bst.box_rows = bst.box_rows or {}
        bst.box_rows[sr] = #rows
    end
    for row = sr, end_row do
        op(ctx, row, 0, { conceal_lines = "" })
        -- The rows belong to the box: the inline pass would otherwise decorate text that is not
        -- on screen, and the cell text the box draws already carries those icons (`span_text`).
        ctx.skip_rows[row] = true
    end
    return true
end

---@param ctx LvimRenderWalkCtx
---@param node TSNode
---@param ichild vim.treesitter.LanguageTree|nil
---@param iq vim.treesitter.Query|nil
local function emit_table(ctx, node, ichild, iq)
    local tconf = ctx.fconf.tables
    if tconf == nil or not tconf.enabled then
        return
    end
    local sr, _, er, ec = node:range()
    local end_row = ec == 0 and er - 1 or er

    local info = analyze_table(ctx, node, ichild, iq)

    -- The wrapped layout depends on the WINDOW, and the analysis above is cached per EDIT, so it
    -- cannot live in there: computed once per width instead, and rebuilt when the width changes.
    -- (It was cached with the analysis at first, and picked up a text width measured before the
    -- gutter existed — 79 instead of 72 — which stuck for the rest of the generation and drew a
    -- box seven cells too wide. The width is part of the key now, so a resize re-lays it out too.)
    if not info.degraded and tconf.wrap_cells and vim.wo[ctx.win].wrap then
        local avail = text_width(ctx)
        if info.fit_width ~= avail then
            info.fit_width = avail
            -- ALWAYS, under a wrapping window — not only when the natural box is too wide. The
            -- ordinary rendering pads the cells INSIDE the source line, so the line keeps its own
            -- length: a 94-column row still needs two screen rows in a 111-column window even
            -- though the box it draws is only 91 wide (measured). Under 'wrap' there is no way to
            -- stop that from a decoration, so the box takes over the drawing entirely and the
            -- source rows are hidden. `fit_layout` shrinks nothing when the columns already fit,
            -- so a table that was fine stays exactly as wide as it was.
            info.fit = fit_layout(info, avail, tconf)
        end
    elseif info.fit ~= nil then
        info.fit, info.fit_width = nil, nil
    end

    -- THE WRAPPED BOX. A table too wide for a wrapping window is re-laid out narrower, with each
    -- cell split across as many lines as its column needs — so the box always fits and 'wrap'
    -- never touches it. ('wrap' is a WINDOW option; there is no per-line wrapping in Neovim, so
    -- fitting the box is the only way to keep a wrapped document and an intact table together.)
    --
    -- It is drawn WHOLE as virtual lines, because a wrapped cell needs more screen rows than its
    -- source row has. Anchored on the table's FIRST row, whose own text is concealed and whose
    -- cells the top border overlays; every following row is hidden with `conceal_lines`. That
    -- order is forced, not chosen: virtual lines attached to a `conceal_lines` row do not draw at
    -- all (measured), so the anchor must be a row that is still there.
    -- THE BOX IS TRIED BEFORE THE REVEAL, and that order is the point. Entering insert reveals the
    -- element under the cursor everywhere else, because there you edit the buffer's own text — but
    -- a boxed table is NOT edited in the buffer: its rows are hidden and the editor
    -- (`:LvimRender table`) is where its cells are changed. Revealing it would tear the box apart
    -- for an edit that does not happen there. `tables_box_reveal` restores the old behaviour for
    -- anyone who wants it.
    local box_first = not config.tables_box_reveal
    if box_first and not info.degraded and info.fit ~= nil and emit_table_wrapped(ctx, node, info) then
        return
    end

    -- Whole-element reveal, and the reveal SPAN grows to the whole table so the inline pass
    -- (which runs after the block pass) reveals the cell contents too — a table is one element,
    -- half a box is unreadable.
    if ctx.reveal ~= nil and sr <= ctx.reveal.last and end_row >= ctx.reveal.first then
        revealed(ctx, sr, end_row)
        ctx.reveal.first = math.min(ctx.reveal.first, sr)
        ctx.reveal.last = math.max(ctx.reveal.last, end_row)
        return
    end

    if not info.degraded and info.fit ~= nil then
        if emit_table_wrapped(ctx, node, info) then
            return
        end
        -- The box could not be put up (the table is taller than the window, so its anchor row is
        -- off screen and the block could never be taken down again). Under 'wrap' the in-place
        -- rendering is not an alternative — it pads INSIDE the source line, which then wraps and
        -- comes apart — so the table is left as its own plain text. The all-or-nothing rule this
        -- renderer already follows for a box that cannot fit, applied to a box that cannot hang.
        return
    end

    -- The degrade rule includes the live window: a box wider than the text area cannot draw.
    local degraded = info.degraded or info.total > text_width(ctx)

    for child in node:iter_children() do
        local kind = child:type()
        local row = child:range()
        if row >= ctx.first and row <= ctx.last then
            if kind == "pipe_table_delimiter_row" then
                if degraded then
                    -- Styled in place: every `-`/`:` cell overlaid by the horizontal glyph at
                    -- its OWN width, pipes concealed to the vertical glyph — borders aligned to
                    -- the text as written.
                    for cell in child:iter_children() do
                        if cell:type() == "pipe_table_delimiter_cell" then
                            local _, csc, _, cec = cell:range()
                            op(ctx, row, csc, {
                                virt_text = { { tconf.borders.horizontal:rep(cec - csc), "LvimRenderTableBorder" } },
                                virt_text_pos = "overlay",
                                hl_mode = "combine",
                            })
                        end
                    end
                    for pipe in child:iter_children() do
                        if not pipe:named() and pipe:type() == "|" then
                            local _, pc = pipe:range()
                            op(ctx, row, pc, {
                                end_col = pc + 1,
                                conceal = tconf.borders.vertical,
                                hl_group = "LvimRenderTableBorder",
                            })
                        end
                    end
                else
                    -- The raw delimiter text vanishes whole (a manually padded source row can be
                    -- longer than the drawn line, and its tail would peek out past an overlay);
                    -- the drawn junction line floats over the collapsed row.
                    op(ctx, row, 0, { end_col = #line_at(ctx, row), conceal = "" })
                    op(ctx, row, 0, {
                        virt_text = border_line(
                            tconf.borders,
                            info.cols,
                            tconf.borders.mid_left,
                            tconf.borders.cross,
                            tconf.borders.mid_right
                        ),
                        virt_text_pos = "overlay",
                        hl_mode = "combine",
                    })
                end
            elseif kind == "pipe_table_header" or kind == "pipe_table_row" then
                if kind == "pipe_table_header" and tconf.head and not degraded then
                    op(ctx, row, 0, {
                        end_row = row + 1,
                        end_col = 0,
                        hl_group = "LvimRenderTableHead",
                        hl_eol = false,
                        hl_mode = "combine",
                        priority = config.priorities.band,
                    })
                end
                -- Pipes become the vertical border glyph via CONCEAL, never an overlay: an
                -- overlay anchored at the same byte as an inline pad paints over the pad and
                -- leaves the raw pipe beside it (measured on a manually padded source table).
                local pipes = {}
                for pipe in child:iter_children() do
                    if not pipe:named() and pipe:type() == "|" then
                        local _, pc = pipe:range()
                        pipes[#pipes + 1] = pc
                        op(ctx, row, pc, {
                            end_col = pc + 1,
                            conceal = tconf.borders.vertical,
                            hl_group = "LvimRenderTableBorder",
                        })
                    end
                end
                if not degraded then
                    -- Cell padding to the column width, distributed by the column's alignment.
                    -- The pad targets the ABSOLUTE distance between pipes (1 leading space +
                    -- column width + 1 trailing space), so a source row written without the
                    -- cosmetic spaces still lines up.
                    local widths = info.cells[row - sr] or {}
                    local col_index = 0
                    for cell in child:iter_children() do
                        if cell:type() == "pipe_table_cell" then
                            col_index = col_index + 1
                            local _, csc, _, cec = cell:range()
                            -- The source's own trailing padding vanishes; the box pads instead.
                            local cell_text = line_at(ctx, row):sub(csc + 1, cec)
                            local content_end = csc + #(cell_text:gsub("%s+$", ""))
                            if cec > content_end then
                                op(ctx, row, content_end, { end_col = cec, conceal = "" })
                            end
                            local target = info.cols[col_index] or tconf.min_col
                            local lead = csc - (pipes[col_index] or 0) - 1
                            local pad = (1 + target + 1) - lead - (widths[col_index] or 0)
                            if pad > 0 then
                                local align = info.aligns[col_index] or "left"
                                local head_pad = align == "right" and pad - 1
                                    or align == "center" and math.floor((pad - 1) / 2)
                                    or 0
                                local tail_pad = pad - head_pad
                                if head_pad > 0 then
                                    op(ctx, row, csc, {
                                        virt_text = { { string.rep(" ", head_pad), "LvimRenderTableBorder" } },
                                        virt_text_pos = "inline",
                                    })
                                end
                                if tail_pad > 0 then
                                    op(ctx, row, cec, {
                                        virt_text = { { string.rep(" ", tail_pad), "LvimRenderTableBorder" } },
                                        virt_text_pos = "inline",
                                    })
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    if tconf.box and not degraded then
        -- Top and bottom border lines, as virtual lines — persistent lane: ephemeral
        -- virt_lines are silently not drawn (measured).
        if sr >= ctx.first - 1 and sr <= ctx.last + 1 then
            op(ctx, sr, 0, {
                virt_lines = {
                    border_line(
                        tconf.borders,
                        info.cols,
                        tconf.borders.top_left,
                        tconf.borders.top_mid,
                        tconf.borders.top_right
                    ),
                },
                virt_lines_above = true,
            })
        end
        if end_row >= ctx.first - 1 and end_row <= ctx.last + 1 then
            op(ctx, end_row, 0, {
                virt_lines = {
                    border_line(
                        tconf.borders,
                        info.cols,
                        tconf.borders.bottom_left,
                        tconf.borders.bottom_mid,
                        tconf.borders.bottom_right
                    ),
                },
            })
        end
    end
end

---@param ctx LvimRenderWalkCtx
---@param node TSNode
local function emit_math(ctx, node)
    local sr, sc, er, ec = node:range()
    if revealed(ctx, sr, er) then
        return
    end
    ---@type TSNode[]
    local delims = {}
    for child in node:iter_children() do
        if child:type() == "latex_span_delimiter" then
            delims[#delims + 1] = child
        end
    end
    if #delims < 2 then
        return
    end
    local _, d1s, _, d1e = delims[1]:range()
    local d2r, d2s, _, d2e = delims[#delims]:range()
    local block = (d1e - d1s) >= 2 -- $$ … $$
    local mconf = block and config.math.block or config.math.inline
    if not mconf.enabled then
        return
    end

    -- Delimiters conceal; a block's `$$` rows become empty banded rows.
    op(ctx, sr, d1s, { end_col = d1e, conceal = "" })
    op(ctx, d2r, d2s, { end_col = d2e, conceal = "" })

    if block then
        if config.math.block.band then
            for row = math.max(sr, ctx.first), math.min(er, ctx.last) do
                op(ctx, row, 0, {
                    end_row = row + 1,
                    end_col = 0,
                    hl_group = "LvimRenderMath",
                    hl_eol = true,
                    hl_mode = "combine",
                    priority = config.priorities.band,
                })
            end
        end
        if config.math.block.label ~= "" then
            op(ctx, sr, 0, {
                virt_text = { { config.math.block.label, "LvimRenderMathLabel" } },
                virt_text_pos = "right_align",
                hl_mode = "combine",
            })
        end
    end

    -- Substitute per row of the span (the segment between the delimiters on each line).
    for row = math.max(sr, ctx.first), math.min(d2r, ctx.last) do
        local line = line_at(ctx, row)
        local seg_s = row == sr and d1e or 0
        local seg_e = row == d2r and d2s or #line
        if seg_e > seg_s then
            for _, t in ipairs(math_tokens(line:sub(seg_s + 1, seg_e), seg_s)) do
                op(ctx, row, t.s, { end_col = t.e, conceal = t.repl, hl_group = "LvimRenderMathSymbol" })
            end
        end
    end
end

-- ── typst: the elements markdown has no counterpart for ──────────────────────
--
-- Typst's math is NATIVE, not an injected LaTeX span, so it is read from the TREE rather than
-- scanned as text: `alpha` is an `ident` inside a `formula`, `x^2` is an `attach` node. The
-- substitution still runs through the SHARED symbol table — typst spells the same symbols as
-- LaTeX does without the backslash (`alpha` ↔ `\alpha`), so one table serves both and the
-- single-character ceiling of §math holds unchanged: what has no one-char rendering stays raw.

--- Substitute one typst formula's symbols and scripts.
---@param ctx LvimRenderWalkCtx
---@param formula TSNode
---@return nil
local function typst_formula(ctx, formula)
    local maps = get_math_maps()
    ---@param node TSNode
    local function walk(node)
        local kind = node:type()
        if kind == "ident" then
            local repl = maps.symbols["\\" .. ts.get_node_text(node, ctx.buf)]
            if repl ~= nil and fn.strchars(repl) == 1 then
                local r, c, _, ec = node:range()
                op(ctx, r, c, { end_col = ec, conceal = repl, hl_group = "LvimRenderMathSymbol" })
            end
            return
        end
        if kind == "attach" then
            -- `x^2` / `y_1`: the operator and its ONE-character argument conceal together into the
            -- superscript/subscript glyph. A longer argument has no single-char rendering and is
            -- left exactly as written.
            local prev = nil
            for child in node:iter_children() do
                local ckind = child:type()
                if ckind == "^" or ckind == "_" then
                    prev = { kind = ckind, node = child }
                elseif prev ~= nil then
                    local text = ts.get_node_text(child, ctx.buf)
                    local map = prev.kind == "^" and maps.sup or maps.sub
                    local repl = #text == 1 and map[text] or nil
                    if repl ~= nil then
                        local r, c = prev.node:range()
                        local _, _, _, ec = child:range()
                        op(ctx, r, c, { end_col = ec, conceal = repl, hl_group = "LvimRenderMathSymbol" })
                    else
                        walk(child)
                    end
                    prev = nil
                else
                    walk(child)
                end
            end
            return
        end
        for child in node:iter_children() do
            walk(child)
        end
    end
    walk(formula)
end

--- A typst `$…$`. BLOCK vs INLINE is typst's own rule, not a second delimiter: `$ x $` (spaces
--- inside the dollars) is display math, `$x$` is inline. A multi-row span is display either way.
---@param ctx LvimRenderWalkCtx
---@param node TSNode
local function emit_typst_math(ctx, node)
    local sr, _, er = node:range()
    if revealed(ctx, sr, er) then
        return
    end
    ---@type TSNode[], TSNode|nil
    local delims, formula = {}, nil
    for child in node:iter_children() do
        local kind = child:type()
        if kind == "$" then
            delims[#delims + 1] = child
        elseif kind == "formula" then
            formula = child
        end
    end
    if #delims < 2 or formula == nil then
        return
    end
    local _, d1s, _, d1e = delims[1]:range()
    local d2r, d2s, _, d2e = delims[#delims]:range()
    local fsr, fsc, fer = formula:range()
    local block = er > sr or fsc > d1e or (fsr == d2r and fer == d2r and fsc > d1e)
    -- The gap before the closing dollar counts too — `$x $` is display math in typst.
    if not block then
        local _, _, _, fec = formula:range()
        block = d2s > fec
    end
    local mconf = block and config.math.block or config.math.inline
    if not mconf.enabled then
        return
    end

    op(ctx, sr, d1s, { end_col = d1e, conceal = "" })
    op(ctx, d2r, d2s, { end_col = d2e, conceal = "" })

    if block then
        if config.math.block.band then
            for row = math.max(sr, ctx.first), math.min(er, ctx.last) do
                op(ctx, row, 0, {
                    end_row = row + 1,
                    end_col = 0,
                    hl_group = "LvimRenderMath",
                    hl_eol = true,
                    hl_mode = "combine",
                    priority = config.priorities.band,
                })
            end
        end
        if config.math.block.label ~= "" then
            op(ctx, sr, 0, {
                virt_text = { { config.math.block.label, "LvimRenderMathLabel" } },
                virt_text_pos = "right_align",
                hl_mode = "combine",
            })
        end
    end
    typst_formula(ctx, formula)
end

--- A BARE url. Typst writes it with no delimiters at all — unlike markdown's `<…>` autolink —
--- so there is nothing to conceal and the icon is simply placed in front of it.
---@param ctx LvimRenderWalkCtx
---@param node TSNode
local function emit_typst_url(ctx, node)
    local lconf = ctx.fconf.links
    if lconf == nil or not lconf.enabled or lconf.icons.auto == "" then
        return
    end
    local sr, sc, er = node:range()
    if revealed(ctx, sr, er) then
        return
    end
    op(ctx, sr, sc, {
        virt_text = { { lconf.icons.auto, "LvimRenderLink" } },
        virt_text_pos = "inline",
    })
end

--- `<name>` — a typst label. The brackets conceal behind a tag icon; the NAME stays readable,
--- because a label the reader cannot read is a label they cannot reference.
---@param ctx LvimRenderWalkCtx
---@param node TSNode
local function emit_typst_label(ctx, node)
    local lconf = ctx.fconf.labels
    if lconf == nil or not lconf.enabled then
        return
    end
    local sr, sc, er, ec = node:range()
    if revealed(ctx, sr, er) then
        return
    end
    if lconf.conceal then
        op(ctx, sr, sc, { end_col = sc + 1, conceal = "" })
        op(ctx, er, ec - 1, { end_col = ec, conceal = "" })
    end
    if lconf.icon ~= "" then
        op(ctx, sr, sc + 1, {
            virt_text = { { lconf.icon, "LvimRenderLink" } },
            virt_text_pos = "inline",
        })
    end
end

--- `@name` — a reference. The `@` IS the marker, so it conceals to the icon rather than gaining
--- one beside it: one glyph in one cell, no width added to the line.
---@param ctx LvimRenderWalkCtx
---@param node TSNode
local function emit_typst_ref(ctx, node)
    local rconf = ctx.fconf.refs
    if rconf == nil or not rconf.enabled or rconf.icon == "" then
        return
    end
    local sr, sc, er = node:range()
    if revealed(ctx, sr, er) then
        return
    end
    op(ctx, sr, sc, { end_col = sc + 1, conceal = "" })
    op(ctx, sr, sc + 1, {
        virt_text = { { rconf.icon, "LvimRenderLink" } },
        virt_text_pos = "inline",
    })
end

--- `/ Term: description` — typst's definition list. The `/` becomes a glyph and the TERM (the
--- text before the colon) takes the bullet's colour, so the two halves of the row read apart.
---@param ctx LvimRenderWalkCtx
---@param node TSNode
local function emit_typst_term(ctx, node)
    local tconf = ctx.fconf.terms
    if tconf == nil or not tconf.enabled then
        return
    end
    local sr, sc, er = node:range()
    if revealed(ctx, sr, er) then
        return
    end
    ---@type TSNode|nil, TSNode|nil
    local marker, colon = nil, nil
    ---@type TSNode|nil
    local term = nil
    for child in node:iter_children() do
        local kind = child:type()
        if kind == "/" then
            marker = child
        elseif kind == ":" and colon == nil then
            colon = child
        elseif kind == "text" and colon == nil then
            term = child
        end
    end
    if marker ~= nil and tconf.icon ~= "" then
        local mr, mc = marker:range()
        op(ctx, mr, mc, {
            virt_text = { { tconf.icon, "LvimRenderTerm" } },
            virt_text_pos = "overlay",
            hl_mode = "combine",
        })
    end
    if tconf.bold and term ~= nil then
        local tsr, tsc, ter2, tec = term:range()
        -- Above treesitter, like an accent heading title: the term's own bold has to win over the
        -- grammar's `@spell`-plain text or the option would be silently ignored.
        op(ctx, tsr, tsc, {
            end_row = ter2,
            end_col = tec,
            hl_group = "LvimRenderTerm",
            hl_mode = "combine",
            priority = config.priorities.heading_text,
        })
    end
end

-- ── org: markup without markup nodes ─────────────────────────────────────────
--
-- Org's grammar gives its inline markup NO nodes: `*bold*` is a `str` between two bare `*`
-- tokens inside an `expr`, and `*bold text*` splits across two exprs with one token in each.
-- The grammar's own `markup.scm` is written exactly that way — a start token paired with an end
-- token, in one expr or across two — so the pairing is done here, over the whole paragraph, in
-- the same terms.
--
-- WHY PAIRING MATTERS: a lone `*` is multiplication, not emphasis. Concealing every marker token
-- would eat real asterisks out of prose. Only a token that FINDS its partner is concealed; an
-- unmatched one is left exactly as written.
--
-- AND WHY PAIRING ALONE IS NOT ENOUGH: `~/.config/nvim/.snapshots` has two `/` that pair
-- perfectly, and concealing them turns the path into `~.confignvim.snapshots` — a lie about the
-- file's contents (reported from a screenshot; the same bug ate the slashes out of every URL).
-- Org itself does not call those emphasis, because of `org-emphasis-regexp-components`: a marker
-- opens only at a word BOUNDARY (start of line or after whitespace/an opening bracket, and
-- immediately before a non-space) and closes only at one (immediately after a non-space, and
-- before end of line, whitespace or closing punctuation). Those rules are implemented below, and
-- they are what makes a slash in a path different from the `/` in `/italic/`.

---@type table<string, "emphasis"|"code">  org marker token → what it makes
local ORG_MARKERS = {
    ["*"] = "emphasis",
    ["/"] = "emphasis",
    ["_"] = "emphasis",
    ["+"] = "emphasis",
    ["="] = "code",
    ["~"] = "code",
}

-- `org-emphasis-regexp-components`, as org ships them. PRE is what may sit immediately before an
-- OPENING marker, POST what may sit immediately after a CLOSING one; the "border" rule (no space
-- just inside the markers) is the two `%s` tests in the predicates.
local ORG_PRE =
    { [""] = true, [" "] = true, ["\t"] = true, ["-"] = true, ["("] = true, ["{"] = true, ["'"] = true, ['"'] = true }
local ORG_POST = {
    [""] = true,
    [" "] = true,
    ["\t"] = true,
    ["-"] = true,
    ["."] = true,
    [","] = true,
    [":"] = true,
    ["!"] = true,
    ["?"] = true,
    [";"] = true,
    ["'"] = true,
    ['"'] = true,
    [")"] = true,
    ["}"] = true,
    ["["] = true,
    ["]"] = true,
    ["\\"] = true,
}

--- May a marker at [col, ecol) on `line` OPEN an emphasis run? (0-based byte columns.)
---@param line string
---@param col integer
---@param ecol integer
---@return boolean
local function org_can_open(line, col, ecol)
    local before = col > 0 and line:sub(col, col) or ""
    local after = line:sub(ecol + 1, ecol + 1)
    return ORG_PRE[before] == true and after ~= "" and after:match("%s") == nil
end

--- May a marker at [col, ecol) on `line` CLOSE one?
---@param line string
---@param col integer
---@param ecol integer
---@return boolean
local function org_can_close(line, col, ecol)
    local before = col > 0 and line:sub(col, col) or ""
    local after = line:sub(ecol + 1, ecol + 1)
    return before ~= "" and before:match("%s") == nil and ORG_POST[after] == true
end

--- Is this expr an org link (`[[target]]` or `[[target][label]]`)? Returns its parts in byte
--- columns, or nil.
---@param node TSNode
---@param buf integer
---@return { row: integer, s: integer, e: integer, sep: integer|nil, mid: integer|nil }|nil
local function org_link_parts(node, buf)
    local text = ts.get_node_text(node, buf)
    if text:sub(1, 2) ~= "[[" or text:sub(-2) ~= "]]" or text:find("\n") ~= nil then
        return nil
    end
    local row, col = node:range()
    -- `][` splits target from label; without it the whole inside is the target.
    local sep = text:find("][", 3, true)
    return {
        row = row,
        s = col,
        e = col + #text,
        sep = sep ~= nil and (col + sep - 1) or nil,
        mid = sep ~= nil and (col + sep + 1) or nil,
    }
end

--- Emphasis, verbatim/code spans and links inside one org paragraph or headline title.
---@param ctx LvimRenderWalkCtx
---@param node TSNode
local function emit_org_markup(ctx, node)
    local sr, _, er = node:range()
    if revealed(ctx, sr, er) then
        return
    end
    local econf = ctx.fconf.emphasis
    local iconf = ctx.fconf.inline_code
    local lconf = ctx.fconf.links

    ---@type table<string, { row: integer, col: integer, ecol: integer }>
    local open = {}
    for expr in node:iter_children() do
        if expr:type() == "expr" then
            local links_on = lconf ~= nil and lconf.enabled
            local link = links_on and org_link_parts(expr, ctx.buf) or nil
            if link ~= nil and lconf ~= nil then
                if lconf.conceal then
                    if link.mid ~= nil then
                        -- `[[target][label]]`: the target and both bracket runs go, the label stays.
                        op(ctx, link.row, link.s, { end_col = link.mid, conceal = "" })
                        op(ctx, link.row, link.e - 2, { end_col = link.e, conceal = "" })
                    else
                        -- `[[target]]`: only the brackets go — the target IS the visible text.
                        op(ctx, link.row, link.s, { end_col = link.s + 2, conceal = "" })
                        op(ctx, link.row, link.e - 2, { end_col = link.e, conceal = "" })
                    end
                end
                if lconf.icons.link ~= "" then
                    op(ctx, link.row, link.mid or (link.s + 2), {
                        virt_text = { { lconf.icons.link, "LvimRenderLink" } },
                        virt_text_pos = "inline",
                    })
                end
            else
                for token in expr:iter_children() do
                    local kind = ORG_MARKERS[token:type()]
                    if kind ~= nil then
                        local trow, tcol, _, tecol = token:range()
                        local tline = line_at(ctx, trow)
                        local prev = open[token:type()]
                        if prev == nil then
                            -- Only a marker at a word boundary OPENS. Without this the two slashes
                            -- of `~/.config/nvim` pair and the path renders as `~.confignvim`.
                            if org_can_open(tline, tcol, tecol) then
                                open[token:type()] = { row = trow, col = tcol, ecol = tecol }
                            end
                        elseif not org_can_close(tline, tcol, tecol) then
                            -- Not a close either. If it could open, it becomes the new candidate
                            -- (`*a *b*` — the second `*` starts the run that the third finishes);
                            -- otherwise the pending one stands and this token is plain text.
                            if org_can_open(tline, tcol, tecol) then
                                open[token:type()] = { row = trow, col = tcol, ecol = tecol }
                            end
                        else
                            open[token:type()] = nil
                            if kind == "code" then
                                if iconf ~= nil and iconf.enabled then
                                    -- The pill spans marker to marker; the markers themselves
                                    -- conceal to the padding, exactly as markdown's backticks do.
                                    op(ctx, prev.row, prev.col, {
                                        end_row = trow,
                                        end_col = tecol,
                                        hl_group = "LvimRenderCodeInline",
                                        hl_mode = "combine",
                                        priority = config.priorities.band,
                                    })
                                    local pad = iconf.pad ~= "" and iconf.pad or ""
                                    op(ctx, prev.row, prev.col, {
                                        end_col = prev.ecol,
                                        conceal = pad,
                                        hl_group = "LvimRenderCodeInline",
                                    })
                                    op(ctx, trow, tcol, {
                                        end_col = tecol,
                                        conceal = pad,
                                        hl_group = "LvimRenderCodeInline",
                                    })
                                end
                            elseif econf ~= nil and econf.enabled then
                                op(ctx, prev.row, prev.col, { end_col = prev.ecol, conceal = "" })
                                op(ctx, trow, tcol, { end_col = tecol, conceal = "" })
                            end
                        end
                    end
                end
            end
        end
    end
end

--- An org `[ ]` / `[X]` checkbox: a node of its own here, unlike markdown's bare token run.
---@param ctx LvimRenderWalkCtx
---@param node TSNode
local function emit_org_checkbox(ctx, node)
    local cconf = ctx.fconf.checkboxes
    if cconf == nil or not cconf.enabled then
        return
    end
    local sr, sc, _, ec = node:range()
    if revealed(ctx, sr, sr) then
        return
    end
    local text = ts.get_node_text(node, ctx.buf)
    local char = text:sub(2, 2)
    for index, spec in ipairs(cconf.states) do
        if spec.char == char and spec.icon ~= "" then
            op(ctx, sr, sc, { end_col = ec, conceal = spec.icon, hl_group = highlights.checkbox_group(index) })
            return
        end
    end
end

--- An org `#+begin_… / #+end_…` block. Its KIND decides which element it is: `src` (and
--- `example`) is a code block, `quote` is a quote. One node type, two renderings — so the kind is
--- read rather than assumed.
---@param ctx LvimRenderWalkCtx
---@param node TSNode
local function emit_org_block(ctx, node)
    local kind = org_block_kind(node, ctx.buf)
    if kind == "quote" then
        local qconf = ctx.fconf.quotes
        if qconf == nil or not qconf.enabled or qconf.border == "" then
            return
        end
        local sr, _, er, ec = node:range()
        local end_row = ec == 0 and er - 1 or er
        if revealed(ctx, sr, end_row) then
            return
        end
        -- The markers themselves conceal, leaving two blank rows around the quotation: unlike a
        -- code fence there is no language to keep on them, so `#+begin_quote` is pure syntax.
        local delimiters = ctx.shape.code_parts(node, ctx.buf)
        for _, delim in ipairs(delimiters) do
            local dr, dc, _, dec = delim:range()
            op(ctx, dr, dc, { end_col = dec, conceal = "" })
        end
        -- The border is drawn on the CONTENT rows only: the `#+begin_quote` line is the marker,
        -- not part of the quotation, and bordering it would claim otherwise.
        for child in node:iter_children() do
            if child:type() == "contents" then
                local csr, _, cer, cec = child:range()
                local clast = cec == 0 and cer - 1 or cer
                for row = math.max(csr, ctx.first), math.min(clast, ctx.last) do
                    op(ctx, row, 0, {
                        virt_text = { { qconf.border, highlights.quote_group(1) } },
                        virt_text_pos = "inline",
                    })
                end
            end
        end
        return
    end
    emit_codeblock(ctx, node)
end

-- ── the long-tail inline emitters ────────────────────────────────────────────

--- An OPENING basic tag: conceal it, find its close among the following siblings, style the
--- span between and conceal the close. A tag without a close (or outside the basic set —
--- `<sub>`, custom elements) stays raw: honesty over guessing.
---@param ctx LvimRenderWalkCtx
---@param node TSNode
local function emit_html(ctx, node)
    if ctx.fconf.html == nil or not ctx.fconf.html.enabled then
        return
    end
    local sr, sc, er, ec = node:range()
    if revealed(ctx, sr, er) then
        return
    end
    local close, grp = html_pair(node, ctx.buf)
    if close == nil or grp == nil then
        return
    end
    local csr, csc, _, cec = close:range()
    op(ctx, sr, sc, { end_col = ec, conceal = "" })
    op(ctx, csr, csc, { end_col = cec, conceal = "" })
    op(ctx, sr, ec, {
        end_row = csr,
        end_col = csc,
        hl_group = grp,
        hl_mode = "combine",
        priority = config.priorities.band,
    })
end

---@param ctx LvimRenderWalkCtx
---@param node TSNode
local function emit_autolink(ctx, node)
    local lconf = ctx.fconf.links
    if lconf == nil or not lconf.enabled then
        return
    end
    local sr, sc, er, ec = node:range()
    if revealed(ctx, sr, er) then
        return
    end
    op(ctx, sr, sc, { end_col = sc + 1, conceal = "" })
    op(ctx, er, ec - 1, { end_col = ec, conceal = "" })
    if lconf.icons.auto ~= "" then
        op(ctx, sr, sc + 1, {
            virt_text = { { lconf.icons.auto, "LvimRenderLink" } },
            virt_text_pos = "inline",
        })
    end
end

---@param ctx LvimRenderWalkCtx
---@param node TSNode
local function emit_escape(ctx, node)
    local econf = ctx.fconf.escapes
    if econf == nil or not econf.enabled then
        return
    end
    local sr, sc, er = node:range()
    if revealed(ctx, sr, er) then
        return
    end
    -- The backslash goes; the escaped character shows plain.
    op(ctx, sr, sc, { end_col = sc + 1, conceal = "" })
end

--- The refdef line: `[id]: url` gets its icon; the definition stays readable (it is metadata
--- the reader may genuinely want to see).
---@param ctx LvimRenderWalkCtx
---@param node TSNode
local function emit_refdef(ctx, node)
    local rconf = ctx.fconf.refdefs
    if rconf == nil or not rconf.enabled then
        return
    end
    local sr, sc = node:range()
    if revealed(ctx, sr, sr) then
        return
    end
    if rconf.icon ~= "" then
        op(ctx, sr, sc, {
            virt_text = { { rconf.icon, "LvimRenderLink" } },
            virt_text_pos = "inline",
        })
    end
end

--- Frontmatter (`---` YAML / `+++` TOML): a banded block; the injected yaml/toml colours ride
--- on top of a background-only group.
---@param ctx LvimRenderWalkCtx
---@param node TSNode
local function emit_meta(ctx, node)
    local mconf = ctx.fconf.frontmatter
    if mconf == nil or not mconf.enabled then
        return
    end
    local sr, _, er, ec = node:range()
    local end_row = ec == 0 and er - 1 or er
    if revealed(ctx, sr, end_row) then
        return
    end
    for row = math.max(sr, ctx.first), math.min(end_row, ctx.last) do
        op(ctx, row, 0, {
            end_row = row + 1,
            end_col = 0,
            hl_group = "LvimRenderMetadata",
            hl_eol = true,
            hl_mode = "combine",
            priority = config.priorities.band,
        })
    end
end

-- ── the row scans: elements the grammar does not name ────────────────────────
--
-- `==mark==`, `:emoji:` and `#tag` have NO nodes (measured: bare `=`/`:`/`#` anon tokens), so
-- they are found by a per-row scan — guarded by the PROTECTED ranges the inline pass collected
-- (code spans, math spans, autolinks), so a `==` inside `code` is never decorated.

--- Is a byte range inside any protected range of its row?
---@param ctx LvimRenderWalkCtx
---@param row integer
---@param s integer
---@param e integer
---@return boolean
local function protected(ctx, row, s, e)
    for _, r in ipairs(ctx.protect[row] or {}) do
        if s < r[2] and e > r[1] then
            return true
        end
    end
    return false
end

---@param ctx LvimRenderWalkCtx
---@param row integer
local function emit_row_scans(ctx, row)
    if ctx.skip_rows[row] or row_revealed(ctx, row) then
        return
    end
    local fconf = ctx.fconf
    local line = line_at(ctx, row)

    if fconf.mark ~= nil and fconf.mark.enabled then
        for s0, inner, e0 in line:gmatch("()==([^=]+)==()") do
            if not protected(ctx, row, s0 - 1, e0 - 1) then
                op(ctx, row, s0 - 1, { end_col = s0 + 1, conceal = "" })
                op(ctx, row, e0 - 3, { end_col = e0 - 1, conceal = "" })
                op(ctx, row, s0 + 1, {
                    end_col = e0 - 3,
                    hl_group = "LvimRenderMark",
                    hl_mode = "combine",
                    priority = config.priorities.band,
                })
            end
        end
    end

    if fconf.emoji ~= nil and fconf.emoji.enabled then
        for s0, name, e0 in line:gmatch("():([%w_%+%-]+):()") do
            local glyph = fconf.emoji.extra[name] or emoji[name]
            if glyph ~= nil and fn.strchars(glyph) == 1 and not protected(ctx, row, s0 - 1, e0 - 1) then
                op(ctx, row, s0 - 1, { end_col = e0 - 1, conceal = glyph })
            end
        end
    end

    if fconf.tags ~= nil and fconf.tags.enabled then
        for s0, tag, e0 in line:gmatch("()#([%w_/%-]+)()") do
            local before = s0 == 1 and " " or line:sub(s0 - 1, s0 - 1)
            if before:match("%s") and not tag:match("^%d+$") and not protected(ctx, row, s0 - 1, e0 - 1) then
                op(ctx, row, s0 - 1, {
                    end_col = e0 - 1,
                    hl_group = "LvimRenderTag",
                    hl_mode = "combine",
                    priority = config.priorities.band,
                })
            end
        end
    end
end

-- ── inline emitters ──────────────────────────────────────────────────────────

---@param ctx LvimRenderWalkCtx
---@param node TSNode
local function emit_code_span(ctx, node)
    local iconf = ctx.fconf.inline_code
    if iconf == nil or not iconf.enabled then
        return
    end
    local sr, sc, er, ec = node:range()
    if revealed(ctx, sr, er) then
        return
    end
    -- The pill: one range highlight over the whole span (background-only group), delimiters
    -- concealed TO the pad character — the padding cells ARE the old backtick cells.
    op(ctx, sr, sc, {
        end_row = er,
        end_col = ec,
        hl_group = "LvimRenderCodeInline",
        hl_mode = "combine",
        priority = config.priorities.band,
    })
    for child in node:iter_children() do
        if ctx.shape.code_delims[child:type()] then
            local dr, dc, _, dec = child:range()
            op(ctx, dr, dc, {
                end_col = dec,
                conceal = iconf.pad ~= "" and iconf.pad or "",
                hl_group = "LvimRenderCodeInline",
            })
        end
    end
end

---@param ctx LvimRenderWalkCtx
---@param node TSNode
local function emit_emphasis(ctx, node)
    local econf = ctx.fconf.emphasis
    if econf == nil or not econf.enabled then
        return
    end
    local sr, _, er = node:range()
    if revealed(ctx, sr, er) then
        return
    end
    for child in node:iter_children() do
        if ctx.shape.emphasis_delims[child:type()] then
            local dr, dc, _, dec = child:range()
            op(ctx, dr, dc, { end_col = dec, conceal = "" })
        end
    end
end

---@param ctx LvimRenderWalkCtx
---@param node TSNode
---@param image boolean
local function emit_link(ctx, node, image)
    local lconf = ctx.fconf.links
    if lconf == nil or not lconf.enabled then
        return
    end
    local sr, sc, er, ec = node:range()
    if revealed(ctx, sr, er) then
        return
    end
    ---@type TSNode|nil
    local label = nil
    for child in node:iter_children() do
        local kind = child:type()
        if kind == "link_text" or kind == "image_description" then
            label = child
        end
    end
    if label == nil then
        return
    end
    local icon = image and lconf.icons.image or lconf.icons.link
    -- An EMBED (`![[target]]`) parses as an image whose description holds a shortcut link:
    -- descend to the inner text and use the embed icon.
    if image then
        for child in label:iter_children() do
            if child:type() == "shortcut_link" then
                for sub in child:iter_children() do
                    if sub:type() == "link_text" then
                        label = sub
                        icon = lconf.icons.embed
                    end
                end
            end
        end
    end
    local lsr, lsc, ler, lec = label:range()
    if lconf.conceal then
        op(ctx, sr, sc, { end_row = lsr, end_col = lsc, conceal = "" })
        op(ctx, ler, lec, { end_row = er, end_col = ec, conceal = "" })
    end
    if icon ~= "" then
        op(ctx, lsr, lsc, {
            virt_text = { { icon, "LvimRenderLink" } },
            virt_text_pos = "inline",
        })
    end
end

--- A `[[wikilink]]` / `[[target|alias]]`: the grammar sees `[` + shortcut_link + `]`, so the
--- outer brackets are the give-away. Target and pipes conceal, the alias (or the target when
--- there is none) stays behind the wiki icon. A bare `[word]` is NOT a wikilink and gets
--- nothing of ours (its brackets are the runtime's own conceal).
---@param ctx LvimRenderWalkCtx
---@param node TSNode
local function emit_wikilink(ctx, node)
    local lconf = ctx.fconf.links
    if lconf == nil or not lconf.enabled then
        return
    end
    -- An embed's inner shortcut (`![[x]]` → image > image_description > shortcut_link) belongs
    -- to the image emitter; decorating it here too gave the token two icons (measured by the
    -- longtail fixture).
    local parent = node:parent()
    if parent ~= nil and parent:type() == "image_description" then
        return
    end
    local sr, sc, er, ec = node:range()
    if sr ~= er then
        return
    end
    local line = line_at(ctx, sr)
    if line:sub(sc, sc) ~= "[" or line:sub(ec + 1, ec + 1) ~= "]" then
        return
    end
    if revealed(ctx, sr, er) then
        return
    end
    ---@type TSNode|nil
    local label = nil
    for child in node:iter_children() do
        if child:type() == "link_text" then
            label = child
        end
    end
    if label == nil then
        return
    end
    local _, lsc, _, lec = label:range()
    local text = line:sub(lsc + 1, lec)
    local pipe = text:find("|", 1, true)
    local shown = pipe ~= nil and (lsc + pipe) or lsc
    if lconf.conceal then
        op(ctx, sr, sc - 1, { end_col = shown, conceal = "" })
        op(ctx, sr, lec, { end_col = ec + 1, conceal = "" })
    end
    if lconf.icons.wiki ~= "" then
        op(ctx, sr, shown, {
            virt_text = { { lconf.icons.wiki, "LvimRenderLink" } },
            virt_text_pos = "inline",
        })
    end
end

---@param ctx LvimRenderWalkCtx
---@param node TSNode
local function emit_entity(ctx, node)
    local econf = ctx.fconf.entities
    if econf == nil or not econf.enabled then
        return
    end
    local sr, sc, er, ec = node:range()
    if revealed(ctx, sr, er) then
        return
    end
    local name = ts.get_node_text(node, ctx.buf):match("^&(%w+);$")
    local glyph = name ~= nil and (econf.extra[name] or entities[name]) or nil
    -- `conceal` takes exactly one character; a multi-char mapping cannot render and stays raw.
    if glyph ~= nil and fn.strchars(glyph) == 1 then
        op(ctx, sr, sc, { end_row = er, end_col = ec, conceal = glyph })
    end
end

--- The span of the boxed table `row` is inside, or nil. Public: the navigation keys need to know
--- where the box BEGINS (its anchor is the row above `first`) to scroll the view through it.
---@param buf integer
---@param row integer  0-based
---@return { first: integer, last: integer }|nil
function M.boxed_span(buf, row)
    local st = state.get(buf)
    for first, last in pairs(st ~= nil and st.boxed or {}) do
        if row >= first and row <= last then
            return { first = first, last = last }
        end
    end
    return nil
end

--- Is `row` a table SEPARATOR row that a BOX is currently hiding? The box draws its own junction
--- line, so the source's `|---|---|` is a row with nothing of its own on screen — a stop the cursor
--- makes for no reason. Public: the navigation keys ask through here rather than re-deriving it.
---@param buf integer
---@param row integer  0-based
---@return boolean
function M.is_hidden_separator(buf, row)
    local st = state.get(buf)
    if st == nil or st.boxed == nil then
        return false
    end
    local inside = false
    for first, last in pairs(st.boxed) do
        if row >= first and row <= last then
            inside = true
            break
        end
    end
    if not inside then
        return false
    end
    local line = api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
    -- `|---|---|` (markdown, with or without alignment colons) and `|---+---|` (org): a row of
    -- nothing but pipes, dashes, colons and pluses.
    return line ~= nil and line:match("^%s*|[%s%-:+|]+$") ~= nil
end

-- ── the walk ─────────────────────────────────────────────────────────────────

--- Compute the decoration ops for one window's visible rows.
---@param win integer
---@param buf integer
---@param top integer  0-based first visible row
---@param bot integer  0-based last visible row (a guess is fine; extra rows cost nothing)
---@return LvimRenderOp[] ops
---@return { first: integer, last: integer }|nil reveal  the EFFECTIVE raw span for this window
---@return { first: integer, last: integer }|nil extend  rows outside the visible range whose
---   persistent marks this pass owns (a boxed table crossing the viewport edge)
function M.collect(win, buf, top, bot)
    local st = state.get(buf)
    if st == nil or not st.enabled or st.inert ~= nil or st.raw then
        return {}, nil
    end
    local fconf = rawget(config, st.format) --[[@as LvimRenderFormatConfig|nil]]
    if fconf == nil or not fconf.enabled then
        return {}, nil
    end

    -- The reveal applies to the window the cursor is IN; other windows showing the same buffer
    -- have no cursor of the reader's and render fully. A MIRROR never reveals at all, even when
    -- focused: it is a projection of someone else's file, so there is nothing in it to edit and
    -- nothing the reader needs to see raw — showing markers there would defeat its only purpose.
    local current = win == api.nvim_get_current_win() and not require("lvim-render.split").is_mirror(buf)
    local mode = api.nvim_get_mode().mode
    if current and not M.mode_allowed(mode) then
        return {}, nil
    end

    ---@type LvimRenderWalkCtx
    local ctx = {
        buf = buf,
        win = win,
        fconf = fconf,
        shape = SHAPE[st.format] or SHAPE.markdown,
        first = 0,
        last = 0,
        ops = {},
        reveal = nil,
        eff_first = 0,
        eff_last = -1,
        lines = {},
        text_width = nil,
        protect = {},
        skip_rows = {},
        extend = nil,
    }
    if current and M.mode_reveals(mode) then
        local cur = api.nvim_win_get_cursor(win)[1] - 1
        ctx.reveal = { first = cur - config.reveal.lines, last = cur + config.reveal.lines }
        ctx.eff_first, ctx.eff_last = ctx.reveal.first, ctx.reveal.last
    end

    local ok, parser = pcall(ts.get_parser, buf, st.lang)
    if not ok or parser == nil then
        return {}, ctx.reveal
    end

    local last_row = api.nvim_buf_line_count(buf) - 1
    ctx.first = math.max(0, top - M.SLACK)
    ctx.last = math.min(bot + M.SLACK, last_row)

    local trees = parser:parse({ ctx.first, ctx.last })
    local root = trees and trees[1] and trees[1]:root()
    if root == nil then
        return {}, ctx.reveal
    end

    -- The inline layer is resolved up front: the TABLE emitter measures cells through it, and
    -- the inline pass below reuses the same query and trees.
    local ispec = INLINE_SRC[st.format]
    local iq = ispec ~= nil and query_for(inline_queries, st.format, ispec.lang, ispec.src) or nil
    local ichild = iq ~= nil and parser:children()[ispec.lang] or nil

    local bq = query_for(block_queries, st.format, st.lang, BLOCK_SRC[st.format])
    if bq ~= nil then
        for id, node in bq:iter_captures(root, buf, ctx.first, ctx.last + 1) do
            local name = bq.captures[id]
            if name == "heading" then
                emit_heading(ctx, node, false)
            elseif name == "heading_setext" then
                emit_heading(ctx, node, true)
            elseif name == "rule" then
                emit_rule(ctx, node)
            elseif name == "bullet" then
                emit_bullet(ctx, node)
            elseif name == "codeblock" then
                local bsr, _, ber, bec = node:range()
                for r = bsr, (bec == 0 and ber - 1 or ber) do
                    ctx.skip_rows[r] = true
                end
                emit_codeblock(ctx, node)
            elseif name == "quote" then
                emit_quote(ctx, node)
            elseif name == "table" then
                emit_table(ctx, node, ichild, iq)
            elseif name == "meta" then
                local bsr, _, ber, bec = node:range()
                for r = bsr, (bec == 0 and ber - 1 or ber) do
                    ctx.skip_rows[r] = true
                end
                emit_meta(ctx, node)
            elseif name == "refdef" then
                emit_refdef(ctx, node)
            -- Typst carries its inline elements in the SAME tree as its blocks, so the captures
            -- below arrive from this one pass rather than from the injected-inline pass.
            elseif name == "term" then
                emit_typst_term(ctx, node)
            elseif name == "math" then
                protect_node(ctx, node)
                emit_typst_math(ctx, node)
            elseif name == "code" then
                protect_node(ctx, node)
                emit_code_span(ctx, node)
            elseif name == "emphasis" then
                emit_emphasis(ctx, node)
            elseif name == "autolink" then
                protect_node(ctx, node)
                emit_typst_url(ctx, node)
            elseif name == "label" then
                emit_typst_label(ctx, node)
            elseif name == "ref" then
                emit_typst_ref(ctx, node)
            elseif name == "escape" then
                emit_escape(ctx, node)
            -- Org: one node type per element, and the inline markup scanned per paragraph.
            elseif name == "markup" then
                emit_org_markup(ctx, node)
            elseif name == "checkbox" then
                emit_org_checkbox(ctx, node)
            elseif name == "block" then
                local bsr, _, ber, bec = node:range()
                for r = bsr, (bec == 0 and ber - 1 or ber) do
                    ctx.skip_rows[r] = true
                end
                emit_org_block(ctx, node)
            end
        end
    end

    if iq ~= nil then
        local child = ichild
        if child ~= nil then
            for _, tree in pairs(child:trees()) do
                local iroot = tree:root()
                local isr, _, ier = iroot:range()
                if isr <= ctx.last and ier >= ctx.first then
                    for id, node in iq:iter_captures(iroot, buf, ctx.first, ctx.last + 1) do
                        local name = iq.captures[id]
                        local nrow = node:range()
                        if ctx.skip_rows[nrow] then
                            -- A row another element OWNS outright (a wrapped table box redraws its
                            -- rows from scratch; a fenced block and frontmatter are not prose).
                            name = nil
                        end
                        if name == "code" then
                            protect_node(ctx, node)
                            emit_code_span(ctx, node)
                        elseif name == "emphasis" then
                            emit_emphasis(ctx, node)
                        elseif name == "link" then
                            emit_link(ctx, node, false)
                        elseif name == "link_shortcut" then
                            emit_wikilink(ctx, node)
                        elseif name == "image" then
                            emit_link(ctx, node, true)
                        elseif name == "entity" then
                            emit_entity(ctx, node)
                        elseif name == "math" then
                            protect_node(ctx, node)
                            emit_math(ctx, node)
                        elseif name == "html" then
                            emit_html(ctx, node)
                        elseif name == "autolink" then
                            protect_node(ctx, node)
                            emit_autolink(ctx, node)
                        elseif name == "escape" then
                            emit_escape(ctx, node)
                        end
                    end
                end
            end
        end
    end

    -- The grammarless elements (==mark==, :emoji:, #tag), after the inline pass has recorded
    -- what to stay out of.
    for row = ctx.first, ctx.last do
        emit_row_scans(ctx, row)
    end

    local reveal = ctx.reveal
    if reveal ~= nil then
        reveal = { first = ctx.eff_first, last = ctx.eff_last }
    end
    return ctx.ops, reveal, ctx.extend
end

return M
