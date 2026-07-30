-- lvim-render.engine: the lifecycle and the paint path. Attach decides WHETHER a buffer renders
-- (format match, size gates, grammar present); ONE decoration provider paints every attached
-- buffer's visible rows with ephemeral marks; `on_bytes` + a per-buffer debounce keep the fold
-- outline current; window options (conceal + folds) are OWNED politely — saved on apply, restored
-- on detach or :LvimRender off, and never touched on a window that moved to another buffer.
--
-- WHY EPHEMERAL. The provider re-emits every visible decoration on every redraw, which sounds
-- expensive and is the cheap path: nothing persistent accumulates, nothing needs cleanup, and a
-- 10k-line document costs what one screen costs (how-build-panels §17 — persistent per-keystroke
-- extmarks are the forbidden slow path).
--
-- CANCELLATION IS ONE MECHANISM: every scheduled rebuild carries the generation it was created
-- for and aborts on entry when the buffer has moved on. The debounce timer restarts per change,
-- so the rebuild that lands is always for the newest text.
--
---@module "lvim-render.engine"

local config = require("lvim-render.config")
local fold = require("lvim-render.fold")
local queries = require("lvim-render.queries")
local render = require("lvim-render.render")
local state = require("lvim-render.state")

local api = vim.api
local uv = vim.uv

local M = {}

---@class LvimRenderStats
---@field windows integer  provider passes painted
---@field ops integer      decoration ops emitted in total
---@field ns integer       nanoseconds spent collecting + emitting, in total
M.stats = { windows = 0, ops = 0, ns = 0 }

---@type string[]  the formats whose RENDERER exists — the phase gate. Config blocks for the
--- others are already the fixed surface; a format joins this list when its phase lands, and only
--- then do its buffers attach (so no window options are taken for a renderer that is not there).
M.formats = { "markdown", "typst", "org", "latex" }

--- The format block a filetype belongs to, if any (enabled + implemented).
---@param ft string
---@return string|nil format
function M.format_for(ft)
    for _, format in ipairs(M.formats) do
        local fconf = config[format]
        if fconf ~= nil and vim.tbl_contains(fconf.filetypes or {}, ft) then
            return format
        end
    end
    return nil
end

--- The window options configured for a buffer's filetype: `["*"]` for every rendered filetype,
--- with the filetype's own table merged over it. Returns a fresh table, never the config's.
---@param buf integer
---@return table<string, any>
local function configured_options(buf)
    local conf = config.win_options
    if type(conf) ~= "table" then
        return {}
    end
    local out = {}
    for name, value in pairs(conf["*"] or {}) do
        out[name] = value
    end
    for name, value in pairs(conf[vim.bo[buf].filetype] or {}) do
        out[name] = value
    end
    return out
end

--- Restore a window's saved options, if we own any.
---@param win integer
---@return nil
local function restore_win(win)
    local saved = state.wins[win]
    if saved == nil then
        return
    end
    state.wins[win] = nil
    state.reveal[win] = nil
    if not api.nvim_win_is_valid(win) then
        return
    end
    local wo = vim.wo[win]
    wo.conceallevel = saved.conceallevel
    wo.concealcursor = saved.concealcursor
    -- By the names RECORDED, not the ones configured now: an option dropped from the config after
    -- this window was taken over still has to be handed back as it was found.
    for name, value in pairs(saved.options or {}) do
        pcall(api.nvim_set_option_value, name, value, { win = win })
    end
    if config.fold.enabled and config.fold.headings then
        wo.foldmethod = saved.foldmethod
        wo.foldexpr = saved.foldexpr
        wo.foldtext = saved.foldtext
        wo.foldenable = saved.foldenable
        wo.foldlevel = saved.foldlevel
        if saved.foldmethod == "manual" then
            -- Switching back to manual KEEPS the expr-computed folds as manual folds (Vim's
            -- documented carry-over), and the restored foldlevel then closes them — the document
            -- would come back folded by ghosts of ours. Any manual folds the user had were already
            -- unrecoverable the moment expr took over, so every fold present here is ours to
            -- remove; eliminating them completes the restore.
            api.nvim_win_call(win, function()
                pcall(vim.cmd, "normal! zE")
            end)
        end
    end
end

---@type string  the foldexpr the plugin sets — and the FINGERPRINT that tells an inherited window
--- apart: a split of an owned window is born carrying our options, so "what was there before us"
--- never existed for it and must come from the buffer's baseline instead.
local FOLDEXPR = "v:lua.require'lvim-render.fold'.expr()"

--- Set our option values on a window. Split from the snapshotting so an OWNED window can be
--- RE-ASSERTED without re-saving: window-local options are re-initialised whenever a buffer
--- (re-)enters a window, and other config machinery legitimately writes them on the same events
--- (measured live: the control-center's window-option enforcer re-applied `conceallevel = 0` on
--- every BufWinEnter/FileType, and a value set once at attach silently lost). Re-asserting at
--- the same seam — BufWinEnter, never CursorMoved — is the ownership §3a promises.
---@param win integer
---@return nil
local function assert_win(win)
    local wo = vim.wo[win]
    -- RAW PREVIEW: the window shows the file's own characters, so 'conceallevel' is 0 — not the
    -- reader's own setting, because "raw" is a claim about what they SEE, and Neovim's markdown
    -- queries conceal `**` and `[]` on their own at level 2. Asserted here, at the same reenter
    -- seam as every other owned option, rather than written once from outside and lost.
    local st = state.get(api.nvim_win_get_buf(win))
    if st ~= nil and st.raw then
        wo.conceallevel = 0
        wo.concealcursor = ""
    else
        wo.conceallevel = config.conceal.level
        wo.concealcursor = config.conceal.cursor
    end
    -- The configured window chrome for this filetype, re-asserted here for the same reason the
    -- conceal options are: window-local values are re-initialised whenever a buffer re-enters a
    -- window, so a value written once at attach silently reverts.
    for name, value in pairs(configured_options(api.nvim_win_get_buf(win))) do
        pcall(api.nvim_set_option_value, name, value, { win = win })
    end
    if config.fold.enabled and config.fold.headings then
        wo.foldmethod = "expr"
        wo.foldexpr = FOLDEXPR
        if config.fold.text.enabled then
            wo.foldtext = "v:lua.require'lvim-render.fold'.text()"
        end
        wo.foldenable = true
    end
end

--- Apply our window options to a window showing an attached buffer, saving what was there first.
---@param win integer
---@param buf integer
---@return nil
local function apply_win(win, buf)
    local saved = state.wins[win]
    if saved ~= nil and saved.buf == buf then
        -- Already owned: just re-assert the values (the reinit seam), keep the saved baseline.
        assert_win(win)
        return
    end
    if saved ~= nil then
        -- The window moved from one attached buffer to another; put the first one's values back
        -- before saving the new baseline.
        restore_win(win)
    end
    local st = state.get(buf)
    local wo = vim.wo[win]
    ---@type LvimRenderWinSaved
    local snapshot
    if
        config.fold.enabled
        and config.fold.headings
        and wo.foldexpr == FOLDEXPR
        and st ~= nil
        and st.baseline ~= nil
    then
        -- Inherited from a split of an owned window: its current values are OURS, so the honest
        -- thing to restore later is what the buffer's first window had before attach.
        snapshot = vim.tbl_extend("force", {}, st.baseline)
        snapshot.buf = buf
    else
        snapshot = {
            buf = buf,
            foldmethod = wo.foldmethod,
            foldexpr = wo.foldexpr,
            foldtext = wo.foldtext,
            foldenable = wo.foldenable,
            foldlevel = wo.foldlevel,
            conceallevel = wo.conceallevel,
            concealcursor = wo.concealcursor,
        }
    end
    if snapshot.options == nil then
        -- What the reader had, for exactly the options we are about to take over. Recorded once,
        -- with the window's own values — the split-inherited branch above carries the first
        -- window's baseline instead, which is what that window really had before us.
        local before = {}
        for name in pairs(configured_options(buf)) do
            local ok, value = pcall(api.nvim_get_option_value, name, { win = win })
            if ok then
                before[name] = value
            end
        end
        snapshot.options = before
    end
    state.wins[win] = snapshot
    if st ~= nil and st.baseline == nil then
        st.baseline = vim.tbl_extend("force", {}, snapshot)
    end
    assert_win(win)
    if config.fold.enabled and config.fold.headings then
        -- Only on FIRST ownership: re-asserting 'foldlevel' at the reinit seam would stomp the
        -- user's zM/zR state on every buffer re-entry.
        wo.foldlevel = config.fold.level
    end
end

--- Apply or restore window options for every window currently showing a buffer.
---@param buf integer
---@param on boolean
---@return nil
local function sync_wins(buf, on)
    for _, win in ipairs(api.nvim_list_wins()) do
        if api.nvim_win_get_buf(win) == buf then
            if on then
                apply_win(win, buf)
            else
                restore_win(win)
            end
        end
    end
end

--- Ask for a repaint of a buffer's windows.
---@param buf integer
---@return nil
local function redraw(buf)
    pcall(api.nvim__redraw, { buf = buf, valid = true, flush = false })
end

--- Ask for a repaint after a WALK transition — entering, stepping, leaving. These change the
--- HEIGHT of the box's virtual block (the page slides, pagination turns on or off) and may move
--- the topline in the same tick, so the existing screen lines are NOT valid, and saying they are
--- (`valid = true`) left a stale duplicated row on screen under key auto-repeat — measured: the
--- box's bottom border drawn twice, 3/3 profile runs; 0/3 with an honest redraw. Per BUFFER, not
--- per window: every window showing the buffer draws the same paged box.
---
--- THE MARKS ARE BROUGHT CURRENT FIRST, HERE, OUTSIDE ANY REDRAW (`M.sync_view`). Writing
--- persistent `virt_lines`/`conceal_lines` marks from inside the decoration provider changes
--- line HEIGHTS while the frame is being assembled, and the scroll-shift optimisation then
--- carries the lie forward: a row drawn twice, multiplying under wheel scrolling (measured —
--- a cursor row triplicated after use + wheel bursts; zero artifacts with the writes moved
--- out). The provider only ever CHECKS the lane now and defers to this function.
---@param buf integer
---@return nil
local function redraw_walk(buf)
    M.sync_view(buf)
    pcall(api.nvim__redraw, { buf = buf, valid = false, flush = false })
end

