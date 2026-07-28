-- lvim-render.split: the side-by-side preview — you edit the file on one side and watch it
-- rendered on the other.
--
-- WHY A SECOND BUFFER, when the plan asked for one buffer in two windows. Because Neovim cannot
-- draw one buffer two ways, and this was measured rather than assumed:
--
--   * EPHEMERAL decorations already differ per window — `render.collect` skips the reveal for any
--     window that is not the current one, and a probe confirmed a conceal emitted only for window A
--     leaves window B showing the raw text. That half works today.
--   * The PERSISTENT lane cannot. Inline `virt_text` and `virt_lines` draw NOTHING when ephemeral
--     (invariant 2), so every icon, code chip and table border is a real buffer extmark — and a
--     buffer extmark is visible in every window showing that buffer. There is no window scope for
--     them: `nvim_win_add_ns` does not exist in 0.12.3 OR in 0.13.0-dev-1061 (both binaries probed
--     on this machine).
--
-- So a same-buffer splitview would put the icons on top of the raw text on the editing side — the
-- half-rendered state this plugin treats as a defect everywhere else. A separate buffer makes the
-- two views independent by construction, which is also where the reference implementation lands:
-- its documented command set includes a `splitRedraw` that "updates splitview contents", and
-- contents that need updating are contents that were copied.
--
-- THE MIRROR IS A PROJECTION, NEVER A SOURCE. It is unlisted, unmodifiable and unwritable; it is
-- overwritten wholesale from the source and never read back. That asymmetry is the whole safety
-- argument: no edit can be lost in it, because no edit can happen in it.
--
---@module "lvim-render.split"

local config = require("lvim-render.config")
local engine = require("lvim-render.engine")
local state = require("lvim-render.state")

local api = vim.api

local M = {}

---@class LvimRenderSplitState
---@field buf integer          the mirror buffer
---@field win integer          the window showing it
---@field source_win integer   the window the mirror was opened FROM, for scroll sync
---@field timer uv.uv_timer_t|nil  the content-sync debounce
---@field generation integer   the source `changedtick` the mirror last copied
---@field lens_off boolean     this split switched the source buffer's LSP codelens off, so closing
---   it must switch that back on — and only then
---@field source_off boolean   this split switched the SOURCE buffer's rendering off, so closing
---   it must switch that back on — and only then, so a `:LvimRender off` the reader ran
---   themselves in the meantime is not undone behind their back

---@type table<integer, LvimRenderSplitState>  source buffer → its open split
local splits = {}

--- The split open for `buf`, if any and still valid. A window or buffer can be closed by any means
--- (`:q`, `:bd`, a session restore), so validity is checked at every entry rather than trusted from
--- the bookkeeping — the bookkeeping is a cache of the truth, not the truth.
---@param buf integer
---@return LvimRenderSplitState|nil
local function live(buf)
    local sp = splits[buf]
    if sp == nil then
        return nil
    end
    if not api.nvim_buf_is_valid(sp.buf) or not api.nvim_win_is_valid(sp.win) then
        M.close(buf)
        return nil
    end
    return sp
end

--- Is `buf` a mirror rather than a real file? Read by the engine so a mirror never reveals: the
--- reader's cursor is not in it, and its content is not theirs to edit.
---@param buf integer
---@return boolean
function M.is_mirror(buf)
    return vim.b[buf].lvim_render_mirror == true
end

--- The source buffer a mirror projects, or nil.
---@param buf integer
---@return integer|nil
function M.source_of(buf)
    local src = vim.b[buf].lvim_render_source
    return type(src) == "number" and api.nvim_buf_is_valid(src) and src or nil
end

--- Copy the source's lines into the mirror. Cheap when nothing changed: `changedtick` is the
--- source's own statement about that, so an unchanged buffer costs one integer comparison rather
--- than a line copy of the whole file.
---@param buf integer  the SOURCE buffer
---@param force boolean?  copy even when the tick says nothing moved
---@return boolean copied
local function sync_content(buf, force)
    local sp = live(buf)
    if sp == nil or not api.nvim_buf_is_valid(buf) then
        return false
    end
    local tick = api.nvim_buf_get_changedtick(buf)
    if not force and tick == sp.generation then
        return false
    end
    sp.generation = tick

    local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
    vim.bo[sp.buf].modifiable = true
    api.nvim_buf_set_lines(sp.buf, 0, -1, false, lines)
    vim.bo[sp.buf].modifiable = false
    -- The mirror carries no undo history of its own: an overwrite is not an edit anyone should be
    -- able to walk back into, and a growing undo tree over a file-sized buffer is pure waste.
    pcall(function()
        vim.bo[sp.buf].undolevels = -1
    end)
    return true
end

