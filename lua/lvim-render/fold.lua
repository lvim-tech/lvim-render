-- lvim-render.fold: heading folding — the outline, the foldexpr/foldtext pair, and the org-style
-- cycle. A heading folds everything under it, down to the next heading of the same or higher level.
--
-- THE OUTLINE IS ITS OWN PASS, not the windowed walk: fold levels are needed for every line of the
-- buffer (a fold above the viewport changes what is on screen), so they cannot come from a walk
-- that only sees visible rows. The outline query runs over the BLOCK tree alone (`parser:parse()`,
-- no injections — cheap even at 20k lines), is rebuilt on the engine's debounce, and `expr()` is an
-- O(1) table lookup into its cache.
--
-- Fold extents come from the FLAT heading list (row + level), never from the grammar's `section`
-- nesting — measured on this grammar build: a setext heading does not open a `section` node, so the
-- nesting disagrees with what a reader calls a heading's subtree.
--
-- After a rebuild the changed rows go through `vim._foldupdate(win, srow, erow)` — the same
-- C-implemented seam Neovim's own treesitter and LSP fold providers use to say "the expr's backing
-- data changed, re-evaluate". No 'foldmethod' re-set, no fold state lost.
--
---@module "lvim-render.fold"

local config = require("lvim-render.config")
local highlights = require("lvim-render.highlights")
local state = require("lvim-render.state")

local api = vim.api
local fn = vim.fn
local ts = vim.treesitter

local M = {}

---@type table<string, vim.treesitter.Query|false>  format → compiled outline query
local queries = {}

---@type table<string, string>  headings only — the outline needs nothing else
local QUERY_SRC = {
    markdown = [[
        (atx_heading) @atx
        (setext_heading) @setext
        (pipe_table) @tbl
    ]],
    -- Typst has one heading form and no table node of its own (a typst table is a `#table(…)`
    -- call, i.e. code — nothing for `fold.tables` to fold).
    typst = [[
        (heading) @atx
    ]],
    -- Org headlines. Its `table` node is real, so `fold.tables` has something to fold here.
    org = [[
        (headline) @atx
        (table) @tbl
    ]],
}

--- Compile (once) and return the outline query for a format.
---@param format string  the config block name
---@param lang string    the parser language it compiles against
---@return vim.treesitter.Query|nil
local function query_for(format, lang)
    if queries[format] == nil then
        local src = QUERY_SRC[format]
        if src == nil then
            queries[format] = false
        else
            local ok, q = pcall(ts.query.parse, lang, src)
            queries[format] = ok and q or false
        end
    end
    return queries[format] or nil
end

--- Heading level and marker of a heading node, read from its marker/underline child.
---@param node TSNode
---@return integer|nil level
local function heading_level(node)
    for child in node:iter_children() do
        local kind = child:type()
        local m = kind:match("^atx_h(%d)_marker$") or kind:match("^setext_h(%d)_underline$")
        if m then
            return tonumber(m)
        end
        -- Typst names the level by the LENGTH of the `=` run, not in the node type.
        local eq = kind:match("^(=+)$")
        if eq then
            return #eq
        end
        -- Org: the level is the number of leading stars, in a node of its own.
        if kind == "stars" then
            local _, sc, _, ec = child:range()
            return ec - sc
        end
    end
    return nil
end

--- The heading's title text: its `inline` child (the text without markers), first line only.
---@param node TSNode
---@param buf integer
---@return string
local function heading_title(node, buf)
    for child in node:iter_children() do
        local kind = child:type()
        if kind == "inline" then
            return (ts.get_node_text(child, buf):match("[^\n]*"))
        end
        -- A setext heading's text lives in a paragraph child, not a bare inline.
        if kind == "paragraph" then
            return (ts.get_node_text(child, buf):match("[^\n]*"))
        end
        -- Typst: the title is a bare `text` child beside the `=` marker.
        if kind == "text" then
            return (ts.get_node_text(child, buf):match("[^\n]*"))
        end
        -- Org: the title (with its TODO keyword and tags, as written) is the `item` child.
        if kind == "item" then
            return (ts.get_node_text(child, buf):match("[^\n]*"))
        end
    end
    return ""
end

