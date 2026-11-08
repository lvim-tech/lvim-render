-- The data tables that have to hold an invariant, and what a refresh actually draws.
--
-- The emoji table states its own rule in its header: it is "curated to the common gemoji names
-- whose emoji is a SINGLE codepoint -- conceal replaces a range with exactly one character, so
-- multi-codepoint sequences (skin tones, ZWJ families) cannot render this way and are left out on
-- purpose". One multi-codepoint entry slipping in would render as nothing a reader can read, and
-- nobody checks 178 escapes by eye. Same for the 252 entity names.
--
-- The renderer itself is exercised where it can be: the PERSISTENT lane is real buffer extmarks,
-- so a refresh can be asked what it drew. The ephemeral lane (conceals, the reveal of the line
-- under the cursor) only exists inside a decoration-provider callback during a real redraw and is
-- not reachable from a headless run -- the cases that would need it say so instead of pretending.

local render = require("lvim-render")
local split = require("lvim-render.split")
local emoji = require("lvim-render.data.emoji")
local entities = require("lvim-render.data.entities")

describe("lvim-render: the emoji shortcodes")

it("there is a curated table to check", function()
    eq(178, vim.tbl_count(emoji), "the curated gemoji subset")
end)

it("every emoji is exactly ONE codepoint", function()
    for name, ch in pairs(emoji) do
        eq(
            1,
            vim.fn.strchars(ch),
            ("%s = %q is %d codepoints; conceal can only put one character in a range"):format(
                name,
                ch,
                vim.fn.strchars(ch)
            )
        )
    end
end)

it("every shortcode is usable as one", function()
    for name, ch in pairs(emoji) do
        truthy(type(name) == "string" and name ~= "", "an empty shortcode")
        eq(nil, name:match(":"), name .. " contains the delimiter it is wrapped in")
        eq(nil, name:match("%s"), name .. " contains whitespace")
        truthy(type(ch) == "string" and ch ~= "", name .. " maps to nothing")
    end
end)

describe("lvim-render: the HTML entities")

it("there is the classic entity set", function()
    eq(252, vim.tbl_count(entities))
    eq("&", entities["amp"], "the one every renderer is judged by")
    eq("<", entities["lt"])
    eq(">", entities["gt"])
    eq("\u{00A0}", entities["nbsp"], "a non-breaking space, which is why these are written as escapes")
end)

it("every name is usable inside &…; and maps to a character", function()
    for name, ch in pairs(entities) do
        truthy(type(name) == "string" and name ~= "")
        eq(nil, name:match("[&;]"), name .. " carries the delimiters it sits between")
        eq(nil, name:match("%s"), name .. " contains whitespace")
        truthy(type(ch) == "string" and ch ~= "", name .. " maps to nothing")
    end
end)

describe("lvim-render: what the plugin thinks it is doing")

--- A markdown buffer holding `lines`, with the plugin attached to it.
---@param lines string[]
---@param ft? string
---@return integer buf
local function markdown(lines, ft)
    vim.cmd("enew!")
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].filetype = ft or "markdown"
    vim.cmd("doautocmd FileType")
    return buf
end

it("a markdown buffer is attached and enabled", function()
    local buf = markdown({ "# Title" })
    local st = render.status(buf)
    eq(true, st.attached)
    eq(true, st.enabled)
    eq("markdown", st.format)
    eq(false, st.mirror, "the buffer the user edits is never the mirror")
    eq(false, st.split)
end)

it("a buffer of another filetype is not attached", function()
    local buf = markdown({ "# Title" }, "lua")
    local st = render.status(buf)
    eq(false, st.attached, "a Lua file is not a document to render")
end)

describe("lvim-render: what a refresh draws")