--- `redraw_walk` for a repaint that must NOT move the view: replacing the block mark (any
--- content change — a step relights a row) momentarily removes the mark the view's 'topfill'
--- hangs on, and the fill collapses to a normalised topline (measured: a below-parked walk's
--- view threw to the anchor on every step). The view is captured before the sync and re-landed
--- after it, while the final mark is in place — then the repaint honours it.
---@param buf integer
---@return nil
local function redraw_walk_keep_view(buf)
    local v = vim.fn.winsaveview()
    M.sync_view(buf)
    vim.fn.winrestview({ topline = v.topline, topfill = v.topfill })
    pcall(api.nvim__redraw, { buf = buf, valid = false, flush = false })
end

---@type integer  screen lines revealed when a walk ENTERS a box that does not fit under the
--- parked row: two borders + the active row — the page follows the active row, so this is all a
--- visible entry needs. Deliberately minimal: entry must read as "the cursor stopped on the
--- table", not as a scroll; every further line arrives one step at a time.
local ENTRY_ROOM = 3

--- End a widget walk. Every exit goes through here — stepping off either end, moving the cursor
--- away, opening the editor, an edit landing while a walk is up — so no path can leave the box
--- claiming an active row nobody is on. (The walk borrows nothing any more: the view is moved
--- only through `winrestview`, one line at a time, so there is nothing to give back.)
---@param st LvimRenderBufState|nil
---@return nil
local function release_box(st)
    if st ~= nil then
        st.box_active = nil
    end
end

--- The debounced rebuild: outline + fold refresh + repaint. Runs on the main loop.
---@param buf integer
---@param gen integer  the generation this work was scheduled for
---@return nil
local function rebuild(buf, gen)
    local st = state.get(buf)
    if st == nil or st.generation ~= gen or not api.nvim_buf_is_valid(buf) then
        -- Superseded or gone: a stale rebuild never paints stale decorations.
        return
    end
    local dirty = st.dirty
    st.dirty = nil
    -- OFF-SCREEN MARKS GO AT EVERY EDIT. A boxed table keeps its marks beyond the visible rows on
    -- purpose (that is what lets it draw while its anchor is scrolled away), and the lane that
    -- reconciles them only ever visits rows a pass SAW — so a table edited while off screen would
    -- keep a box describing text that no longer exists, and `conceal_lines` marks hiding rows that
    -- are no longer a table's. Dropping the whole lane on the debounce is the honest reset: the
    -- next paint rebuilds exactly what is visible, at the same screen cost as any other redraw.
    api.nvim_buf_clear_namespace(buf, render.ns_inline, 0, -1)
    -- THE BOX BOOKKEEPING GOES WITH THE LANE. `boxed`/`box_rows`/`box_lines` describe the marks
    -- just dropped, in the ROW NUMBERS of the text as it was — after an edit both can be wrong,
    -- and the navigation that reads them would walk phantom tables (measured: deleting a table
    -- left its span behind, and `j` on the prose that took its place entered a widget walk,
    -- parked the cursor and scrolled the view). The next paint re-records exactly what it draws.
    -- `tables` is generation-keyed and could only serve stale entries' memory, never their data.
    st.tables = {}
    st.boxed = nil
    st.box_rows = nil
    st.box_lines = nil
    release_box(st)
    fold.rebuild(buf)
    if dirty ~= nil then
        -- A heading edit changes the fold level of every line down to the next heading, so the
        -- honest refresh range is "from the first touched row to the end".
        fold.refresh(buf, dirty.first, api.nvim_buf_line_count(buf) - 1)
    end
    -- The lane was just dropped wholesale: rebuild it HERE, outside any redraw, so the first
    -- post-edit frame draws with correct marks instead of dry-checking a fully empty lane and
    -- deferring everything by a frame. Legal extmark writes (this runs from the debounce
    -- schedule) are tracked by Neovim itself, so the plain `valid = true` repaint stays honest.
    M.sync_view(buf)
    redraw(buf)
end

--- Track an edit: extend the dirty span, bump the generation, restart the debounce.
---@param buf integer
---@param start_row integer
---@param old_end integer  rows the change removed, relative to start_row
---@param new_end integer  rows the change added, relative to start_row
---@return boolean|nil detach  true tells nvim_buf_attach to let go
local function on_bytes(buf, start_row, old_end, new_end)
    local st = state.get(buf)
    if st == nil then
        return true
    end
    st.generation = st.generation + 1
    local last = start_row + math.max(old_end, new_end)
    if st.dirty == nil then
        st.dirty = { first = start_row, last = last }
    else
        st.dirty.first = math.min(st.dirty.first, start_row)
        st.dirty.last = math.max(st.dirty.last, last)
    end
    if st.timer ~= nil then
        local gen = st.generation
        st.timer:start(
            config.debounce,
            0,
            vim.schedule_wrap(function()
                rebuild(buf, gen)
            end)
        )
    end
end

--- Hide the hardware cursor while it stands inside a table drawn as a BOX: those rows are hidden,
--- so the cursor has nothing to stand on there, and the box paints the active row itself. Through
--- lvim-utils' own cursor registry — never a hand-rolled 'guicursor' save/restore.
---@param buf integer
---@return nil
local function sync_box_cursor(buf)
    if not config.tables_hide_cursor then
        return
    end
    local st = state.get(buf)
    local inside = false
    if st ~= nil and st.boxed ~= nil then
        local row = api.nvim_win_get_cursor(0)[1] - 1
        for first, last in pairs(st.boxed) do
            if row >= first and row <= last then
                inside = true
                break
            end
        end
        -- A WALK COUNTS AS BEING INSIDE. The widget parks the real cursor on the displayed row
        -- ABOVE the table — outside every boxed span — so the span test alone would leave a
        -- hardware cursor blinking on the anchor while the box paints the row you are actually on.
        if st.box_active ~= nil and row == st.box_active.parked then
            inside = true
        end
    end
    local ok, cursor = pcall(require, "lvim-utils.cursor")
    if ok and type(cursor.mark_hide_buffer) == "function" then
        cursor.mark_hide_buffer(buf, inside or nil)
    end
end

--- One line's total screen rows in the current window — wrap, virtual lines and concealed rows
--- all accounted (an intermediate box's ANCHOR line counts its whole block, and a concealed row
--- counts zero). The honest unit for every view computation here; buffer-line arithmetic broke
--- twice (a wrapped line counted as one row — measured both times).
---@param l integer  1-based line
---@return integer rows
local function line_rows(l)
    return api.nvim_win_text_height(0, { start_row = l - 1, end_row = l - 1 }).all
end

--- The window's TEXT-AREA height. `nvim_win_get_height` counts the winbar row, `winline()` does
--- not: mixing the two put a fill one row too deep, 'scrolloff' was then violated by one, and
--- Neovim's own correction dragged the cursor off its row during the flush (measured). EVERY
--- view computation here uses this, never the raw height.
---@param win integer
---@return integer rows
local function text_height(win)
    local h = api.nvim_win_get_height(win)
    if api.nvim_get_option_value("winbar", { win = win }) ~= "" then
        h = h - 1
    end
    return h
end

--- The next DISPLAYED line at or after `l`: a line inside a boxed span is concealed and can
--- never be a topline (parking one there is the measured stable MIS-DRAW state).
---@param st LvimRenderBufState
---@param l integer  1-based line
---@return integer
local function next_displayed(st, l)
    for f, last in pairs(st.boxed or {}) do
        -- f/last are 0-based rows; concealed lines are f+1 .. last+1 in 1-based terms.
        if l >= f + 1 and l <= last + 1 then
            return last + 2
        end
    end
    return l
end

--- The screen rows a DISPLAYED line costs, block included. `nvim_win_text_height` books a box's
--- `virt_lines` as the fill of the FIRST CONCEALED row (measured: the anchor row answers all=1,
--- the concealed row after it all=fill=8) — and the displayed-line walks skip concealed rows, so
--- an anchor must be costed together with that row or every intermediate box counts as one line
--- (measured: a jump walk sailed 30 lines past its budget).
---@param st LvimRenderBufState
---@param l integer  1-based displayed line
---@return integer rows
local function display_cost(st, l)
    if (st.boxed or {})[l] ~= nil then
        return api.nvim_win_text_height(0, { start_row = l - 1, end_row = l }).all
    end
    return line_rows(l)
end