--- Put the mirror's view where the source's is. Only the TOP line is synced, deliberately: the two
--- windows render to different heights (a rendered table is taller than its source rows), so
--- matching cursor lines would fight the difference. The top line is what "looking at the same part
--- of the document" means.
---@param buf integer  the SOURCE buffer
---@return nil
local function sync_scroll(buf)
    local sp = live(buf)
    if sp == nil or not config.split.sync_scroll then
        return
    end
    if not api.nvim_win_is_valid(sp.source_win) then
        return
    end
    local top = api.nvim_win_call(sp.source_win, function()
        return vim.fn.line("w0")
    end)
    api.nvim_win_call(sp.win, function()
        local last = api.nvim_buf_line_count(sp.buf)
        vim.fn.winrestview({ topline = math.min(top, last), lnum = math.min(top, last) })
    end)
end

--- Refresh the mirror now: content, then view.
---@param buf integer?  source buffer (defaults to the current one, or the source of a mirror)
---@return boolean refreshed
function M.redraw(buf)
    buf = buf or api.nvim_get_current_buf()
    buf = M.source_of(buf) or buf
    if live(buf) == nil then
        return false
    end
    sync_content(buf, true)
    sync_scroll(buf)
    return true
end

--- Schedule a content sync, coalesced. Typing produces one sync per idle window rather than one per
--- keystroke — the same debounce the renderer itself uses, for the same reason.
---@param buf integer
---@return nil
local function schedule_sync(buf)
    local sp = live(buf)
    if sp == nil then
        return
    end
    if sp.timer == nil then
        sp.timer = vim.uv.new_timer()
    end
    sp.timer:stop()
    sp.timer:start(
        math.max(0, config.split.debounce),
        0,
        vim.schedule_wrap(function()
            if sync_content(buf) then
                sync_scroll(buf)
            end
        end)
    )
end

--- Wire the events that keep ONE split current. Scoped to its own augroup so closing the split
--- removes exactly its listeners and nothing else's.
---@param buf integer
---@return integer group
local function attach_events(buf)
    local group = api.nvim_create_augroup("LvimRenderSplit" .. buf, { clear = true })

    api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        group = group,
        buffer = buf,
        callback = function()
            schedule_sync(buf)
        end,
    })
    -- Leaving insert is where a burst of edits settles; sync it immediately rather than waiting out
    -- the debounce, so the preview is current the moment you stop typing.
    api.nvim_create_autocmd("InsertLeave", {
        group = group,
        buffer = buf,
        callback = function()
            sync_content(buf)
            sync_scroll(buf)
        end,
    })
    -- WinScrolled's patterns are WINDOW IDS, not file names, so it is registered pattern-less and
    -- filtered by which window actually moved.
    api.nvim_create_autocmd({ "WinScrolled", "WinResized" }, {
        group = group,
        callback = function()
            local sp = live(buf)
            if sp ~= nil and api.nvim_get_current_win() == sp.source_win then
                sync_scroll(buf)
            end
        end,
    })
    api.nvim_create_autocmd("WinClosed", {
        group = group,
        callback = function(ev)
            local win = tonumber(ev.match) or -1
            local sp = splits[buf]
            if sp ~= nil and (win == sp.win or win == sp.source_win) then
                M.close(buf)
            end
        end,
    })
    api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
        group = group,
        buffer = buf,
        callback = function()
            M.close(buf)
        end,
    })
    return group
end

