-- lvim-render.table_editor: the full-screen TABLE EDITOR.
--
-- WHY IT EXISTS, and it is not a convenience. A table cannot be edited comfortably in the buffer
-- under `'wrap'`, and that is a property of Neovim rather than of this plugin: CONCEALED TEXT STILL
-- TAKES ITS WIDTH WHEN A LINE WRAPS. A table row carrying links is two to three times longer raw
-- than rendered, so the line wraps by its RAW length and the columns come apart — and a decoration
-- cannot shorten a line. The in-buffer answer is the box (lvim-render.render), which hides the
-- source rows; that makes the table READABLE but not editable, since what you would edit is hidden.
--
-- This editor is the other half. It is a window of its own, so it has its own width and its own
-- `'nowrap'`: nothing here fights the reader's settings, and the grid is shown exactly as wide as
-- it needs to be. You edit the cells; `<CR>` writes the table back.
--
-- WRITE-BACK REFORMATS, by the owner's decision and for a plain reason: the grid you edit is
-- aligned, and writing back something ragged would make the file disagree with what you just saw.
-- The columns are padded to their widest cell, the delimiter row keeps whatever alignment the
-- source declared, and nothing outside the table's own rows is touched.
--
-- FORMATS: markdown (`pipe_table`) and org (`table`). Typst has no table NODE at all — a typst
-- table is a `#table(…)` function call, which is code, so there is nothing here to edit.
--
---@module "lvim-render.table_editor"

local config = require("lvim-render.config")
local state = require("lvim-render.state")

local api = vim.api
local fn = vim.fn
local ts = vim.treesitter

local M = {}

---@class LvimRenderTableGrid
---@field first integer    0-based first buffer row of the table
---@field last integer     0-based last buffer row (inclusive)
---@field rows string[][]  every DATA row (the delimiter/hr rows are not kept — they are regenerated)
---@field aligns ("left"|"center"|"right")[]
---@field format string    the format block the table came from
---@field header boolean   the first row is a header (markdown always; org when it has an `hr`)

---@type table<integer, { grid: LvimRenderTableGrid, source: integer, buf: integer, handle: table }>
--- editor buffer → what it is editing
local open_editors = {}

--- The table node the cursor is inside, or nil.
---@param buf integer
---@param row integer  0-based
---@return TSNode|nil node
---@return string|nil format
local function table_at(buf, row)
    local st = state.get(buf)
    if st == nil or st.inert ~= nil then
        return nil, nil
    end
    local ok, parser = pcall(ts.get_parser, buf, st.lang)
    if not ok or parser == nil then
        return nil, nil
    end
    local trees = parser:parse()
    local root = trees and trees[1] and trees[1]:root()
    if root == nil then
        return nil, nil
    end
    -- The node types are the two grammars' own; typst is absent on purpose (see the header).
    local want = st.format == "org" and "table" or "pipe_table"
    local node = root:named_descendant_for_range(row, 0, row, 0)
    while node ~= nil do
        if node:type() == want then
            return node, st.format
        end
        node = node:parent()
    end
    return nil, nil
end