--- Leave a boxed table DOWNWARD as one defined navigation step: the cursor lands on the first
--- displayed row after the table, and the view slides by EXACTLY the overshoot — the number of
--- screen rows by which the landing row would sink past the 'scrolloff' line — computed here and
--- applied atomically, never left to Neovim's scroll recompute (measured failures: a tall block
--- threw the topline past itself entirely, 74 → 172; and a bare cursor move let 'scrolloff' drag
--- the cursor off the landing row). The slide consumes screen rows from the current topline
--- forward — prose lines by their real height, an intermediate box's anchor with its whole block —
--- and when it reaches the exited table's anchor it stops INSIDE the block: topline = the first
--- concealed row with 'topfill' = the block's remaining tail. That state is the native one
--- (Neovim itself represents a landing under a block this way, and CTRL-Y walks the fill), and
--- for a block taller than the window it degenerates to exactly "tail + cursor under it"; for a
--- small box near the window's bottom it is a few-row slide that keeps all context above — the
--- binary fits/tail split repositioned those (topline 20 → 45 on a 16-line box, measured, the
--- owner's report). The lane is reconciled synchronously FIRST (`M.sync_inline`) so the
--- full-height block is already the mark any fill counts against, and the whole landing is ONE
--- full-dict `winrestview`.
---@param buf integer
---@param st LvimRenderBufState
---@param first integer  0-based first source row of the table
---@param last integer  0-based last source row of the table
---@return nil
-- FORWARD DECLARATION. The two view steppers are defined below, next to the display-unit model
-- they belong to, but the box EXITS above them step through that same model — a local is only in
-- scope after its definition, so calling one from here without this reads as a global and is nil
-- (measured in the owner's session: `attempt to call global 'view_step_up'`, thrown on every
-- upward exit, which silently turned the exit into a no-op).
---@type fun(st: LvimRenderBufState, buf: integer, view: { topline: integer, topfill: integer }, cap: integer, budget: integer): { topline: integer, topfill: integer }
local view_step_up

local function exit_box_below(buf, st, first, last)
    -- Read the layout BEFORE anything moves. The height is the TEXT area: `nvim_win_get_height`
    -- counts the winbar row, `winline()` does not, and one row too deep violates 'scrolloff' —
    -- Neovim's correction then drags the cursor off the landing row during the flush (measured).
    local view = vim.fn.winsaveview()
    local wl = vim.fn.winline()
    local h = text_height(0)
    local so = api.nvim_get_option_value("scrolloff", { win = 0 })
    local full = (st.box_lines or {})[first] or 0
    release_box(st)
    local total = api.nvim_buf_line_count(buf)
    local out = math.max(1, math.min(last + 2, total))
    -- The landing row's screen line if nothing scrolled, versus where 'scrolloff' allows it.
    local overshoot = wl + full + 1 - math.max(h - so, 2)
    if overshoot <= 0 then
        -- Everything fits where it stands: the cursor moves, the view does not.
        api.nvim_win_set_cursor(0, { out, 0 })
    else
        M.sync_inline(api.nvim_get_current_win(), buf, math.max(0, first - 1), last + 1)
        local anchor = first -- 1-based displayed line the block hangs below
        local tl = view.topline
        local fill = 0
        local remaining = overshoot
        -- A topline already inside an earlier box's run carries that block's tail as fill:
        -- consume the fill first, then continue from the first displayed line after that run.
        if view.topfill > 0 then
            if remaining < view.topfill then
                fill = view.topfill - remaining
                remaining = 0
            else
                remaining = remaining - view.topfill
                tl = next_displayed(st, tl)
            end
        end
        while remaining > 0 and tl <= anchor do
            if tl == anchor then
                -- The exited table's anchor: one text row, then the landing stops INSIDE the
                -- block — its first concealed row as topline, the untravelled tail as fill.
                remaining = remaining - 1
                fill = math.max(0, full - remaining)
                tl = anchor + 1
                remaining = 0
            else
                local cost = display_cost(st, tl)
                if remaining < cost and (st.boxed or {})[tl] ~= nil then
                    -- An INTERMEDIATE box whose cost exceeds what is left: consuming it whole
                    -- would over-slide the view by its height (measured: a 7-row overshoot
                    -- slid 17). Land inside its fill states instead — the anchor's text row
                    -- costs 1, each block row one more — consuming exactly the remainder.
                    local bfull = (st.box_lines or {})[tl] or 1
                    fill = math.max(0, bfull - (remaining - 1))
                    tl = tl + 1 -- its first concealed row (1-based)
                    remaining = 0
                else
                    -- A whole displayed line (over-consuming a wrapped line's rows slightly
                    -- lifts the landing rather than sinking it — the safe direction).
                    remaining = remaining - cost
                    tl = next_displayed(st, tl + 1)
                end
            end
        end
        vim.fn.winrestview({
            lnum = out,
            col = 0,
            coladd = 0,
            curswant = 0,
            leftcol = 0,
            skipcol = 0,
            topline = tl,
            topfill = fill,
        })
    end
    sync_box_cursor(buf)
    redraw_walk(buf)
end

--- The displayed line at or before `l` — the mirror of `next_displayed`: a line inside a boxed
--- run resolves to that box's ANCHOR line (always displayed; boxes on row 0 are refused).
---@param st LvimRenderBufState
---@param buf integer
---@param l integer  1-based line
---@return integer
local function prev_displayed(st, buf, l)
    local span = render.boxed_span(buf, l - 1)
    if span ~= nil then
        return math.max(span.first, 1)
    end
    return l
end

--- Leave a boxed table UPWARD from a walk parked BELOW it: the cursor lands on the ANCHOR — the
--- displayed row above the table — and, when the anchor is not already comfortably on screen,
--- the view is landed atomically with the anchor near the top margin and the box's head below it
--- (the mirror of `exit_box_below`; letting Neovim scroll to a far-above cursor snaps over the
--- block — measured on the upward tour: topline 74 → 61 in one press).
---@param buf integer
---@param st LvimRenderBufState
---@param first integer  0-based first source row of the table
---@param last integer  0-based last source row of the table
---@return nil
local function exit_box_above(buf, st, first, last)
    release_box(st)
    local anchor_line = math.max(first, 1) -- 1-based displayed line above the table
    local so = api.nvim_get_option_value("scrolloff", { win = 0 })
    if anchor_line >= vim.fn.line("w0") + so then
        -- Already comfortably on screen: the cursor moves, the view does not.
        api.nvim_win_set_cursor(0, { anchor_line, 0 })
    else
        M.sync_inline(api.nvim_get_current_win(), buf, math.max(0, first - 1), last + 1)
        -- SCREEN ROWS, stepped one at a time — never lines. Walking back `scrolloff` LINES from
        -- the anchor crosses whole boxes in a single step (each is one line but a windowful of
        -- rows): the owner's recorder caught an exit whose anchor already stood on the window's
        -- FIRST row leaping `topline 76 → 44`. The view instead climbs by exactly the rows the
        -- anchor's margin is short, through the same display-unit stepper the walk uses, so an
        -- anchor that is already comfortably placed costs nothing and one that sits at the edge
        -- costs the margin.
        local vv = vim.fn.winsaveview()
        local h = text_height(0)
        local cap = math.max(h - 1 - so, 1)
        local vbudget = math.max(h - so, 2)
        -- A FEW ROWS OF CONTEXT, not the bare margin. Landing on 'scrolloff' exactly leaves the
        -- cursor at the limit of its own travel, so every following `k` can only slide the page
        -- under a motionless cursor — reported twice, and visible in the recorder as `wl 3→3`
        -- presses after each upward exit. Leaving the table upward is a move TOWARDS the text
        -- above it, so that text is what the landing should show. Counted in SCREEN rows and
        -- bounded by a fifth of the window: an earlier line-counted version stepped over whole
        -- boxes and cost 32 lines.
        local margin = math.min(so + 3, math.max(math.floor(h / 5), so))
        local v2 = { topline = vv.topline, topfill = vv.topfill }
        for _ = 1, h do
            -- Rows above the anchor in the view as it stands: the fill, plus the real height of
            -- every displayed line from the top down to the line before it.
            local above = v2.topfill
            if v2.topline <= anchor_line - 1 then
                above = above + api.nvim_win_text_height(0, {
                    start_row = v2.topline - 1,
                    end_row = anchor_line - 2,
                }).all
            elseif v2.topline > anchor_line then
                above = -1 -- the anchor is above the top edge: keep climbing
            end
            if above >= margin then
                break
            end
            local stepped = view_step_up(st, buf, v2, cap, vbudget)
            if stepped.topline == v2.topline and stepped.topfill == v2.topfill then
                break
            end
            v2 = stepped
        end
        vim.fn.winrestview({
            lnum = anchor_line,
            col = 0,
            coladd = 0,
            curswant = 0,
            leftcol = 0,
            skipcol = 0,
            topline = v2.topline,
            topfill = v2.topfill,
        })
    end
    sync_box_cursor(buf)
    redraw_walk(buf)
end

--- One DOWNWARD screen-row step of a view over boxed-table state. The display units are: a
--- displayed line (top row leaves → next line), a box's ANCHOR line (its text row leaves → the
--- block becomes 'topfill', capped at `cap` — a block taller than the window has NO expressible
--- "middle" scroll positions with this primitive, only its tail states, so a tall box is crossed
--- in one honest jump to its tail), and a fill state (one tail line fewer; spent fill normalises
--- to the first displayed line after the run — a fill-less topline on a concealed row is the
--- measured stable mis-draw state). `st.boxed` is keyed by the 0-based first table row, which is
--- numerically the anchor's 1-based line — used directly.
---@param st LvimRenderBufState
---@param buf integer
---@param view { topline: integer, topfill: integer }
---@param total integer
---@param cap integer  the largest legal fill: text height − 1 − 'scrolloff' (one row for the
---   cursor's displayed line under the tail, its margin respected)
---@return { topline: integer, topfill: integer }
local function view_step_down(st, buf, view, total, cap)
    if view.topfill == 0 then
        -- An UNNORMALISED view (topline on a concealed row, no fill) displays identically to
        -- topline = the first row after the run; normalise before stepping, or the step lands
        -- inside the run and the materialising block lurches the layout (measured: 11 rows).
        local selfspan = render.boxed_span(buf, view.topline - 1)
        if selfspan ~= nil then
            view = { topline = math.min(selfspan.last + 2, total), topfill = 0 }
        end
    end
    if view.topfill > 0 then
        local f = view.topfill - 1
        if f > 0 then
            return { topline = view.topline, topfill = f }
        end
        local span = render.boxed_span(buf, view.topline - 1)
        return { topline = span ~= nil and math.min(span.last + 2, total) or view.topline, topfill = 0 }
    end
    local last = (st.boxed or {})[view.topline]
    if last ~= nil then
        local full = (st.box_lines or {})[view.topline] or 1
        return { topline = view.topline + 1, topfill = math.max(1, math.min(full, cap)) }
    end
    return { topline = math.min(view.topline + 1, total), topfill = 0 }
end

--- One UPWARD screen-row step — the mirror of `view_step_down`: fill grows to the whole block
--- (small box) or to `cap` (tall box — the stall would otherwise ask for a state whose cursor
--- has no displayed row, and Neovim snaps; measured), then the view jumps over the block and
--- lands the ANCHOR at the window's bottom margin, displayed lines walked by their real heights.
---@param st LvimRenderBufState
---@param buf integer
---@param view { topline: integer, topfill: integer }
---@param cap integer  see `view_step_down`
---@param budget integer  text height − 'scrolloff': the rows above the anchor after the jump
---@return { topline: integer, topfill: integer }
function view_step_up(st, buf, view, cap, budget)
    if view.topfill == 0 then
        -- See view_step_down: normalise a concealed fill-less topline before stepping.
        local selfspan = render.boxed_span(buf, view.topline - 1)
        if selfspan ~= nil then
            view = { topline = math.min(selfspan.last + 2, api.nvim_buf_line_count(buf)), topfill = 0 }
        end
    end
    if view.topfill > 0 then
        local span = render.boxed_span(buf, view.topline - 1)
        local full = span ~= nil and ((st.box_lines or {})[span.first] or view.topfill) or view.topfill
        if view.topfill < math.min(full, cap) then
            return { topline = view.topline, topfill = view.topfill + 1 }
        end
        if full <= cap then
            -- The whole block is shown: the anchor's text row comes back.
            return { topline = math.max(view.topline - 1, 1), topfill = 0 }
        end
        -- A tall block's remaining positions are inexpressible: jump over it, the anchor at
        -- the window's bottom margin.
        local tl = span ~= nil and math.max(span.first, 1) or math.max(view.topline - 1, 1)
        local acc = 1 -- the anchor's own text row; its block stays below the window edge
        while tl > 1 do
            local p = prev_displayed(st, buf, tl - 1)
            local hh = display_cost(st, p)
            if acc + hh > budget or p >= tl then
                break
            end
            acc = acc + hh
            tl = p
        end
        return { topline = tl, topfill = 0 }
    end
    local prev = view.topline - 1
    if prev < 1 then
        return view
    end
    local span = render.boxed_span(buf, prev - 1)
    if span ~= nil then
        return { topline = span.first + 1, topfill = 1 }
    end
    return { topline = prev, topfill = 0 }
end

--- The wheel over a document with boxed tables, stepped through the view model above: Neovim's
--- native scroll cannot step DOWN over a `conceal_lines` run — a notch from a fill state snaps
--- past the whole run (12-20 lines instead of 'mousescroll', measured live and in --clean). The
--- cursor is clamped onto DISPLAYED lines only (never dragged onto a hidden row — the native
--- drag was what re-triggered the block scroll), and any walk ends here. A window under the
--- pointer that is not the current one keeps the native behaviour, applied where the pointer is
--- (a buffer-local mouse mapping otherwise captures scrolls aimed at other windows).
---@param buf integer
---@param delta integer  1 down, -1 up
---@return nil
local function wheel_scroll(buf, delta)
    local count = tonumber((vim.o.mousescroll or ""):match("ver:(%d+)")) or 3
    local native = ("normal! %d%s"):format(count, delta > 0 and "\5" or "\25")
    local win = api.nvim_get_current_win()
    local ok, mp = pcall(vim.fn.getmousepos)
    if ok and mp.winid ~= 0 and mp.winid ~= win and api.nvim_win_is_valid(mp.winid) then
        -- Only a real SPLIT under the pointer takes the scroll: a floating window there is
        -- chrome over the text (a hud overlay, an indicator) — scrolling it would silently
        -- swallow every notch (measured: the view froze while notches went into a float).
        if api.nvim_win_get_config(mp.winid).relative == "" then
            api.nvim_win_call(mp.winid, function()
                pcall(vim.cmd, native)
            end)
            return
        end
    end
    local st = state.get(buf)
    if st == nil or st.boxed == nil or next(st.boxed) == nil or config.tables_nav_mode == "raw" then
        vim.cmd(native)
        return
    end
    local v = vim.fn.winsaveview()
    local total = api.nvim_buf_line_count(buf)
    local h = text_height(0)
    local so = api.nvim_get_option_value("scrolloff", { win = 0 })
    local cap = math.max(h - 1 - so, 1)
    local budget = math.max(h - so, 2)
    local view = { topline = v.topline, topfill = v.topfill }
    for _ = 1, count do
        view = delta > 0 and view_step_down(st, buf, view, total, cap) or view_step_up(st, buf, view, cap, budget)
    end
    release_box(st)
    local top_disp
    if view.topfill > 0 then
        local span = render.boxed_span(buf, view.topline - 1)
        top_disp = span ~= nil and math.min(span.last + 2, total) or view.topline
    else
        top_disp = math.min(next_displayed(st, view.topline), total)
    end
    local cur = v.lnum
    if delta > 0 then
        -- The cursor keeps 'scrolloff' displayed lines under the view's top and never rests on
        -- a hidden row.
        local minl = top_disp
        for _ = 1, math.min(so, h - 1) do
            minl = math.min(next_displayed(st, minl + 1), total)
        end
        if cur < minl or render.boxed_span(buf, cur - 1) ~= nil then
            cur = minl
        end
    else
        -- The last displayed line whose rows still fit above the bottom 'scrolloff' margin,
        -- heights taken for real (a wrapped line, an anchor with its whole block).
        local vis_budget = math.max(h - so, 1) - view.topfill
        local l = top_disp
        local lastvis = top_disp
        local acc = 0
        while l <= total do
            local hh = display_cost(st, l)
            if acc + hh > vis_budget then
                break
            end
            acc = acc + hh
            lastvis = l
            l = math.min(next_displayed(st, l + 1), total)
            if l == lastvis then
                break
            end
        end
        if cur > lastvis or render.boxed_span(buf, cur - 1) ~= nil then
            cur = lastvis
        end
    end
    cur = math.max(1, math.min(cur, total))
    vim.fn.winrestview({
        lnum = cur,
        col = cur == v.lnum and v.col or 0,
        coladd = 0,
        curswant = cur == v.lnum and v.curswant or 0,
        leftcol = v.leftcol,
        skipcol = 0,
        topline = view.topline,
        topfill = view.topfill,
    })
end

--- Attach a buffer: resolve its format and grammar, gate on size, build the first outline, own
--- the windows, take the fold keys.
---@param buf integer
---@return nil
function M.attach(buf)
    -- An explicit refusal, honoured before anything else: a buffer that IS this plugin's own UI
    -- (the table editor's grid) carries the document's filetype so treesitter colours it, but must
    -- never be decorated — it would render a box over the very text you are there to edit.
    if vim.b[buf].lvim_render_skip then
        return
    end
    -- A buffer that lives in a FLOAT belongs to whoever opened it (an LSP hover, a peek, a
    -- documentation popup) — and Neovim's own `open_floating_preview` sets `filetype = markdown`
    -- on it, so this pattern fires for every hover unless it is refused here. The window is
    -- already open by the time the filetype is set (measured in the runtime: the window at
    -- `open_floating_preview` step 84, the filetype at 131), so the test is reliable. A buffer
    -- shown in ANY ordinary window is still ours — the same document open in a split and peeked
    -- at renders as it should.
    if not config.floats then
        local wins = vim.fn.win_findbuf(buf)
        if #wins > 0 then
            local only_float = true
            for _, win in ipairs(wins) do
                if (api.nvim_win_get_config(win).relative or "") == "" then
                    only_float = false
                    break
                end
            end
            if only_float then
                return
            end
        end
    end
    if state.get(buf) ~= nil or not api.nvim_buf_is_valid(buf) then
        return
    end
    local ft = vim.bo[buf].filetype
    local format = M.format_for(ft)
    if format == nil then
        return
    end

    -- The grammar comes through lvim-ts when it is around (it resolves `b:lvim_ts_lang` overrides
    -- and can install on demand); the runtime mapping answers otherwise. Inline require: optional
    -- cross-plugin dependency.
    local lang = nil
    local ok_ts, lvim_ts = pcall(require, "lvim-ts")
    if ok_ts and lvim_ts.lang_for_buf ~= nil then
        lang = lvim_ts.lang_for_buf(buf)
    end
    lang = lang or vim.treesitter.language.get_lang(ft) or ft

    ---@type LvimRenderBufState
    local st = {
        enabled = config.enabled,
        inert = nil,
        format = format,
        lang = lang,
        generation = 0,
        timer = nil,
        dirty = nil,
        tables = {},
        table_folds = nil,
        outline = {},
        heading_by_row = {},
        max_level = 0,
        cycle_all = 2,
        baseline = nil,
    }

    local lines = api.nvim_buf_line_count(buf)
    local bytes = api.nvim_buf_get_offset(buf, lines)
    if lines > config.max_lines or (bytes >= 0 and bytes > config.max_file_size) then
        st.inert = ("size gate: %d lines / %d bytes (max_lines = %d, max_file_size = %d)"):format(
            lines,
            bytes,
            config.max_lines,
            config.max_file_size
        )
        vim.notify_once(
            ("lvim-render: buffer %d exceeds the size gate — attached inert (:checkhealth lvim-render)"):format(buf),
            vim.log.levels.INFO
        )
    elseif not pcall(vim.treesitter.get_parser, buf, lang) then
        st.inert = ("no parser for %q"):format(lang)
    end

    state.buffers[buf] = st
    if st.inert ~= nil then
        return
    end

    st.timer = uv.new_timer()
    -- A highlighter attached before setup() amended the query still carries the old one.
    queries.refresh_highlighter(buf, lang)
    fold.rebuild(buf)
    if st.enabled then
        sync_wins(buf, true)
    end

    api.nvim_buf_attach(buf, false, {
        on_bytes = function(_, b, _, start_row, _, _, old_end, _, _, new_end)
            return on_bytes(b, start_row, old_end, new_end)
        end,
        -- The documented reload contract: fed through the same seam as a whole-buffer edit, so
        -- the generation moves and every cache keyed on it regenerates.
        on_reload = function(_, b)
            return on_bytes(b, 0, 0, 0)
        end,
        -- A RELOAD (`:e!`, 'autoread') and an UNLOAD (`:bunload`, 'nohidden' switches) both KILL
        -- this attachment — measured on this build: `:e!` fires on_detach, never on_reload, and
        -- on_bytes is silent afterwards. The plugin state used to survive that: attach() then
        -- early-returned forever (the generation froze, and the screen kept drawing table cells
        -- the buffer no longer contained). Everything is dropped, and a buffer that is still
        -- loaded and still ours re-attaches from scratch — the FileType re-detection cannot be
        -- relied on for that, because it runs BEFORE this scheduled callback and its attach()
        -- finds the stale state. Scheduled: buffer-update callbacks run in a fast context.
        on_detach = function(_, b)
            vim.schedule(function()
                -- The reader's own per-buffer choices are not the text's: they survive the
                -- round trip (a preview holding the source RAW must still hold it raw).
                local prev = state.get(b)
                local was_disabled = prev ~= nil and not prev.enabled
                local was_raw = prev ~= nil and prev.raw == true
                M.detach(b)
                if api.nvim_buf_is_loaded(b) and M.format_for(vim.bo[b].filetype) ~= nil then
                    M.attach(b)
                    if was_disabled then
                        M.set_enabled(b, false)
                    elseif was_raw then
                        M.set_raw(b, true)
                    end
                end
            end)
        end,
    })

    -- j/k PREDICT their landing row and never place the cursor on a row a box hides. THE MEASURED
    -- ROOT FACT (nav mode "raw", no plugin navigation at all): the moment the cursor lands on a
    -- `conceal_lines`-hidden table row, NEOVIM ITSELF scrolls the whole virtual block into view —
    -- topline jumped 3 → 10 on a five-row table sitting at the bottom edge. The old shape ran
    -- `normal! j` FIRST and sorted the position out afterwards, so the cursor VISITED the hidden
    -- row every time and the native scroll had already yanked the screen before any parking could
    -- help. Deciding first is the only order that never triggers it.
    for name, key in pairs(config.tables_nav_keys or {}) do
        if type(key) == "string" and key ~= "" then
            local delta = name == "up" and -1 or 1
            vim.keymap.set("n", key, function()
                local count = vim.v.count1
                local nav_mode = config.tables_nav_mode
                local st = state.get(buf)
                local native = ("normal! %d%s"):format(count, delta < 0 and "k" or "j")
                if nav_mode == "raw" or st == nil then
                    vim.cmd(native)
                    return
                end

                -- THE WIDGET, already walking: the press moves the plugin-owned index, never the
                -- cursor — the box repaints with the new row active and the parked cursor stays on
                -- its displayed line. Stepping DOWN through a block taller than what is left under
                -- the parked row slides the view ONE line per press — exactly what `j` does at the
                -- bottom of a window — never a jump. The pagination's page follows the active row
                -- inside `avail` either way.
                local act = st.box_active
                if nav_mode == "widget" and act ~= nil then
                    local next_index = act.index + delta * count
                    if next_index >= 1 and next_index <= act.rows then
                        act.index = next_index
                        if act.parked ~= act.anchor and delta < 0 then
                            local vv = vim.fn.winsaveview()
                            if vv.topfill > 0 and (act.rows - next_index) + 2 > vv.topfill then
                                local h2 = text_height(0)
                                local so2 = api.nvim_get_option_value("scrolloff", { win = 0 })
                                if vim.fn.winline() < h2 - so2 then
                                    -- THE UP-SLIDE, the mirror of the downward slide's promise:
                                    -- reveal ONE more tail row — the lit row keeps its screen
                                    -- row, the parked cursor drops one. (The frozen-view walk
                                    -- reparked after 1-2 steps whenever the entry fill was
                                    -- small, and the repark turned the page — the recorder's
                                    -- shape 1.)
                                    local stepped = view_step_up(
                                        st,
                                        buf,
                                        { topline = vv.topline, topfill = vv.topfill },
                                        math.max(h2 - 1 - so2, 1),
                                        math.max(h2 - so2, 2)
                                    )
                                    vim.fn.winrestview({ topline = stepped.topline, topfill = stepped.topfill })
                                else
                                    -- No room left to slide: repark ABOVE — and keep the LIT
                                    -- ROW near the top of the paged slice, so the reader's
                                    -- eyes stay where they were (the page-follow's default
                                    -- bottom placement flipped the whole window).
                                    act.parked = act.anchor
                                    local anchor_line = math.max(act.first, 1)
                                    act.page = next_index <= 1 and 2 or (next_index + 2)
                                    -- THE REPARK MOVES THE CURSOR, NOT THE PAGE. A parked cursor
                                    -- stands on a hidden row and is not drawn — it is bookkeeping,
                                    -- and the reader only sees the page and the lit row. Landing
                                    -- the anchor near the TOP edge instead turned the whole window
                                    -- over on a single press: measured in the owner's own recorder,
                                    -- `topline 132 → 164` with the parked row going from screen row
                                    -- 48 to 3. While the anchor is still displayed, restating the
                                    -- CURRENT view with the new cursor changes nothing on screen;
                                    -- only when it has left the viewport is a step owed, and then
                                    -- it costs the margin, not a page.
                                    local tl, tf = vv.topline, vv.topfill
                                    if anchor_line < vim.fn.line("w0") then
                                        tl, tf = anchor_line, 0
                                        for _ = 1, so2 do
                                            tl = prev_displayed(st, buf, math.max(tl - 1, 1))
                                        end
                                    end
                                    vim.fn.winrestview({
                                        lnum = anchor_line,
                                        col = 0,
                                        coladd = 0,
                                        curswant = 0,
                                        leftcol = 0,
                                        skipcol = 0,
                                        topline = tl,
                                        topfill = tf,
                                    })
                                    act.avail = text_height(0) - vim.fn.winline()
                                    sync_box_cursor(buf)
                                    redraw_walk(buf)
                                    return
                                end
                            end
                        end
                        api.nvim_win_set_cursor(0, { act.parked + 1, 0 })
                        local needed = (st.box_lines or {})[act.first] or 1
                        local h = text_height(0)
                        local below = h - vim.fn.winline()
                        -- A slide 'scrolloff' would veto is never asked for: the option pulls the
                        -- topline straight back (measured: the view DRIFTED UP while stepping
                        -- down under scrolloff=8), and the parked row cannot come nearer the top
                        -- edge than the option allows anyway.
                        local so = api.nvim_get_option_value("scrolloff", { win = 0 })
                        -- The slide belongs to the ABOVE-parked walk only: a walk parked BELOW
                        -- its box shows the block through the layout above the parked row, and
                        -- the page follows the lit row INSIDE the block — zero view movement.
                        if delta > 0 and act.parked == act.anchor and needed > below and vim.fn.winline() > so + 1 then
                            -- ONE DISPLAY unit, never `topline + 1` in buffer lines: a raw +1
                            -- landing inside an EARLIER table's concealed run gets normalised
                            -- past the whole run — one press moved the view 15 lines and the
                            -- next seven moved nothing while the slack drained (measured, the
                            -- owner's original screenshot). `view_step_down` steps runs,
                            -- anchors and fill states by exactly one screen row.
                            local view = vim.fn.winsaveview()
                            local stepped = view_step_down(
                                st,
                                buf,
                                { topline = view.topline, topfill = view.topfill },
                                api.nvim_buf_line_count(buf),
                                math.max(h - 1 - so, 1)
                            )
                            view.topline = stepped.topline
                            view.topfill = stepped.topfill
                            vim.fn.winrestview(view)
                            below = h - vim.fn.winline()
                        end
                        if act.parked == act.anchor then
                            -- `avail` is the room under the parked row — ABOVE-parked semantics.
                            -- A below-parked walk keeps its entry value (the full block): the
                            -- step's tiny "room under the cursor" here paginated a 96-line
                            -- block to 3 under a 39-row fill and collapsed the view (measured).
                            act.avail = below
                            redraw_walk(buf)
                        else
                            redraw_walk_keep_view(buf)
                        end
                        return
                    end
                    -- Stepping past either end hands the cursor back to the buffer, on the first
                    -- displayed row beyond the box. Downward that is `exit_box_below` — the box
                    -- grows to full height in the same tick and a tall one needs the view landed
                    -- on its tail. Upward the cursor returns to the anchor, a displayed line
                    -- already on screen, and the block grows BELOW it: nothing scrolls.
                    local first, last = act.first, act.last
                    local below_parked = act.parked ~= act.anchor
                    if delta > 0 then
                        if below_parked then
                            -- The cursor already rests on the row below the table: release and
                            -- continue reading — nothing needs to move.
                            release_box(st)
                            sync_box_cursor(buf)
                            redraw_walk_keep_view(buf)
                            return
                        end
                        -- A table that ENDS THE BUFFER has no displayed row below it to stand
                        -- on — the clamp would park the cursor on a hidden row, and the next
                        -- press would re-enter the walk at row 1: an endless cycle (measured on
                        -- a document whose last line is a table row). The document ends here;
                        -- the press does what `j` on a file's last line does — nothing.
                        if last + 2 > api.nvim_buf_line_count(buf) then
                            return
                        end
                        exit_box_below(buf, st, first, last)
                        return
                    end
                    if below_parked then
                        exit_box_above(buf, st, first, last)
                        return
                    end
                    release_box(st)
                    api.nvim_win_set_cursor(0, { math.max(1, first), 0 })
                    sync_box_cursor(buf)
                    redraw_walk(buf)
                    return
                end

                -- "stop", standing on the stop: the next press leaves it — down crosses the whole
                -- table (its rows are one unit), up is the ordinary motion off the anchor.
                if nav_mode == "stop" and act ~= nil then
                    local stop_below = act.parked ~= act.anchor
                    if delta > 0 then
                        if stop_below then
                            -- The cursor already rests below the table: an ordinary line down.
                            release_box(st)
                            vim.cmd(native)
                            sync_box_cursor(buf)
                            redraw_walk(buf)
                            return
                        end
                        -- A table ending the buffer has nothing below to cross TO: stay on the
                        -- stop (same rule as the widget's past-the-end press).
                        if act.last + 2 > api.nvim_buf_line_count(buf) then
                            return
                        end
                        -- Crossing a table taller than the window shares the widget's exit shape:
                        -- the whole block sits above the landing row, so the view must land on
                        -- its tail rather than be recomputed past it.
                        exit_box_below(buf, st, act.first, act.last)
                        return
                    end
                    if stop_below then
                        -- Crossing upward: the mirror landing — the anchor with the box's head.
                        exit_box_above(buf, st, act.first, act.last)
                        return
                    end
                    release_box(st)
                    vim.cmd(native)
                    sync_box_cursor(buf)
                    redraw_walk(buf)
                    return
                end

                -- Not walking: predict where this press would land, honouring closed folds the
                -- way `j`/`k` do. Only a landing INSIDE a boxed span is intercepted; everything
                -- else is the native motion, executed exactly once.
                local target = api.nvim_win_get_cursor(0)[1]
                for _ = 1, count do
                    if delta > 0 then
                        local fold_end = vim.fn.foldclosedend(target)
                        target = (fold_end ~= -1 and fold_end or target) + 1
                    else
                        target = target - 1
                        local fold_start = vim.fn.foldclosed(target)
                        if fold_start ~= -1 then
                            target = fold_start
                        end
                    end
                end
                target = math.max(1, math.min(target, api.nvim_buf_line_count(buf)))
                local span = render.boxed_span(buf, target - 1)
                if span == nil then
                    -- BELOW A BOX WITH ITS TAIL SHOWING (the state a downward exit lands): the
                    -- view carries 'topfill' tail lines of the block over the concealed run.
                    -- Neovim cannot scroll DOWN over such a run one line at a time — measured in
                    -- --clean: one CTRL-E (or the scroll a plain `j` triggers) from that state
                    -- snaps past the WHOLE run to fill 0, and the box vanishes in one press. The
                    -- fill states are stable and drawable, just not natively steppable downward,
                    -- so stepping them is this navigation's job: the native motion moves the
                    -- cursor, then the view is landed one visual row further — the same promise,
                    -- and the same `winrestview` seam, as the in-walk slide. Restored only while
                    -- the cursor stays inside the slid view; anything else keeps the native
                    -- result (one honest scroll, never a fight).
                    local view = vim.fn.winsaveview()
                    if delta > 0 and view.topfill > 0 then
                        local tspan = render.boxed_span(buf, view.topline - 1)
                        if tspan ~= nil then
                            -- SCREEN rows, never buffer lines: under 'wrap' a long line is
                            -- several rows, and line arithmetic collapsed the slide on the
                            -- first wrapped line below a box (measured — a 337-char line
                            -- entered the count as 1). `nvim_win_text_height` is the honest
                            -- seam: wraps, virtual lines and concealed rows all accounted.
                            -- The step keeps the TARGET's whole line visible with 'scrolloff'
                            -- rows under its LAST screen row, sliding the view by exactly the
                            -- overshoot. Applied as ONE `winrestview`, cursor and view
                            -- together, computed from the still-valid pre-press layout: the
                            -- native motion first would leave the wrapped cursor line not
                            -- fitting, and the very next layout query finalizes Neovim's
                            -- snap — cursor dragged three lines before any restore could run
                            -- (measured). The exit learned this once already; the slide obeys
                            -- the same rule.
                            local h = text_height(0)
                            local so = api.nvim_get_option_value("scrolloff", { win = 0 })
                            local budget = h - so
                            local out = tspan.last + 2
                            local rows = api.nvim_win_text_height(0, { start_row = out - 1, end_row = target - 1 }).all
                            local fill = math.min(view.topfill, budget - rows)
                            local topline = view.topline
                            if fill <= 0 then
                                -- The fill is spent: the slide hands over to the normal no-fill
                                -- view IN THE SAME STEP — the topline walks forward from the
                                -- first displayed row, in screen rows, until the target fits
                                -- the budget. Falling to the native motion here instead snaps
                                -- over the run (the press that exhausts the fill was the same
                                -- one-keypress jump, one screen later).
                                topline = target
                                local acc = line_rows(target)
                                while topline > out do
                                    local p = prev_displayed(st, buf, topline - 1)
                                    local hh = display_cost(st, p)
                                    if acc + hh > budget or p >= topline then
                                        break
                                    end
                                    acc = acc + hh
                                    topline = p
                                end
                                fill = 0
                            end
                            local line = api.nvim_buf_get_lines(buf, target - 1, target, true)[1] or ""
                            local col = math.min(view.col, math.max(#line - 1, 0))
                            vim.fn.winrestview({
                                lnum = target,
                                col = col,
                                coladd = 0,
                                curswant = col,
                                leftcol = view.leftcol,
                                skipcol = 0,
                                topline = topline,
                                topfill = fill,
                            })
                            return
                        end
                    end
                    -- The UP mirror: a native `k` that must scroll misbehaves anywhere NEAR
                    -- box state — over a hidden run it snaps the whole run (topline 74 → 61);
                    -- from a fill state it collapses ((62,1) → (60,0), 14 rows); and even TWO
                    -- displayed lines above a run it overshoots, revealing the whole block
                    -- ((15,0) → (7,9), the recorder's shape 2). No reliable adjacency
                    -- heuristic exists, and the display-unit step is byte-identical to the
                    -- native scroll over plain prose — so in an owned buffer every scrolling
                    -- `k` steps through the model, cursor and view in one restore.
                    if delta < 0 then
                        -- EVERY upward press states cursor AND view, including the presses that
                        -- need no scroll at all. Handing those to the native motion was the last
                        -- jump left: from a displayed row two lines under a block, `k` moved the
                        -- view 22 rows (measured: topline 198 → 178, fill 0 → 21) although the
                        -- target was already on screen with 23 rows above it. Stating the view we
                        -- already have is not a correction after the fact — it is the same
                        -- contract the downward step keeps, applied unconditionally so no press
                        -- can fall through to a redraw that overshoots near a box.
                        local wl = vim.fn.winline()
                        local so = api.nvim_get_option_value("scrolloff", { win = 0 })
                        local h = text_height(0)
                        local cap = math.max(h - 1 - so, 1)
                        local vbudget = math.max(h - so, 2)
                        -- THE MOTION'S REAL COST, in screen rows: each DISPLAYED line the cursor
                        -- rises past costs its own height — a wrapped line more than one row, an
                        -- anchor its whole block — and the hidden rows of a box cost nothing,
                        -- being counted once at their anchor. Counting buffer lines instead put
                        -- the deficit out by a block's height, which is what let the native
                        -- motion take the press in the first place.
                        local cost, walk_line = 0, target
                        while walk_line < view.lnum do
                            cost = cost + display_cost(st, walk_line)
                            local nxt = next_displayed(st, walk_line + 1)
                            walk_line = nxt > walk_line and nxt or walk_line + 1
                        end
                        -- How far the view must climb for the target to keep its 'scrolloff'
                        -- margin. Zero (or less) means the target is already comfortably on
                        -- screen and the view is restored EXACTLY as it stands.
                        local deficit = (so + 1) - (wl - cost)
                        local v2 = { topline = view.topline, topfill = view.topfill }
                        for _ = 1, math.max(0, deficit) do
                            v2 = view_step_up(st, buf, v2, cap, vbudget)
                        end
                        local tline = api.nvim_buf_get_lines(buf, target - 1, target, true)[1] or ""
                        local tcol = math.min(view.col, math.max(#tline - 1, 0))
                        vim.fn.winrestview({
                            lnum = target,
                            col = tcol,
                            coladd = 0,
                            curswant = tcol,
                            leftcol = view.leftcol,
                            skipcol = 0,
                            topline = v2.topline,
                            topfill = v2.topfill,
                        })
                        return
                    end
                    vim.cmd(native)
                    return
                end

                if nav_mode == "widget" then
                    -- Entering: park on the NEAR displayed row — the anchor when coming from
                    -- above, the row below the table when coming from BELOW (parking on the
                    -- far-away anchor scrolled it to the top of the window: one `k` yanked the
                    -- view a windowful — measured at the owner's geometry). THE VIEW DOES NOT
                    -- JUMP: the box only needs its ACTIVE row visible and the pagination's page
                    -- follows that row inside `avail`.
                    local rows = (st.box_rows or {})[span.first] or 1
                    local total = api.nvim_buf_line_count(buf)
                    -- The NEAREST edge to where the cursor actually stands — not the press
                    -- direction: a `:N` jump dragged the cursor to the box's TOP and the next
                    -- `k` parked it BELOW the whole table, +22 rows of view (the recorder).
                    local cur_row = api.nvim_win_get_cursor(0)[1] - 1
                    local anchor_row = span.first - 1
                    local out_row = math.min(span.last + 1, total - 1)
                    local parked = math.abs(cur_row - anchor_row) <= math.abs(cur_row - out_row) and anchor_row
                        or out_row
                    st.box_active = {
                        first = span.first,
                        last = span.last,
                        anchor = span.first - 1,
                        parked = parked,
                        rows = rows,
                        index = delta > 0 and 1 or rows,
                        walk = true,
                    }
                    api.nvim_win_set_cursor(0, { math.max(1, parked + 1), 0 })
                    local needed = (st.box_lines or {})[span.first] or 1
                    if parked ~= anchor_row then
                        -- Parked below: the block shows through the layout ABOVE the parked
                        -- row and is NEVER paginated — replacing a full block with a paged one
                        -- while the view's fill hangs on it collapses the fill (measured: a
                        -- 96-line block paged to 39 threw the view to the anchor). The view is
                        -- not touched at all.
                        st.box_active.avail = needed
                        sync_box_cursor(buf)
                        redraw_walk_keep_view(buf)
                        return
                    end
                    local below = text_height(0) - vim.fn.winline()
                    local want = math.min(needed, ENTRY_ROOM)
                    -- Clamped by 'scrolloff' for the same reason as the step slide: a topline
                    -- the option will pull back is a request for a flicker, nothing more.
                    local so = api.nvim_get_option_value("scrolloff", { win = 0 })
                    local shift = math.min(want - below, vim.fn.winline() - so - 1)
                    if shift > 0 then
                        -- DISPLAY units, never `topline + shift` in buffer lines: a raw advance
                        -- landing inside an earlier table's concealed run gets normalised past
                        -- the whole run (the in-walk slide's measured 15-line lump).
                        local view = vim.fn.winsaveview()
                        local stepped = { topline = view.topline, topfill = view.topfill }
                        local total = api.nvim_buf_line_count(buf)
                        local h = text_height(0)
                        for _ = 1, shift do
                            stepped = view_step_down(st, buf, stepped, total, math.max(h - 1 - so, 1))
                        end
                        view.topline = stepped.topline
                        view.topfill = stepped.topfill
                        vim.fn.winrestview(view)
                        below = h - vim.fn.winline()
                    end
                    st.box_active.avail = below
                    -- Entering does not always MOVE the cursor: press `j` on the row the widget
                    -- parks on and it stays put, so CursorMoved never fires and the hardware
                    -- cursor would blink on the anchor. Asked for directly.
                    sync_box_cursor(buf)
                    redraw_walk(buf)
                    return
                end

                -- "stop": the table is ONE stop the cursor RESTS ON — on the displayed row the
                -- box hangs from, since a hidden row triggers the native block scroll (the root
                -- fact above). The stop is recorded as a non-walking `box_active`, which is what
                -- keeps `i`-opens-the-editor and the cursor hiding working there; any cursor
                -- move away releases it. It never jumps over: a table you cannot put the cursor
                -- on is a table you cannot open.
                local stop_total = api.nvim_buf_line_count(buf)
                local stop_cur = api.nvim_win_get_cursor(0)[1] - 1
                local stop_out = math.min(span.last + 1, stop_total - 1)
                local stop_parked = math.abs(stop_cur - (span.first - 1)) <= math.abs(stop_cur - stop_out)
                        and (span.first - 1)
                    or stop_out
                st.box_active = {
                    first = span.first,
                    last = span.last,
                    anchor = span.first - 1,
                    parked = stop_parked,
                    rows = (st.box_rows or {})[span.first] or 1,
                    index = 1,
                }
                api.nvim_win_set_cursor(0, { math.max(1, stop_parked + 1), 0 })
                sync_box_cursor(buf)
            end, {
                buffer = buf,
                desc = "lvim-render: move a line; a boxed table is entered without touching its hidden rows",
            })
        end
    end

    if config.tables_nav_wheel then
        -- The wheel joins the same navigation contract as j/k: stepped through the plugin's
        -- view model over boxed tables (a native notch snaps past a whole conceal run —
        -- measured), native everywhere else and for windows under the pointer that are not
        -- the current one.
        vim.keymap.set("n", "<ScrollWheelDown>", function()
            wheel_scroll(buf, 1)
        end, { buffer = buf, desc = "lvim-render: wheel down, one view row at a time over boxed tables" })
        vim.keymap.set("n", "<ScrollWheelUp>", function()
            wheel_scroll(buf, -1)
        end, { buffer = buf, desc = "lvim-render: wheel up, one view row at a time over boxed tables" })
    end

    if config.fold.enabled and config.fold.headings then
        if config.fold.keys.cycle then
            vim.keymap.set("n", config.fold.keys.cycle, fold.cycle, {
                buffer = buf,
                desc = "lvim-render: cycle the heading under the cursor",
            })
        end
        if config.fold.keys.cycle_all then
            vim.keymap.set("n", config.fold.keys.cycle_all, fold.cycle_all, {
                buffer = buf,
                desc = "lvim-render: cycle the whole document",
            })
        end
    end
end

--- Detach a buffer entirely (it is being deleted, or its filetype no longer matches).
---@param buf integer
---@return nil
function M.detach(buf)
    local st = state.get(buf)
    if st == nil then
        return
    end
    if st.timer ~= nil then
        st.timer:stop()
        st.timer:close()
        st.timer = nil
    end
    st.generation = st.generation + 1
    fold.errors[buf] = nil
    for win, saved in pairs(state.wins) do
        if saved.buf == buf then
            restore_win(win)
        end
    end
    if api.nvim_buf_is_valid(buf) then
        for _, key in ipairs({ config.fold.keys.cycle, config.fold.keys.cycle_all }) do
            if key then
                pcall(vim.keymap.del, "n", key, { buffer = buf })
            end
        end
        for _, key in pairs(config.tables_nav_keys or {}) do
            if type(key) == "string" and key ~= "" then
                pcall(vim.keymap.del, "n", key, { buffer = buf })
            end
        end
        for _, key in ipairs({ "<ScrollWheelDown>", "<ScrollWheelUp>" }) do
            pcall(vim.keymap.del, "n", key, { buffer = buf })
        end
        if api.nvim_buf_is_loaded(buf) then
            api.nvim_buf_clear_namespace(buf, render.ns_inline, 0, -1)
            redraw(buf)
        end
    end
    state.drop(buf)
end

--- Turn one buffer's rendering on or off, restoring or re-taking its windows' options.
---@param buf integer
---@param on boolean
---@return nil
function M.set_enabled(buf, on)
    local st = state.get(buf)
    if st == nil or st.inert ~= nil or st.enabled == on then
        return
    end
    st.enabled = on
    sync_wins(buf, on)
    if not on then
        -- The ephemeral lane vanishes on the next redraw by itself; the persistent inline lane
        -- must be taken down explicitly.
        api.nvim_buf_clear_namespace(buf, render.ns_inline, 0, -1)
    end
    redraw(buf)
end

--- Put a buffer into RAW PREVIEW mode, or take it out. Nothing is painted while it lasts and the
--- window shows the file's own characters — but the plugin keeps OWNING the window options, so
--- the state survives a buffer re-entry and leaving it restores rendering rather than a half
--- state. That is what distinguishes this from `set_enabled(buf, false)`, which hands the options
--- back to whoever had them.
---@param buf integer
---@param on boolean
---@return nil
function M.set_raw(buf, on)
    local st = state.get(buf)
    if st == nil or st.inert ~= nil or (st.raw == true) == on then
        return
    end
    st.raw = on or nil
    sync_wins(buf, true)
    if on then
        -- The ephemeral lane vanishes on the next redraw by itself; the persistent inline lane
        -- must be taken down explicitly.
        api.nvim_buf_clear_namespace(buf, render.ns_inline, 0, -1)
    end
    redraw(buf)
end

--- Should the provider paint this window/buffer pair at all? Public so a fixture can assert the
--- same verdict the paint path uses.
---@param buf integer
---@return boolean
function M.eligible(buf)
    if buf == nil or buf == 0 then
        buf = api.nvim_get_current_buf()
    end
    local st = state.get(buf)
    return st ~= nil and st.enabled and st.inert == nil and not st.raw
end

--- Does the plugin OWN this buffer's window options? A different question from `eligible`, and
--- they diverge in exactly one place: a RAW-preview buffer paints nothing yet must keep its
--- 'conceallevel' at 0, so ownership outlives painting. Conflating the two left the raw side
--- silently re-concealing at the next buffer re-entry.
---@param buf integer
---@return boolean
function M.owns(buf)
    local st = state.get(buf)
    return st ~= nil and (st.enabled or st.raw == true) and st.inert == nil
end

--- A window now shows an attached buffer (BufWinEnter): own its options; or stopped showing one.
---@param win integer
---@return nil
function M.on_win_enter(win)
    if not api.nvim_win_is_valid(win) then
        return
    end
    local buf = api.nvim_win_get_buf(win)
    if M.owns(buf) then
        apply_win(win, buf)
    elseif state.wins[win] ~= nil and state.wins[win].buf ~= buf then
        restore_win(win)
    end
end

--- A window closed: its saved options die with it; forget them.
---@param win integer
---@return nil
function M.on_win_closed(win)
    state.wins[win] = nil
    state.reveal[win] = nil
end

---@type table<integer, true>  windows with a post-scroll repaint already scheduled (see
--- M.on_win_scrolled) — a wheel burst fires WinScrolled per notch and one flush is enough
local scroll_pending = {}

--- A window scrolled (WinScrolled — wheel, CTRL-E/D, drag). MITIGATION FOR TWO UPSTREAM REDRAW
--- DEFECTS around `conceal_lines` runs carrying `virt_lines` blocks, both measured:
---
--- (A) The incremental scroll TEARS the grid — a row drawn twice, persisting at rest
---     (reproduced in `nvim --clean` with manually-set marks and wheel bursts, no plugin
---     code). A full `valid = false` redraw of the same state draws it correctly, so one
---     honest FLUSHED repaint after the scroll settles bounds a tear to a single frame. The
---     flush matters: a `flush = false` request after the last notch is never honoured —
---     nothing else triggers a cycle at rest (measured).
--- (B) A topline parked INSIDE a concealed run without fill from its box MIS-DRAWS stably —
---     the next anchor row duplicated, surviving every repaint (measured live: topline on the
---     run's first row with topfill=0 drew the cursor row twice; normalising the topline to
---     the first displayed line after the run — the SAME visible content — drew it correctly).
---     A topline on the run's first row WITH fill is the legal tail state (the exit/slide
---     land there) and is left alone.
---
--- Scheduled (WinScrolled fires inside the scroll's own processing), deduped per window, and
--- scoped tightly: only a window whose viewport touches boxed-table state has the fragile
--- layout. Remove when the upstream redraw is fixed.
---@param win integer
---@return nil
function M.on_win_scrolled(win)
    if scroll_pending[win] or not api.nvim_win_is_valid(win) then
        return
    end
    local buf = api.nvim_win_get_buf(win)
    if not M.eligible(buf) then
        return
    end
    local st = state.get(buf)
    if st == nil or st.boxed == nil then
        return
    end
    local top = vim.fn.line("w0", win) - 1
    local bot = vim.fn.line("w$", win) - 1
    for first, last in pairs(st.boxed) do
        -- The anchor row above the span carries the block, so the fragile region starts one
        -- row early; a box hanging into the viewport from above still counts (`first - 1`).
        if first - 1 <= bot and last >= top then
            scroll_pending[win] = true
            vim.schedule(function()
                scroll_pending[win] = nil
                if not api.nvim_win_is_valid(win) then
                    return
                end
                api.nvim_win_call(win, function()
                    local v = vim.fn.winsaveview()
                    local row = v.topline - 1
                    for f, l in pairs(st.boxed or {}) do
                        if row >= f and row <= l and not (row == f and v.topfill > 0) then
                            vim.fn.winrestview({ topline = l + 2, topfill = 0 })
                            break
                        end
                    end
                end)
                pcall(api.nvim__redraw, { win = win, valid = false, flush = true })
            end)
            return
        end
    end
end

--- The cursor moved: redraw only the lines whose reveal membership changed — the span that WAS
--- raw and the line that now is. O(1) per move, no re-parse, no mark churn.
---@return nil
function M.on_cursor_moved()
    local win = api.nvim_get_current_win()
    local buf = api.nvim_win_get_buf(win)
    -- The widget owns the cursor's position while it is walking a box; a move that lands ANYWHERE
    -- else — a search, a `:N`, a mouse click, a wheel notch DRAGGING the parked cursor — ends the
    -- walk. The old exception (a cursor inside the span kept the walk) left a lit index nobody
    -- was on: one wheel notch dragged the parked cursor onto the first hidden row and the walk
    -- stayed lit while the native block scroll yanked the view 17 lines (measured — the owner's
    -- "one j" screenshot: cursor on 62, 7th row lit, box mid-window).
    local st = state.get(buf)
    if st ~= nil and st.box_active ~= nil then
        local row = api.nvim_win_get_cursor(win)[1] - 1
        if row ~= st.box_active.parked then
            release_box(st)
            redraw_walk(buf)
        end
    end
    sync_box_cursor(buf)
    if not M.eligible(buf) then
        return
    end
    local cur = api.nvim_win_get_cursor(win)[1] - 1
    local old = state.reveal[win]
    if old == nil and not render.mode_reveals(api.nvim_get_mode().mode) then
        -- Nothing revealed and this mode reveals nothing: an ordinary cursor move in normal
        -- mode costs no redraw at all.
        return
    end
    if old ~= nil and cur >= old.first and cur <= old.last then
        return
    end
    if old ~= nil then
        pcall(api.nvim__redraw, {
            win = win,
            range = { math.max(old.first, 0), old.last + 1 },
            valid = true,
            flush = false,
        })
    end
    -- Padded by the walk's slack: the fresh span may reveal a multi-row element whose extent
    -- is only known once the walk runs, and the walk only runs for redrawn rows.
    local n = config.reveal.lines + render.SLACK
    pcall(api.nvim__redraw, {
        win = win,
        range = { math.max(cur - n, 0), cur + n + 1 },
        valid = true,
        flush = false,
    })
end

--- The mode changed: repaint the current window when the change flips "does this mode render"
--- OR "does this mode reveal" — entering insert reveals the element under the cursor, leaving
--- it re-renders (the conceal side of the same rule is native, via 'concealcursor').
---@param from string
---@param to string
---@return nil
function M.on_mode_changed(from, to)
    local buf = api.nvim_get_current_buf()
    if not M.eligible(buf) then
        return
    end

    -- ENTERING INSERT INSIDE A BOXED TABLE OPENS THE EDITOR. Not a flourish: 'concealcursor' is
    -- "nvc", so Neovim itself un-conceals the CURSOR'S LINE in insert — the one row a box hides
    -- would surface underneath it, editable and detached from the table it belongs to. There is
    -- nothing to type into in place (the rows are hidden by design), and the editor is where the
    -- cells change, so `i` goes there instead of leaving a stray line on screen.
    if config.tables_insert_opens_editor and to:sub(1, 1) == "i" and from:sub(1, 1) ~= "i" then
        local st = state.get(buf)
        if st ~= nil and (st.box_active ~= nil or st.boxed ~= nil) then
            -- THE DECISION WAITS FOR THE SCHEDULE, where the command that started insert has
            -- finished moving the cursor. `o` on a table's LAST row begins insert on a NEW row
            -- BELOW the table — deciding from the pre-`o` row hijacked exactly that append,
            -- stopped insert, and let the rest of the typed keys run as normal-mode commands
            -- over the document (measured: "Middle" became "Moddle"). Only an insert that is
            -- still in insert AND still stands on a row the box hides is taken to the editor.
            vim.schedule(function()
                if api.nvim_get_current_buf() ~= buf or api.nvim_get_mode().mode:sub(1, 1) ~= "i" then
                    return
                end
                local row = api.nvim_win_get_cursor(0)[1] - 1
                -- While the widget is walking a table the cursor sits on the row ABOVE it, so
                -- that row counts as being "in" the table — it is where `i` is pressed.
                if st.box_active ~= nil and row == st.box_active.parked then
                    local first = st.box_active.first
                    vim.cmd("stopinsert")
                    -- The walk ends here: the editor is the cursor's next home.
                    release_box(st)
                    api.nvim_win_set_cursor(0, { first + 1, 0 })
                    require("lvim-render.table_editor").open(buf)
                    return
                end
                for first, last in pairs(st.boxed or {}) do
                    if row >= first and row <= last then
                        vim.cmd("stopinsert")
                        require("lvim-render.table_editor").open(buf)
                        return
                    end
                end
            end)
            -- No early return: when the schedule decides this insert is an ordinary one (an
            -- append below the table), the reveal repaint below must still have happened.
        end
    end
    if render.mode_allowed(from) ~= render.mode_allowed(to) then
        redraw(buf)
        return
    end
    if render.mode_reveals(from) ~= render.mode_reveals(to) then
        -- Only the reveal span (and the line the cursor is on) changes, not the whole buffer.
        local win = api.nvim_get_current_win()
        local old = state.reveal[win]
        if old ~= nil then
            pcall(api.nvim__redraw, {
                win = win,
                range = { math.max(old.first, 0), old.last + 1 },
                valid = true,
                flush = false,
            })
        end
        local cur = api.nvim_win_get_cursor(win)[1] - 1
        local n = config.reveal.lines + render.SLACK
        pcall(api.nvim__redraw, {
            win = win,
            range = { math.max(cur - n, 0), cur + n + 1 },
            valid = true,
            flush = false,
        })
    end
end

--- One inline op's identity, for the reconcile: same position, same text, same groups → same
--- mark. The column is part of the key because a row may carry SEVERAL inline marks (a heading
--- icon and a link icon; two links) that must be told apart.
---@param row integer
---@param col integer
---@param opts vim.api.keyset.set_extmark
---@return string
local function inline_key(row, col, opts)
    local parts = { tostring(row), tostring(col) }
    for _, chunk in ipairs(opts.virt_text or {}) do
        parts[#parts + 1] = chunk[1] .. "\1" .. tostring(chunk[2])
    end
    for _, vline in ipairs(opts.virt_lines or {}) do
        for _, chunk in ipairs(vline) do
            parts[#parts + 1] = chunk[1] .. "\1" .. tostring(chunk[2])
        end
        parts[#parts + 1] = opts.virt_lines_above and "A" or "B"
    end
    if opts.conceal_lines ~= nil then
        parts[#parts + 1] = "C" .. opts.conceal_lines
    end
    return table.concat(parts, "\2")
end

--- Bring the persistent inline marks of the visible rows in line with what the walk wants there.
---
--- Inline virt_text cannot be ephemeral (it right-shifts text, which the redraw must know before
--- drawing — Neovim's own inlay hints are persistent for the same reason), so this lane follows
--- the inlay-hint shape instead: real marks, created lazily from on_win for the rows on screen,
--- compared against what is ALREADY in the buffer — the marks themselves are the state, so an
--- edit that shifts rows can never desynchronise a shadow copy. An unchanged mark costs one
--- table lookup; nothing is cleared wholesale.
---@param buf integer
---@param top integer  0-based first visible row
---@param bot integer  0-based last visible row
---@param wanted LvimRenderOp[]  the inline ops the walk produced for those rows
---@param dry boolean|nil  true = only ANSWER whether anything would change, write nothing —
---   the decoration provider's mode, since mark writes are illegal mid-redraw (see redraw_walk)
---@return boolean changed  whether the lane differed (dry) / was changed (wet)
local function reconcile_inline(buf, top, bot, wanted, dry)
    local have = api.nvim_buf_get_extmarks(
        buf,
        render.ns_inline,
        { top, 0 },
        { bot, -1 },
        { details = true, overlap = false }
    )
    local changed = false
    ---@type table<string, true>  keys the buffer already carries
    local present = {}
    for _, mark in ipairs(have) do
        local key = inline_key(mark[2], mark[3], mark[4])
        if present[key] then
            -- A duplicate can only come from an earlier bug; one of them goes.
            changed = true
            if not dry then
                api.nvim_buf_del_extmark(buf, render.ns_inline, mark[1])
            end
        else
            present[key] = mark[1]
        end
    end
    ---@type table<string, true>
    local needed = {}
    for _, o in ipairs(wanted) do
        if o.row >= top and o.row <= bot then
            needed[inline_key(o.row, o.col, o.opts)] = true
        end
    end
    for key, id in pairs(present) do
        if needed[key] == nil then
            changed = true
            if not dry then
                api.nvim_buf_del_extmark(buf, render.ns_inline, id --[[@as integer]])
            end
        end
    end
    for _, o in ipairs(wanted) do
        if o.row >= top and o.row <= bot then
            local key = inline_key(o.row, o.col, o.opts)
            if present[key] == nil then
                changed = true
                if not dry then
                    pcall(api.nvim_buf_set_extmark, buf, render.ns_inline, o.row, o.col, o.opts)
                end
            end
        end
    end
    return changed
end

--- The row span the persistent lane must reconcile: the drawn rows, widened by whatever the walk
--- says it owns beyond them. Public so both entry points widen it identically — one of them
--- forgetting to is exactly the asymmetry that leaves a mark nobody can remove.
---@param top integer
---@param bot integer
---@param extend { first: integer, last: integer }|nil
---@return integer top
---@return integer bot
function M.reconcile_span(top, bot, extend)
    if extend == nil then
        return top, bot
    end
    return math.min(top, extend.first), math.max(bot, extend.last)
end

--- Bring the persistent inline lane current for a window's rows WITHOUT a redraw — the public
--- seam of the reconcile, so "are the inline marks what the walk wants" is a question a fixture
--- (or any caller) can ask headless, where the provider never fires.
---@param win integer
---@param buf integer
---@param top integer  0-based first row
---@param bot integer  0-based last row
---@return integer wanted  how many inline ops the walk produced for those rows
function M.sync_inline(win, buf, top, bot)
    local ops, _, extend = render.collect(win, buf, top, bot)
    top, bot = M.reconcile_span(top, bot, extend)
    ---@type LvimRenderOp[]
    local inline = {}
    for i = 1, #ops do
        if
            ops[i].opts.virt_text_pos == "inline"
            or ops[i].opts.virt_lines ~= nil
            or ops[i].opts.conceal_lines ~= nil
        then
            inline[#inline + 1] = ops[i]
        end
    end
    reconcile_inline(buf, top, math.min(bot, api.nvim_buf_line_count(buf) - 1), inline)
    return #inline
end

--- Bring the persistent lane current for the CURRENT window's visible rows — the out-of-redraw
--- write seam every repaint request goes through (see redraw_walk). A buffer not on screen has
--- nothing to sync; its next paint's dry-check schedules one when it appears.
---@param buf integer
---@return nil
function M.sync_view(buf)
    local win = api.nvim_get_current_win()
    if api.nvim_win_get_buf(win) ~= buf then
        win = vim.fn.win_findbuf(buf)[1]
        if win == nil then
            return
        end
    end
    local top = vim.fn.line("w0", win) - 1
    local bot = vim.fn.line("w$", win) - 1 + render.SLACK
    M.sync_inline(win, buf, top, bot)
end

--- Wire the one decoration provider. Called once, from setup().
---@return nil
function M.start()
    api.nvim_set_decoration_provider(render.ns, {
        on_win = function(_, win, buf, top, bot)
            if not M.eligible(buf) then
                return false
            end
            local started = uv.hrtime()
            local ops, reveal, extend = render.collect(win, buf, top, bot)
            -- The pass may own persistent marks OUTSIDE the drawn rows — a boxed table crossing
            -- the viewport edge hangs its block above and hides its rows below. Reconciling only
            -- what is drawn would leave half of them uncreatable, and the other half undeletable.
            top, bot = M.reconcile_span(top, bot, extend)
            ---@type LvimRenderOp[]
            local inline = {}
            for i = 1, #ops do
                local o = ops[i]
                -- `conceal_lines` joins the persistent lane for the same reason inline text and
                -- virtual lines do: as an EPHEMERAL mark it draws nothing at all (measured — the
                -- rows it should have hidden stayed on screen under a wrapped table box).
                if o.opts.virt_text_pos == "inline" or o.opts.virt_lines ~= nil or o.opts.conceal_lines ~= nil then
                    inline[#inline + 1] = o
                else
                    ---@type table  widened: `ephemeral` is provider-only, so the keyset omits it
                    local opts = o.opts
                    opts.ephemeral = true
                    -- The buffer can shrink between the parse and this emit; a mark past the end
                    -- is dropped, never an error mid-redraw.
                    pcall(api.nvim_buf_set_extmark, buf, render.ns, o.row, o.col, o.opts)
                end
            end
            -- THE PROVIDER NEVER WRITES THE PERSISTENT LANE. A `virt_lines`/`conceal_lines`
            -- write from inside a redraw changes line heights while the frame is being drawn,
            -- and the scroll-shift optimisation then multiplies the torn rows on every wheel
            -- notch (measured — the doubled/multiplying anchor rows). The pass only ASKS
            -- whether the lane differs (a box freshly scrolled into view, an active-row
            -- recolor under a dragged cursor) and defers the writes plus an honest repaint to
            -- after this frame. Only the current window drives the schedule: a non-current
            -- window's wants differ by design (no active row there) and would ping-pong the
            -- buffer-global marks — the documented multi-window residual.
            local st = state.get(buf)
            if
                st ~= nil
                and reconcile_inline(buf, top, math.min(bot, api.nvim_buf_line_count(buf) - 1), inline, true)
                and win == api.nvim_get_current_win()
                and not st.inline_pending
            then
                st.inline_pending = true
                vim.schedule(function()
                    st.inline_pending = nil
                    if api.nvim_buf_is_valid(buf) and M.eligible(buf) then
                        redraw_walk(buf)
                    end
                end)
            end
            state.reveal[win] = reveal
            M.stats.windows = M.stats.windows + 1
            M.stats.ops = M.stats.ops + #ops
            M.stats.ns = M.stats.ns + (uv.hrtime() - started)
            return false
        end,
    })
end

return M