--- Rebuild the outline for a buffer from a fresh whole-buffer block parse.
---@param buf integer
---@return nil
function M.rebuild(buf)
    local st = state.get(buf)
    if st == nil or st.inert ~= nil then
        return
    end
    local query = query_for(st.format, st.lang)
    local ok, parser = pcall(ts.get_parser, buf, st.lang)
    if query == nil or not ok or parser == nil then
        st.outline, st.heading_by_row, st.max_level = {}, {}, 0
        return
    end
    local trees = parser:parse()
    local root = trees and trees[1] and trees[1]:root()
    if root == nil then
        st.outline, st.heading_by_row, st.max_level = {}, {}, 0
        return
    end

    ---@type LvimRenderHeading[]
    local outline = {}
    local max_level = 0
    ---@type { row: integer, end_row: integer }[]
    local tables = {}
    for id, node in query:iter_captures(root, buf, 0, -1) do
        if query.captures[id] == "tbl" then
            if config.fold.tables then
                local tsr, _, ter, tec = node:range()
                tables[#tables + 1] = { row = tsr, end_row = tec == 0 and ter - 1 or ter }
            end
        else
            local level = heading_level(node)
            if level ~= nil then
                local row = node:range()
                outline[#outline + 1] = {
                    row = row,
                    level = level,
                    title = heading_title(node, buf),
                    end_row = 0, -- filled below
                    setext = query.captures[id] == "setext",
                }
                max_level = math.max(max_level, level)
            end
        end
    end
    table.sort(outline, function(a, b)
        return a.row < b.row
    end)

    -- End of each subtree: the nearest FOLLOWING heading of the same or higher level. One reverse
    -- pass with a per-level "next row" table — O(6n), no rescanning.
    local line_count = api.nvim_buf_line_count(buf)
    local next_row = { line_count, line_count, line_count, line_count, line_count, line_count }
    for i = #outline, 1, -1 do
        local h = outline[i]
        local nearest = line_count
        for level = 1, h.level do
            nearest = math.min(nearest, next_row[level])
        end
        h.end_row = nearest
        next_row[h.level] = h.row
    end

    -- THE BLANK LINE BETWEEN TWO SECTIONS STAYS VISIBLE. A run of empty lines immediately before a
    -- heading is a SEPARATOR, not content of the section above it: left inside that section's fold
    -- it disappears when the section collapses, and the collapsed line and the next heading end up
    -- glued together with nothing between them (reported from a screenshot). Such a row is given
    -- the level of the ENCLOSING subtree instead — one below the heading that follows — so it is
    -- excluded from the section above while still folding away with the parent. Before a level-1
    -- heading that level is 0: a blank there belongs to no fold at all, which is correct.
    --
    -- Each heading's `end_row` is trimmed to match, so the hidden-line count on the fold line
    -- counts exactly the rows that actually disappear.
    ---@type table<integer, string>
    local sep = {}
    if config.fold.separate_sections then
        local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
        for _, h in ipairs(outline) do
            local row = h.row - 1
            local level = tostring(math.max(h.level - 1, 0))
            while row >= 0 and (lines[row + 1] or ""):match("^%s*$") ~= nil do
                sep[row] = level
                row = row - 1
            end
        end
        for _, h in ipairs(outline) do
            while h.end_row > h.row + 1 and sep[h.end_row - 1] ~= nil do
                h.end_row = h.end_row - 1
            end
        end
    end
    st.sep_levels = next(sep) ~= nil and sep or nil

    local by_row = {}
    for _, h in ipairs(outline) do
        by_row[h.row] = h
    end
    st.outline, st.heading_by_row, st.max_level = outline, by_row, max_level

    -- Opt-in table folds: a table folds as ONE region one level under its containing heading
    -- (start row opens `>n+1`, last row closes `<n+1`, so the paragraph after the table drops
    -- straight back to the heading's own level).
    if config.fold.tables and #tables > 0 then
        ---@type table<integer, string>
        local tf = {}
        for _, t in ipairs(tables) do
            local base = 0
            for _, h in ipairs(outline) do
                if h.row < t.row and h.end_row > t.row then
                    base = h.level
                end
            end
            if t.end_row > t.row then
                tf[t.row] = ">" .. (base + 1)
                tf[t.end_row] = "<" .. (base + 1)
            end
        end
        st.table_folds = tf
    else
        st.table_folds = nil
    end
end

--- Re-evaluate folds for the rows a rebuild may have changed, in every window we own.
---@param buf integer
---@param first integer  0-based first changed row
---@param last integer   0-based last changed row, INCLUSIVE
---@return nil
function M.refresh(buf, first, last)
    if vim._foldupdate == nil then
        return
    end
    for win, saved in pairs(state.wins) do
        if saved.buf == buf and api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == buf then
            pcall(vim._foldupdate, win, math.max(first, 0), last + 1)
        end
    end
end

---@type table<integer, { where: string, err: string, count: integer }>  the last error a fold
--- expression raised, per buffer — read by health. An error inside 'foldtext'/'foldexpr' is
--- otherwise INVISIBLE: Neovim draws an empty fold line (which, under a `fold:─` fillchar, looks
--- exactly like a rendered rule — a live incident, 2026-07-27) or silently mis-levels a fold.
--- The boundaries below make that failure mode impossible on screen and observable in health.
M.errors = {}

--- Record one boundary failure.
---@param buf integer
---@param where "foldexpr"|"foldtext"
---@param err any
---@return nil
local function record_error(buf, where, err)
    local entry = M.errors[buf]
    local text = tostring(err)
    if entry ~= nil and entry.where == where and entry.err == text then
        entry.count = entry.count + 1
    else
        M.errors[buf] = { where = where, err = text, count = 1 }
    end
end

--- The 'foldexpr' body proper. Reads `v:lnum` and the current buffer — fold evaluation runs with
--- the fold's own buffer current, which is exactly the contract this depends on.
---@return string
local function expr_impl()
    local st = state.get(api.nvim_get_current_buf())
    if st == nil or st.heading_by_row == nil then
        return "="
    end
    local h = st.heading_by_row[vim.v.lnum - 1]
    if h ~= nil then
        return ">" .. h.level
    end
    -- A blank row separating two sections: the enclosing subtree's level, so it survives the
    -- collapse of the section above it.
    if st.sep_levels ~= nil then
        local sl = st.sep_levels[vim.v.lnum - 1]
        if sl ~= nil then
            return sl
        end
    end
    if st.table_folds ~= nil then
        local tf = st.table_folds[vim.v.lnum - 1]
        if tf ~= nil then
            return tf
        end
    end
    return "="
end

--- 'foldexpr' entry: the boundary. Never raises — a raised error would silently break folding.
---@return string
function M.expr()
    local ok, res = pcall(expr_impl)
    if ok then
        return res
    end
    record_error(api.nvim_get_current_buf(), "foldexpr", res)
    return "="
end

--- Render one chunk template through the placeholder map. Table replacement, so `%` in a heading
--- title is never treated as a gsub capture.
---@param template string
---@param values table<string, string>
---@return string
local function fill(template, values)
    return (template:gsub("{(%w+)}", values))
end

--- The 'foldtext' body proper: the collapsed heading, still rendered — its glyph, its level
--- colour, and the count of hidden lines — instead of Neovim's raw `+--` line.
---@return string|[string, string][]
local function text_impl()
    local st = state.get(api.nvim_get_current_buf())
    local start = vim.v.foldstart
    if st == nil or st.heading_by_row == nil then
        return fn.foldtext()
    end
    local h = st.heading_by_row[start - 1]
    if h == nil or not config.fold.text.enabled then
        return fn.foldtext()
    end
    -- The icon comes from the FORMAT's own heading config, so an org headline collapses with the
    -- org glyph, not the markdown one.
    local fconf = config[st.format] or {}
    local spec = ((fconf.headings or {}).levels or {})[h.level] or {}
    local values = {
        icon = spec.icon or "",
        title = h.title,
        count = tostring(vim.v.foldend - start),
    }
    local pad = string.rep(" ", spec.pad or 0)
    local title = pad .. fill(config.fold.text.title, values) .. " "
    local info = fill(config.fold.text.info, values)

    -- THE LINE IS A BAND, NOT A RULE. The collapsed row is painted like the heading it stands for
    -- — the level's own band — with the count as a BOX on it, blended harder so it reads as a box
    -- rather than as more line. And the row is filled to the window's width: 'fillchars' draws its
    -- fold character only over what the foldtext leaves empty, so filling the row is what removes
    -- the trailing `────` (the option itself is the reader's, and is not touched).
    --
    -- WHILE THE CURSOR IS ON IT the band rises to the box's tint, so line and box become one solid
    -- tint of the level's accent — the active-row half of the tint canon.
    local band = highlights.heading_group(h.level)
    local strong = highlights.fold_strong_group(h.level)
    local active = fn.line(".") == start
    local line_hl = active and strong or band

    local width = api.nvim_win_get_width(0) - vim.fn.getwininfo(api.nvim_get_current_win())[1].textoff
    local rest = width - fn.strdisplaywidth(title) - fn.strdisplaywidth(info)
    ---@type [string, string][]
    local chunks = {
        { title, line_hl },
        { info, strong },
    }
    if rest > 0 then
        chunks[#chunks + 1] = { string.rep(" ", rest), line_hl }
    end
    return chunks
end

--- 'foldtext' entry: the boundary. An error inside the expression is drawn as an EMPTY line by
--- Neovim — no message, nothing to see — so it must never escape: the builtin foldtext is the
--- worst a fold line can look, and health names what went wrong.
---@return string|[string, string][]
function M.text()
    local ok, res = pcall(text_impl)
    if ok then
        return res
    end
    record_error(api.nvim_get_current_buf(), "foldtext", res)
    return fn.foldtext()
end

--- The innermost heading whose subtree contains a row.
---@param st LvimRenderBufState
---@param row integer  0-based
---@return LvimRenderHeading|nil
local function heading_at(st, row)
    local found = nil
    for _, h in ipairs(st.outline or {}) do
        if h.row > row then
            break
        end
        if h.end_row > row then
            found = h
        end
    end
    return found
end

--- Cycle the heading under the cursor: collapsed → children shown → whole subtree → collapsed.
--- Off a heading's subtree it does nothing — quietly, because a cycle key that beeps is worse than
--- one that waits.
---@return nil
function M.cycle()
    local win = api.nvim_get_current_win()
    local buf = api.nvim_get_current_buf()
    local st = state.get(buf)
    if st == nil then
        return
    end
    local h = heading_at(st, api.nvim_win_get_cursor(win)[1] - 1)
    if h == nil then
        return
    end
    local line = h.row + 1
    -- The subtree's headings, DEEPEST level first. Range fold commands are useless here — measured:
    -- `:{s},{e}foldclose!` also closes enclosing folds that merely intersect the range, and
    -- `:{line}foldclose` on a line already inside a closed fold closes one level FURTHER OUT — so
    -- every close targets one specific open fold, from the bottom of the tree up.
    ---@type LvimRenderHeading[]
    local descendants = {}
    for _, d in ipairs(st.outline) do
        if d.row > h.row and d.row < h.end_row then
            descendants[#descendants + 1] = d
        end
    end
    table.sort(descendants, function(a, b)
        if a.level ~= b.level then
            return a.level > b.level
        end
        return a.row < b.row
    end)

    api.nvim_win_call(win, function()
        --- Close one heading's own fold, only when it is itself visible and open.
        ---@param row integer
        local function close_own(row)
            if fn.foldclosed(row + 1) == -1 then
                vim.cmd(("silent! %dfoldclose"):format(row + 1))
            end
        end

        if fn.foldclosed(line) == line then
            -- COLLAPSED → CHILDREN: open one level; the descendants were closed on the way in, so
            -- what shows is the child outline.
            vim.cmd(("silent! %dfoldopen"):format(line))
            for _, d in ipairs(descendants) do
                close_own(d.row)
            end
            return
        end
        for _, d in ipairs(descendants) do
            if fn.foldclosed(d.row + 1) == d.row + 1 then
                -- CHILDREN → SUBTREE: something below is still folded; open everything under the
                -- heading (its own fold is already open, so the range stays inside the subtree).
                vim.cmd(("silent! %d,%dfoldopen!"):format(line, h.end_row))
                return
            end
        end
        -- SUBTREE → COLLAPSED: deepest folds first, then the heading's own — bottom-up, so no
        -- close ever lands on a hidden line and walks out of the subtree.
        for _, d in ipairs(descendants) do
            close_own(d.row)
        end
        close_own(h.row)
    end)
end

--- Cycle the whole document: overview ('foldlevel' 0) → children (1) → everything. The three-state
--- global cycle expressed the only way 'foldlevel' can express it — a body shares its heading's
--- fold, so "all headings, no bodies" is not a state expr folds can represent; stated in the docs
--- rather than pretended.
---@return nil
function M.cycle_all()
    local win = api.nvim_get_current_win()
    local buf = api.nvim_get_current_buf()
    local st = state.get(buf)
    if st == nil then
        return
    end
    st.cycle_all = (st.cycle_all + 1) % 3
    if st.cycle_all == 0 then
        vim.wo[win].foldlevel = 0
    elseif st.cycle_all == 1 then
        vim.wo[win].foldlevel = 1
    else
        vim.wo[win].foldlevel = math.max(st.max_level, 1)
    end
end

return M