--- Split one source row into its cells. Both formats write `| a | b |`, so one splitter serves
--- both; the leading and trailing pipes are dropped and every cell is trimmed.
---@param line string
---@return string[]
local function split_row(line)
    local body = line:gsub("^%s*|", ""):gsub("|%s*$", "")
    local cells = {}
    for cell in (body .. "|"):gmatch("(.-)|") do
        cells[#cells + 1] = vim.trim(cell)
    end
    return cells
end

--- Is this a separator row (`|---|---|` / `|---+---|`)? Those are regenerated on write-back, so
--- they are never carried into the grid.
---@param line string
---@return boolean
local function is_separator(line)
    return line:match("^%s*|[%s%-:+|]+$") ~= nil
end

--- Read the table under the cursor into a grid.
---@param buf integer
---@param row integer  0-based
---@return LvimRenderTableGrid|nil
function M.grid_at(buf, row)
    local node, format = table_at(buf, row)
    if node == nil or format == nil then
        return nil
    end
    local sr, _, er, ec = node:range()
    local last = ec == 0 and er - 1 or er
    local lines = api.nvim_buf_get_lines(buf, sr, last + 1, false)

    ---@type string[][]
    local rows = {}
    ---@type ("left"|"center"|"right")[]
    local aligns = {}
    local header = false
    for index, line in ipairs(lines) do
        if is_separator(line) then
            -- The separator's own cells carry the ALIGNMENT in markdown (`:---`, `---:`, `:---:`),
            -- and mark the header boundary in both formats.
            header = index == 2
            for i, cell in ipairs(split_row(line)) do
                local left = cell:sub(1, 1) == ":"
                local right = cell:sub(-1) == ":"
                aligns[i] = (left and right) and "center" or (right and "right") or "left"
            end
        else
            rows[#rows + 1] = split_row(line)
        end
    end
    if #rows == 0 then
        return nil
    end
    return { first = sr, last = last, rows = rows, aligns = aligns, format = format, header = header }
end

--- The column widths of a grid: the widest cell per column, measured in display CELLS so Cyrillic
--- and CJK line up like everything else in this plugin.
---@param rows string[][]
---@return integer[]
local function widths(rows)
    local cols = {}
    for _, row in ipairs(rows) do
        for i, cell in ipairs(row) do
            cols[i] = math.max(cols[i] or 1, fn.strdisplaywidth(cell))
        end
    end
    return cols
end

--- Pad one cell to its column, honouring the column's alignment.
---@param cell string
---@param width integer
---@param align "left"|"center"|"right"
---@return string
local function pad(cell, width, align)
    local slack = width - fn.strdisplaywidth(cell)
    if slack <= 0 then
        return cell
    end
    if align == "right" then
        return string.rep(" ", slack) .. cell
    end
    if align == "center" then
        local head = math.floor(slack / 2)
        return string.rep(" ", head) .. cell .. string.rep(" ", slack - head)
    end
    return cell .. string.rep(" ", slack)
end

--- Render a grid as aligned source text — the very lines that go back into the file. Used both to
--- fill the editor and to write back, so what you edit is what is written, character for character.
---@param grid LvimRenderTableGrid
---@return string[]
function M.format(grid)
    local cols = widths(grid.rows)
    ---@type string[]
    local out = {}
    for index, row in ipairs(grid.rows) do
        local parts = {}
        for i = 1, #cols do
            parts[#parts + 1] = " " .. pad(row[i] or "", cols[i], grid.aligns[i] or "left") .. " "
        end
        out[#out + 1] = "|" .. table.concat(parts, "|") .. "|"
        if index == 1 and grid.header then
            local seps = {}
            for i = 1, #cols do
                -- markdown carries the alignment in the separator; org has no such notation, so it
                -- gets a plain rule and the alignment lives only in this editor's own layout.
                local body = string.rep("-", cols[i] + 2)
                if grid.format ~= "org" then
                    local align = grid.aligns[i] or "left"
                    if align == "center" then
                        body = ":" .. string.rep("-", cols[i]) .. ":"
                    elseif align == "right" then
                        body = string.rep("-", cols[i] + 1) .. ":"
                    end
                end
                seps[#seps + 1] = body
            end
            out[#out + 1] = "|" .. table.concat(seps, grid.format == "org" and "+" or "|") .. "|"
        end
    end
    return out
end

--- Read the editor buffer back into a grid (the same shape `grid_at` produced).
---@param ed integer  the editor buffer
---@param grid LvimRenderTableGrid
---@return LvimRenderTableGrid
local function harvest(ed, grid)
    local rows = {}
    for _, line in ipairs(api.nvim_buf_get_lines(ed, 0, -1, false)) do
        if vim.trim(line) ~= "" and not is_separator(line) then
            rows[#rows + 1] = split_row(line)
        end
    end
    return {
        first = grid.first,
        last = grid.last,
        rows = #rows > 0 and rows or grid.rows,
        aligns = grid.aligns,
        format = grid.format,
        header = grid.header,
    }
end

--- Write the edited table back into its source buffer, reformatted, and close the editor.
---@param ed integer
---@return nil
local function commit(ed)
    local rec = open_editors[ed]
    if rec == nil then
        return
    end
    local grid = harvest(ed, rec.grid)
    if api.nvim_buf_is_valid(rec.source) and vim.bo[rec.source].modifiable then
        api.nvim_buf_set_lines(rec.source, grid.first, grid.last + 1, false, M.format(grid))
    end
    if rec.handle ~= nil and rec.handle.close ~= nil then
        rec.handle.close()
    end
end

--- The cell the cursor is in, as (row, column) 1-based, plus the byte columns of every cell start
--- on that line — the basis for cell-to-cell movement.
---@param ed integer
---@return integer col_index
---@return integer[] starts  byte column of each cell's first character
local function cell_at(ed)
    local pos = api.nvim_win_get_cursor(0)
    local line = api.nvim_buf_get_lines(ed, pos[1] - 1, pos[1], false)[1] or ""
    ---@type integer[]
    local starts = {}
    local col = 1
    while true do
        local pipe = line:find("|", col, true)
        if pipe == nil then
            break
        end
        -- One column past the pipe and its padding space.
        starts[#starts + 1] = pipe + 1
        col = pipe + 1
    end
    -- Drop the LAST pipe: it closes the row rather than opening a cell.
    starts[#starts] = nil
    local index = 1
    for i, s in ipairs(starts) do
        if pos[2] + 1 >= s then
            index = i
        end
    end
    return index, starts
end

--- Move the cursor to the next/previous cell, wrapping to the next/previous row at the ends.
---@param ed integer
---@param delta integer
---@return nil
local function move_cell(ed, delta)
    local index, starts = cell_at(ed)
    local pos = api.nvim_win_get_cursor(0)
    local target = index + delta
    local row = pos[1]
    if target < 1 or target > #starts then
        row = row + (delta > 0 and 1 or -1)
        local total = api.nvim_buf_line_count(ed)
        if row < 1 or row > total then
            return
        end
        api.nvim_win_set_cursor(0, { row, 0 })
        local _, next_starts = cell_at(ed)
        target = delta > 0 and 1 or #next_starts
        starts = next_starts
    end
    if starts[target] ~= nil then
        api.nvim_win_set_cursor(0, { row, starts[target] })
    end
end

--- Insert or delete a whole row / column, keeping the grid rectangular.
---@param ed integer
---@param what "row"|"column"
---@param add boolean
---@return nil
local function edit_structure(ed, what, add)
    local rec = open_editors[ed]
    if rec == nil then
        return
    end
    local grid = harvest(ed, rec.grid)
    local pos = api.nvim_win_get_cursor(0)
    local index, _ = cell_at(ed)
    -- The separator is a rendered line, not a data row: the data index is the line number minus the
    -- separator lines above it.
    local line = pos[1]
    local data_index = line
    if grid.header and line > 2 then
        data_index = line - 1
    end
    data_index = math.max(1, math.min(data_index, #grid.rows))

    if what == "row" then
        if add then
            local blank = {}
            for i = 1, #(grid.rows[1] or {}) do
                blank[i] = ""
            end
            table.insert(grid.rows, data_index + 1, blank)
        elseif #grid.rows > 1 then
            table.remove(grid.rows, data_index)
        end
    else
        for _, row in ipairs(grid.rows) do
            if add then
                table.insert(row, index + 1, "")
            elseif #row > 1 then
                table.remove(row, index)
            end
        end
        if add then
            table.insert(grid.aligns, index + 1, "left")
        elseif #grid.aligns > 1 then
            table.remove(grid.aligns, index)
        end
    end

    rec.grid = grid
    vim.bo[ed].modifiable = true
    api.nvim_buf_set_lines(ed, 0, -1, false, M.format(grid))
    api.nvim_win_set_cursor(0, { math.min(pos[1], api.nvim_buf_line_count(ed)), 0 })
end

--- Re-align the editor's own text: the grid is reformatted from what is currently typed, so the
--- columns snap back after an edit that widened one. Bound to a key rather than run on every
--- keystroke — reformatting under the cursor while typing moves the text out from under it.
---@param ed integer
---@return nil
local function realign(ed)
    local rec = open_editors[ed]
    if rec == nil then
        return
    end
    local pos = api.nvim_win_get_cursor(0)
    rec.grid = harvest(ed, rec.grid)
    api.nvim_buf_set_lines(ed, 0, -1, false, M.format(rec.grid))
    api.nvim_win_set_cursor(0, { math.min(pos[1], api.nvim_buf_line_count(ed)), pos[2] })
end

--- Wire the editor's own keys onto its buffer.
---@param ed integer
---@return nil
local function set_keys(ed)
    local keys = config.tables_editor.keys
    ---@param lhs string|false
    ---@param fn_ fun()
    ---@param modes string[]
    local function map(lhs, fn_, modes)
        if type(lhs) ~= "string" or lhs == "" then
            return
        end
        vim.keymap.set(modes or { "n" }, lhs, fn_, { buffer = ed, nowait = true, silent = true })
    end
    map(keys.commit, function()
        commit(ed)
    end, { "n", "i" })
    map(keys.next_cell, function()
        move_cell(ed, 1)
    end, { "n" })
    map(keys.prev_cell, function()
        move_cell(ed, -1)
    end, { "n" })
    map(keys.row_add, function()
        edit_structure(ed, "row", true)
    end, { "n" })
    map(keys.row_delete, function()
        edit_structure(ed, "row", false)
    end, { "n" })
    map(keys.column_add, function()
        edit_structure(ed, "column", true)
    end, { "n" })
    map(keys.column_delete, function()
        edit_structure(ed, "column", false)
    end, { "n" })
    map(keys.realign, function()
        realign(ed)
    end, { "n" })
end

--- Open the editor for the table under the cursor.
---@param buf integer?
---@return boolean opened
function M.open(buf)
    buf = buf or api.nvim_get_current_buf()
    local row = api.nvim_win_get_cursor(0)[1] - 1
    local grid = M.grid_at(buf, row)
    if grid == nil then
        vim.notify("lvim-render: the cursor is not in a table", vim.log.levels.WARN)
        return false
    end

    local ed = api.nvim_create_buf(false, true)
    vim.bo[ed].buftype = "nofile"
    vim.bo[ed].bufhidden = "wipe"
    vim.bo[ed].swapfile = false
    -- The REAL filetype, so treesitter colours the grid exactly as the document does and the
    -- reader edits familiar-looking text — but NOT rendered: this plugin would draw a box over the
    -- text the reader came here to edit. The refusal is set BEFORE the filetype, since setting the
    -- filetype is what fires the attach.
    vim.b[ed].lvim_render_skip = true
    vim.bo[ed].filetype = grid.format
    vim.bo[ed].modifiable = true
    api.nvim_buf_set_lines(ed, 0, -1, false, M.format(grid))

    local surface = require("lvim-ui.surface")
    local cfg = config.tables_editor
    local handle = surface.open({
        mode = "float",
        -- Three borders exist on this chassis and all three have to be said: the CONTAINER's ring
        -- (`border`), the one around the panel GROUP (`group_border`) and the one around each PANEL
        -- (`panel_border`). Setting only the first leaves the other two drawing, which is exactly
        -- what happened the first time. The grid is the shape here; a frame around it competes with
        -- the box glyphs inside it.
        border = cfg.border,
        group_border = false,
        panel_border = "none",
        title = cfg.title,
        title_pos = "center",
        size = { width = { fixed = cfg.width }, height = { fixed = cfg.height } },
        content = {
            blocks = {
                {
                    id = "grid",
                    provider = {
                        -- NOT the surface's `editable` flag: that one belongs to the input FIELD
                        -- and starts its panel in insert. A table editor is a normal-mode editor —
                        -- you arrive on the grid, move, then type. The buffer is this module's own
                        -- and it sets its own `modifiable`.
                        update = function(pan)
                            -- The panel hosts THIS buffer: the surface renders nothing into it, so
                            -- what the reader types is never overwritten by a relayout.
                            if api.nvim_win_is_valid(pan.win) and api.nvim_win_get_buf(pan.win) ~= ed then
                                api.nvim_win_set_buf(pan.win, ed)
                            end
                            -- Its own window, its own rule: the grid is never wrapped, whatever the
                            -- document's window does. That is the whole reason this editor exists.
                            vim.wo[pan.win].wrap = false
                            vim.wo[pan.win].number = false
                            vim.wo[pan.win].relativenumber = false
                            vim.wo[pan.win].signcolumn = "no"
                            vim.wo[pan.win].cursorline = true
                        end,
                    },
                },
            },
        },
        footer = {
            bars = {
                {
                    align = "center",
                    fill = true,
                    items = {
                        {
                            key = cfg.keys.commit,
                            name = "write back",
                            run = function()
                                commit(ed)
                            end,
                        },
                        { key = cfg.keys.next_cell, name = "cell" },
                        { key = cfg.keys.row_add, name = "+row" },
                        { key = cfg.keys.column_add, name = "+col" },
                        { key = cfg.keys.realign, name = "align" },
                        {
                            key = "q",
                            name = "cancel",
                            run = function(st)
                                st.close()
                            end,
                        },
                    },
                },
            },
        },
        on_close = function()
            open_editors[ed] = nil
        end,
    })
    open_editors[ed] = { grid = grid, source = buf, buf = ed, handle = handle }
    -- The surface may leave the panel in insert (its editable field does); a grid is navigated
    -- before it is typed into, so the editor always arrives in NORMAL mode.
    vim.schedule(function()
        if api.nvim_get_mode().mode:sub(1, 1) == "i" then
            vim.cmd("stopinsert")
        end
        vim.bo[ed].modifiable = true
        -- AFTER the surface, deliberately. The panel hosts THIS buffer, so the chassis maps its own
        -- navigation keys onto it — including <CR>, which it reads as "activate the focused button".
        -- Here <CR> means "write the table back", and the editor's keys have to be the last word on
        -- its own buffer.
        set_keys(ed)
    end)
    return handle ~= nil
end

return M
