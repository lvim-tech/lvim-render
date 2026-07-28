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
M.formats = { "markdown", "typst", "org" }

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
    fold.rebuild(buf)
    if dirty ~= nil then
        -- A heading edit changes the fold level of every line down to the next heading, so the
        -- honest refresh range is "from the first touched row to the end".
        fold.refresh(buf, dirty.first, api.nvim_buf_line_count(buf) - 1)
    end
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
    })

    -- j/k STEP OVER a separator row a box is hiding. Inside the box that row draws nothing of its
    -- own — the junction line is the box's, not the buffer's — so stopping on it is a stop for
    -- nothing. A row whose cells WRAPPED needs no such help: `j` already moves one BUFFER line, and
    -- one buffer line is one table row however many box lines it takes.
    for name, key in pairs(config.tables_nav_keys or {}) do
        if type(key) == "string" and key ~= "" then
            local delta = name == "up" and -1 or 1
            vim.keymap.set("n", key, function()
                local count = vim.v.count1
                vim.cmd(("normal! %d%s"):format(count, delta < 0 and "k" or "j"))
                -- One step further, and only one: two separators never touch.
                local row = api.nvim_win_get_cursor(0)[1] - 1
                if render.is_hidden_separator(buf, row) then
                    pcall(vim.cmd, ("normal! %s"):format(delta < 0 and "k" or "j"))
                    row = api.nvim_win_get_cursor(0)[1] - 1
                end
                -- THE VIEW HAS TO BE LED THROUGH THE BOX. A boxed table's rows are hidden, so they
                -- have no screen height of their own and Neovim has nothing to scroll TO: walking
                -- up into a table whose bottom sits at the top of the window simply stopped, the
                -- cursor moving in a buffer that would not follow (reported). The box's lines
                -- belong to the row ABOVE the table, so the view is nudged one screen line per
                -- keypress while the cursor is inside and that block is not yet fully shown —
                -- which tracks, since one source row is one or more box lines.
                local span = render.boxed_span(buf, row)
                if span ~= nil then
                    if delta < 0 and vim.fn.line("w0") > span.first then
                        pcall(vim.cmd, "normal! \25") -- CTRL-Y
                    elseif delta > 0 and vim.fn.line("w$") < span.last + 1 then
                        pcall(vim.cmd, "normal! \5") -- CTRL-E
                    end
                end
            end, {
                buffer = buf,
                desc = "lvim-render: move a line, stepping over a table separator a box hides",
            })
        end
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
        api.nvim_buf_clear_namespace(buf, render.ns_inline, 0, -1)
        redraw(buf)
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

--- The cursor moved: redraw only the lines whose reveal membership changed — the span that WAS
--- raw and the line that now is. O(1) per move, no re-parse, no mark churn.
---@return nil
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
    end
    local ok, cursor = pcall(require, "lvim-utils.cursor")
    if ok and type(cursor.mark_hide_buffer) == "function" then
        cursor.mark_hide_buffer(buf, inside or nil)
    end
end

function M.on_cursor_moved()
    local win = api.nvim_get_current_win()
    local buf = api.nvim_win_get_buf(win)
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
        local row = api.nvim_win_get_cursor(0)[1] - 1
        for first, last in pairs(st ~= nil and st.boxed or {}) do
            if row >= first and row <= last then
                vim.schedule(function()
                    vim.cmd("stopinsert")
                    require("lvim-render.table_editor").open(buf)
                end)
                return
            end
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
---@return nil
local function reconcile_inline(buf, top, bot, wanted)
    local have = api.nvim_buf_get_extmarks(
        buf,
        render.ns_inline,
        { top, 0 },
        { bot, -1 },
        { details = true, overlap = false }
    )
    ---@type table<string, true>  keys the buffer already carries
    local present = {}
    for _, mark in ipairs(have) do
        local key = inline_key(mark[2], mark[3], mark[4])
        if present[key] then
            -- A duplicate can only come from an earlier bug; one of them goes.
            api.nvim_buf_del_extmark(buf, render.ns_inline, mark[1])
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
            api.nvim_buf_del_extmark(buf, render.ns_inline, id --[[@as integer]])
        end
    end
    for _, o in ipairs(wanted) do
        if o.row >= top and o.row <= bot then
            local key = inline_key(o.row, o.col, o.opts)
            if present[key] == nil then
                pcall(api.nvim_buf_set_extmark, buf, render.ns_inline, o.row, o.col, o.opts)
            end
        end
    end
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
            reconcile_inline(buf, top, math.min(bot, api.nvim_buf_line_count(buf) - 1), inline)
            state.reveal[win] = reveal
            M.stats.windows = M.stats.windows + 1
            M.stats.ops = M.stats.ops + #ops
            M.stats.ns = M.stats.ns + (uv.hrtime() - started)
            return false
        end,
    })
end

return M