--- Open the preview for `buf` beside its window. Idempotent: a second call focuses the existing
--- preview rather than opening another, because two mirrors of one file is not a thing anyone
--- means to ask for.
---@param buf integer?  defaults to the current buffer
---@return boolean opened
function M.open(buf)
    buf = buf or api.nvim_get_current_buf()
    buf = M.source_of(buf) or buf

    if M.is_mirror(buf) then
        return false
    end
    local st = state.get(buf)
    if st == nil then
        vim.notify("lvim-render: this buffer is not rendered — nothing to preview", vim.log.levels.WARN)
        return false
    end

    local existing = live(buf)
    if existing ~= nil then
        api.nvim_set_current_win(existing.win)
        return true
    end

    local source_win = api.nvim_get_current_win()
    local mirror = api.nvim_create_buf(false, true)
    vim.b[mirror].lvim_render_mirror = true
    vim.b[mirror].lvim_render_source = buf
    vim.bo[mirror].bufhidden = "wipe"
    vim.bo[mirror].buftype = "nofile"
    vim.bo[mirror].swapfile = false
    local name = api.nvim_buf_get_name(buf)
    pcall(
        api.nvim_buf_set_name,
        mirror,
        "lvim-render://"
            .. (vim.fn.fnamemodify(name, ":t") ~= "" and vim.fn.fnamemodify(name, ":t") or ("buffer-" .. buf))
    )

    vim.cmd(config.split.position == "left" and "leftabove vsplit" or "rightbelow vsplit")
    local win = api.nvim_get_current_win()
    api.nvim_win_set_buf(win, mirror)
    if config.split.width > 0 then
        local cells = config.split.width <= 1 and math.floor(vim.o.columns * config.split.width)
            or math.floor(config.split.width)
        pcall(api.nvim_win_set_width, win, cells)
    end
    for opt, value in pairs(config.split.win_options or {}) do
        pcall(function()
            vim.wo[win][opt] = value
        end)
    end
    -- THE PREVIEW GETS ITS OWN 'winbar' when the source window has one. Chrome above the text
    -- shifts where the text starts, so a winbar on the source only — the usual case, since a
    -- statusline plugin draws one for real files and not for a scratch buffer — puts the two
    -- documents one row apart, and a preview whose rows do not line up with the source's is
    -- harder to read than no preview.
    --
    -- ITS OWN, not a copy of the source's: the plugin that owns that winbar excludes `nofile`
    -- buffers on purpose and clears its own value back off this window, so copying it would be
    -- undone the moment the window is entered. A different string is a foreign winbar, which such
    -- a plugin leaves alone — and it can say something useful while it is there.
    if (config.split.win_options or {}).winbar == nil and vim.wo[source_win].winbar ~= "" then
        pcall(function()
            vim.wo[win].winbar = config.split.winbar
        end)
    end

    splits[buf] = {
        buf = mirror,
        win = win,
        source_win = source_win,
        timer = nil,
        generation = -1,
        source_off = false,
        lens_off = false,
    }

    -- The filetype is set AFTER the buffer is in a window, so the FileType autocmd attaches the
    -- renderer to a mirror that already has somewhere to draw.
    sync_content(buf, true)
    vim.bo[mirror].filetype = vim.bo[buf].filetype
    attach_events(buf)
    sync_scroll(buf)

    -- THE SOURCE GOES RAW. This is what makes a split preview a preview rather than a clone: one
    -- side is the text you edit — every marker, every fence, every pipe as written — and the other
    -- is what it becomes. Rendering both sides shows the reader the same thing twice.
    --
    -- Done through the engine's own per-buffer switch, so the source window's 'conceallevel' and
    -- fold options are RESTORED exactly as `:LvimRender off` restores them, and re-taken on close.
    if config.split.source == "raw" and st.enabled then
        splits[buf].source_off = true
        engine.set_raw(buf, true)
    end

    -- QUIET THE SOURCE. Codelens draws VIRTUAL LINES ("1 reference" above a heading): not the
    -- file's own text, and each one pushes the source down a row — the very misalignment the
    -- preview's winbar exists to avoid. Turned off for the source BUFFER only (the preview is a
    -- different buffer and never had lenses), through Neovim's own per-buffer API, and only when
    -- it was on — so closing restores exactly what was there.
    if config.split.quiet_source and vim.lsp.codelens.is_enabled({ bufnr = buf }) then
        splits[buf].lens_off = true
        pcall(vim.lsp.codelens.enable, false, { bufnr = buf })
        pcall(vim.lsp.codelens.clear, nil, buf)
    end

    if config.split.focus == "source" then
        pcall(api.nvim_set_current_win, source_win)
    end
    return true
end

--- Close the preview for `buf`, leaving nothing behind: the timer, the augroup, the window and the
--- mirror buffer all go.
---@param buf integer?  defaults to the current buffer (a mirror closes its own source's split)
---@return boolean closed
function M.close(buf)
    buf = buf or api.nvim_get_current_buf()
    buf = M.source_of(buf) or buf
    local sp = splits[buf]
    if sp == nil then
        return false
    end
    splits[buf] = nil

    if sp.timer ~= nil then
        sp.timer:stop()
        if not sp.timer:is_closing() then
            sp.timer:close()
        end
    end
    pcall(api.nvim_del_augroup_by_name, "LvimRenderSplit" .. buf)
    if api.nvim_win_is_valid(sp.win) then
        pcall(api.nvim_win_close, sp.win, true)
    end
    if api.nvim_buf_is_valid(sp.buf) then
        pcall(api.nvim_buf_delete, sp.buf, { force = true })
    end
    -- Give the source its rendering back, but ONLY if this split is what took it away.
    if sp.source_off and api.nvim_buf_is_valid(buf) then
        engine.set_raw(buf, false)
    end
    if sp.lens_off and api.nvim_buf_is_valid(buf) then
        pcall(vim.lsp.codelens.enable, true, { bufnr = buf })
    end
    return true
end

--- Open the preview, or close it when one is already open.
---@param buf integer?
---@return boolean open  whether a preview is open AFTER the call
function M.toggle(buf)
    buf = buf or api.nvim_get_current_buf()
    buf = M.source_of(buf) or buf
    if live(buf) ~= nil then
        M.close(buf)
        return false
    end
    return M.open(buf)
end

--- Whether a preview is open for `buf` — for health, a statusline, or a fixture.
---@param buf integer?
---@return { open: boolean, buf: integer|nil, win: integer|nil }
function M.status(buf)
    buf = buf or api.nvim_get_current_buf()
    buf = M.source_of(buf) or buf
    local sp = live(buf)
    if sp == nil then
        return { open = false, buf = nil, win = nil }
    end
    return { open = true, buf = sp.buf, win = sp.win }
end

return M