--- The persistent extmarks of `buf`, with details.
---
--- The persistent lane is drawn by the DECORATION PROVIDER, so it exists only after a real
--- repaint -- `render.refresh` rebuilds the fold outline, which is a different question. A redraw
--- is therefore the thing to ask for here, and it is what a user's screen does too.
---@param buf integer
---@return table[]
local function marks_of(buf)
    -- `redraw` SCHEDULES the repaint; the provider runs when the event loop is pumped, so the wait is
    -- not a sleep for luck -- measured, redraw alone leaves the marks undrawn and redraw plus a pumped
    -- loop draws them. The predicate makes the wait end as soon as there is something to read.
    vim.cmd("redraw")
    vim.wait(500, function()
        return #vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, {}) > 0
    end)
    return vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
end

--- The virt_text chunks drawn on `row`, flattened to { text, hl } pairs.
---@param buf integer
---@param row integer  0-based
---@return table[]
local function virt_text_on(buf, row)
    local out = {}
    for _, m in ipairs(marks_of(buf)) do
        if m[2] == row and m[4].virt_text then
            for _, chunk in ipairs(m[4].virt_text) do
                out[#out + 1] = { chunk[1], chunk[2] }
            end
        end
    end
    return out
end

it("a heading is given an icon in its own level's highlight", function()
    local buf = markdown({ "# One", "", "## Two", "", "### Three" })
    local levels = { [0] = "LvimRenderH1", [2] = "LvimRenderH2", [4] = "LvimRenderH3" }
    for row, group in pairs(levels) do
        local chunks = virt_text_on(buf, row)
        truthy(#chunks > 0, ("row %d (%s) got no icon"):format(row, group))
        local found = false
        for _, c in ipairs(chunks) do
            if c[2] == group then
                found = true
            end
        end
        truthy(found, ("row %d should be painted %s, got %s"):format(row, group, vim.inspect(chunks)))
    end
end)

it("the three heading levels do not share one highlight", function()
    local buf = markdown({ "# One", "", "## Two", "", "### Three" })
    local seen = {}
    for _, row in ipairs({ 0, 2, 4 }) do
        for _, c in ipairs(virt_text_on(buf, row)) do
            seen[c[2]] = (seen[c[2]] or 0) + 1
        end
    end
    truthy(vim.tbl_count(seen) >= 3, "each level has its own group: " .. vim.inspect(seen))
end)

--- How much `buf` has drawn, split by mechanism.
---@param buf integer
---@return { marks: integer, virt_lines: integer, virt_text: integer }
local function drawn(buf)
    local out = { marks = 0, virt_lines = 0, virt_text = 0 }
    for _, m in ipairs(marks_of(buf)) do
        out.marks = out.marks + 1
        if m[4].virt_lines then
            out.virt_lines = out.virt_lines + #m[4].virt_lines
        end
        if m[4].virt_text then
            out.virt_text = out.virt_text + 1
        end
    end
    return out
end

it("under 'wrap' a table is a box hanging from the row above it", function()
    vim.cmd("enew!")
    vim.wo.wrap = true
    local buf = markdown({ "", "| a | b |", "|---|---|", "| 1 | 2 |" })
    local d = drawn(buf)
    truthy(d.virt_lines > 0, "the whole box is virtual lines: " .. vim.inspect(d))
end)

it("under 'nowrap' the same table is drawn in place, first line or not", function()
    vim.cmd("enew!")
    vim.wo.wrap = false
    local buf = markdown({ "| a | b |", "|---|---|", "| 1 | 2 |" })
    local d = drawn(buf)
    truthy(d.marks > 0, "with no wrapping to come apart, the in-place rendering applies: " .. vim.inspect(d))
    truthy(d.virt_text > 0, "in-place borders are virt_text on the source rows: " .. vim.inspect(d))
    vim.wo.wrap = true
end)

--- The virtual lines of the first box in `buf`, each flattened to its text.
---@param buf integer
---@return string[] texts
---@return table[][] raw
local function box_lines(buf)
    for _, m in ipairs(marks_of(buf)) do
        if m[4].virt_lines then
            local texts = {}
            for i, chunks in ipairs(m[4].virt_lines) do
                local parts = {}
                for _, chunk in ipairs(chunks) do
                    parts[#parts + 1] = chunk[1]
                end
                texts[i] = table.concat(parts)
            end
            return texts, m[4].virt_lines
        end
    end
    return {}, {}
end

--- Does this virtual line carry the row-end underline?
---@param chunks table[]
---@return boolean
local function has_row_end(chunks)
    for _, chunk in ipairs(chunks) do
        if type(chunk[2]) == "table" and vim.tbl_contains(chunk[2], "LvimRenderTableRowEnd") then
            return true
        end
    end
    return false
end

it("under 'wrap' a table past max_width is still a fitted box", function()
    vim.cmd("enew!")
    vim.wo.wrap = true
    local buf = markdown({ "", "| a | b |", "|---|---|", "| x | " .. string.rep("word ", 100) .. "|" })
    local texts = box_lines(buf)
    truthy(#texts > 0, "a long cell must not cost the table its box")
    local width = vim.api.nvim_win_get_width(0)
    for _, text in ipairs(texts) do
        truthy(vim.fn.strdisplaywidth(text) <= width, "wider than the window: " .. text)
    end
end)

it("under 'nowrap' max_width still limits the in-place drawing", function()
    vim.cmd("enew!")
    vim.wo.wrap = false
    local buf = markdown({ "", "| a | b |", "|---|---|", "| x | " .. string.rep("word ", 100) .. "|" })
    eq(0, drawn(buf).virt_lines, "no box border over a table too wide to draw")
    vim.wo.wrap = true
end)

it("a wrapped row is joined by the continuation glyph and ends underlined", function()
    vim.cmd("enew!")
    vim.wo.wrap = true
    local long = string.rep("word ", 40)
    local buf = markdown({ "", "| a | b |", "|---|---|", "| x | " .. long .. "|", "| y | z |", "| p | q |" })
    local texts, raw = box_lines(buf)
    local continued, ends = 0, {}
    for i, text in ipairs(texts) do
        if text:find("┊", 1, true) then
            continued = continued + 1
            eq(nil, text:find("│", 1, true), "one line, one glyph: " .. text)
        end
        if has_row_end(raw[i]) then
            ends[#ends + 1] = vim.trim((text:gsub("[│┊]", " ")))
        end
    end
    truthy(continued > 0, "the long row takes more than one line: " .. vim.inspect(texts))
    eq(2, #ends, "the wrapped row and the row after it, not the last: " .. vim.inspect(ends))
    truthy(ends[2]:find("^y") ~= nil, "the row end sits on the row's last line: " .. vim.inspect(ends))
end)

it("a table with no wrapped body row draws no row marks", function()
    vim.cmd("enew!")
    vim.wo.wrap = true
    local buf = markdown({ "", "| a | b |", "|---|---|", "| 1 | 2 |", "| 3 | 4 |" })
    local texts, raw = box_lines(buf)
    for i, text in ipairs(texts) do
        eq(nil, text:find("┊", 1, true), text)
        eq(false, has_row_end(raw[i]), text)
    end
end)

--- A wrapping buffer holding `lines`.
---@param lines string[]
---@return integer
local function wrapped(lines)
    vim.cmd("silent! only!")
    vim.cmd("enew!")
    vim.wo.wrap = true
    return markdown(lines)
end

--- The screen's rows, right-trimmed.
---@param n integer
---@return string[]
local function screen(n)
    vim.cmd("redraw")
    vim.wait(100, function()
        return false
    end)
    vim.cmd("redraw")
    local out = {}
    for row = 1, n do
        local cells = {}
        for col = 1, vim.o.columns do
            cells[col] = vim.fn.screenstring(row, col)
        end
        out[row] = (table.concat(cells):gsub("%s+$", ""))
    end
    return out
end

--- Is `text` on any of the screen's first `n` rows?
---@param n integer
---@param text string
---@return boolean
local function on_screen(n, text)
    return table.concat(screen(n), "\n"):find(text, 1, true) ~= nil
end

local T = { "| aa | bb |", "|---|---|", "| 11 | 22 |" }

it("a table on the first line is a box, its own row the anchor", function()
    wrapped(T)
    truthy(on_screen(8, "│ 11 "), vim.inspect(screen(8)))
    eq(false, on_screen(8, "|---"), "no raw delimiter")
end)

it("two tables with no blank line between them both show", function()
    wrapped({ "", T[1], T[2], T[3], "| cc | dd |", "|---|---|", "| 33 | 44 |" })
    truthy(on_screen(14, "│ 11 ") and on_screen(14, "│ 33 "), vim.inspect(screen(14)))
end)

it("a closed fold over the row above does not take the table with it", function()
    wrapped({ "# h", "", "text", "", T[1], T[2], T[3] })
    vim.wo.foldmethod = "manual"
    vim.wo.foldenable = true
    vim.cmd("3,4fold")
    truthy(on_screen(10, "│ 11 "), vim.inspect(screen(10)))
    vim.cmd("normal! zE")
end)

it("two windows on one buffer each get their own box", function()
    local buf = wrapped({ "", "| a | b |", "|---|---|", "| x | " .. string.rep("word ", 25) .. "|" })
    vim.cmd("vsplit")
    vim.cmd("vertical resize 30")
    screen(1)
    screen(1)
    local widths = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
        if m[4].virt_lines then
            local parts = {}
            for _, chunk in ipairs(m[4].virt_lines[1]) do
                parts[#parts + 1] = chunk[1]
            end
            widths[vim.fn.strdisplaywidth(table.concat(parts))] = true
        end
    end
    eq(2, vim.tbl_count(widths), "one width per window: " .. vim.inspect(widths))
    vim.cmd("only!")
end)

it("a window under 'nowrap' beside a wrapping one shows no raw pipes", function()
    wrapped({ "", T[1], T[2], T[3] })
    vim.cmd("vsplit")
    vim.wo.wrap = false
    eq(false, on_screen(8, "| aa"), vim.inspect(screen(8)))
    vim.cmd("only!")
    vim.wo.wrap = true
end)

it("turning 'wrap' off forgets the box", function()
    local buf = wrapped({ "", T[1], T[2], T[3] })
    screen(1)
    truthy(next(require("lvim-render.state").get(buf).boxed or {}) ~= nil, "precondition: boxed")
    vim.wo.wrap = false
    screen(1)
    eq(nil, next(require("lvim-render.state").get(buf).boxed or {}))
    vim.wo.wrap = true
end)

it("a search into a box taller than the window shows the hit, and j goes on from it", function()
    local lines = { "# h", "", "| a | b |", "|---|---|" }
    for i = 1, 120 do
        lines[#lines + 1] = ("| %d | v%d |"):format(i, i)
    end
    wrapped(lines)
    screen(1)
    vim.fn.search("v90")
    vim.cmd("doautocmd CursorMoved")
    truthy(on_screen(vim.o.lines - 2, "│ v90 "), vim.inspect(screen(vim.o.lines - 2)))
    vim.cmd("normal j")
    truthy(on_screen(vim.o.lines - 2, "│ v91 "), vim.inspect(screen(vim.o.lines - 2)))
    vim.cmd("doautocmd CursorMoved")
    vim.cmd("normal! gg")
    vim.cmd("doautocmd CursorMoved")
end)

it("a table too wide for min_col is cut at the edge, and says so", function()
    wrapped({ "", "|" .. string.rep(" col |", 30), "|" .. string.rep("---|", 30), "|" .. string.rep(" 1 |", 30) })
    local rows = screen(6)
    truthy(rows[3]:find("│ col", 1, true) ~= nil, vim.inspect(rows))
    truthy(rows[3]:find("›", 1, true) ~= nil, "the cut is visible: " .. vim.inspect(rows))
end)

it("a box in a quote keeps the border, in a list the indent", function()
    wrapped({ "> text", "> " .. T[1], "> " .. T[2], "> " .. T[3] })
    truthy(on_screen(6, "▍ │ 11"), vim.inspect(screen(6)))
    wrapped({ "- item", "", "  " .. T[1], "  " .. T[2], "  " .. T[3] })
    truthy(on_screen(8, "  │ 11"), vim.inspect(screen(8)))
end)

it("a pipe escaped inside a code span shows as a pipe", function()
    local cells = { "", "| a | b |", "|---|---|", "| `x\\|y` | z |" }
    wrapped(cells)
    truthy(on_screen(6, "x|y"), vim.inspect(screen(6)))
    vim.cmd("enew!")
    vim.wo.wrap = false
    markdown(cells)
    truthy(on_screen(6, "x|y"), vim.inspect(screen(6)))
    vim.wo.wrap = true
end)

it("styled text keeps its highlight in the box, and a repaint rewrites nothing", function()
    local buf = wrapped({
        "",
        "| a | b |",
        "|---|---|",
        "| **b** | `c d` [l](http://x) ==m== |",
        "| x | " .. string.rep("w ", 60) .. "|",
        "| p | q |",
    })
    screen(1)
    local seen, top = {}, 0
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
        top = math.max(top, m[1])
        for _, vline in ipairs(m[4].virt_lines or {}) do
            for _, chunk in ipairs(vline) do
                if type(chunk[2]) == "table" then
                    seen[chunk[2][#chunk[2]]] = chunk[1]
                end
            end
        end
    end
    eq("b", seen["@markup.strong"], vim.inspect(seen))
    eq("c d", seen["LvimRenderCodeInline"], vim.inspect(seen))
    eq("m", seen["LvimRenderMark"], vim.inspect(seen))
    truthy(seen["LvimRenderLink"] ~= nil, vim.inspect(seen))
    screen(1)
    screen(1)
    local after = 0
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, {})) do
        after = math.max(after, m[1])
    end
    eq(top, after, "stacked highlights must compare equal across passes")
end)

it("plain prose is left alone", function()
    local buf = markdown({ "just a sentence.", "", "and another." })
    truthy(render.status(buf).enabled, "precondition: the renderer is live for this buffer")
    local drawn = 0
    for _, m in ipairs(marks_of(buf)) do
        if m[4].virt_text or m[4].virt_lines then
            drawn = drawn + 1
        end
    end
    eq(0, drawn, "nothing in this document asks to be decorated")
end)

it("a repeated repaint draws the same, not twice as much", function()
    local buf = markdown({ "# One", "", "## Two" })
    local first = #marks_of(buf)
    truthy(first > 0, "precondition: there is something drawn to compare")
    eq(first, #marks_of(buf), "a repaint must replace the extmarks, not stack them")
    eq(first, #marks_of(buf))
end)

describe("lvim-render: the split mirror is a projection")

it("the editing buffer is not a mirror and has no source", function()
    local buf = markdown({ "# Title" })
    eq(false, split.is_mirror(buf))
    eq(nil, split.source_of(buf))
end)

it("a mirror is unlisted, unmodifiable and unwritable, and knows its source", function()
    local buf = markdown({ "# Title", "", "text" })
    local ok = pcall(split.open, buf)
    if not ok or not render.status(buf).split then
        skip("the split mirror", "the preview window could not be opened in this environment")
        return
    end

    local mirror
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if split.is_mirror(b) then
            mirror = b
        end
    end
    truthy(mirror, "open() reported a split but there is no mirror buffer")

    eq(buf, split.source_of(mirror), "the mirror has to know what it projects")
    eq(false, vim.bo[mirror].buflisted, "a projection is not a file the user navigates to")
    eq(false, vim.bo[mirror].modifiable, "no edit may happen in it, which is why none can be lost")
    eq(false, vim.bo[mirror].modified)
    eq("nofile", vim.bo[mirror].buftype, "and it can never be written anywhere")

    eq(
        vim.api.nvim_buf_get_lines(buf, 0, -1, false),
        vim.api.nvim_buf_get_lines(mirror, 0, -1, false),
        "it is overwritten wholesale from the source"
    )

    pcall(split.close, buf)
    eq(false, render.status(buf).split)
end)
