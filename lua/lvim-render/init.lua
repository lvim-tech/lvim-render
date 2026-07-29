-- lvim-render: the entry point and the lifecycle wiring — which buffers attach, which events keep
-- them current, and the :LvimRender command.
--
-- The plugin decorates the buffer you are EDITING, in place: treesitter parse → node walk →
-- decoration ops → ephemeral extmarks, windowed to what is on screen. Nothing persistent
-- accumulates; turning it off leaves the buffer exactly as it found it, fold options included.
--
-- FORMATS are config blocks (`markdown`, later `org`, `typst`, …): what is common to every format
-- (timing, reveal, folding, the palette mapping) lives at the top of the config; what a format
-- owns lives in its block. Phase 1 renders markdown; the other blocks are the fixed config
-- surface their phases will fill.
--
---@module "lvim-render"

local config = require("lvim-render.config")
local engine = require("lvim-render.engine")
local fold = require("lvim-render.fold")
local highlights = require("lvim-render.highlights")
local state = require("lvim-render.state")
local queries = require("lvim-render.queries")
local split = require("lvim-render.split")
local cmp = require("lvim-render.cmp")
local merge = require("lvim-utils.utils").merge

local api = vim.api

local M = {}

---@type boolean  setup() has wired the autocmds and the provider
local ready = false

--- Normalise a buffer argument: nil AND 0 mean the current buffer (the Neovim convention every
--- caller will assume — `0 or current` keeps the 0, and `state.buffers[0]` never exists, which
--- made status(0) deny a buffer that was visibly rendering. Measured, then fixed here for every
--- public entry).
---@param buf integer|nil
---@return integer
local function bufnr(buf)
    if buf == nil or buf == 0 then
        return api.nvim_get_current_buf()
    end
    return buf
end

--- Every filetype any enabled format claims, for the FileType autocmd pattern.
---@return string[]
local function attach_patterns()
    local out = {}
    for _, format in ipairs({ "markdown", "org", "typst", "latex" }) do
        local fconf = config[format]
        if type(fconf) == "table" and fconf.enabled then
            vim.list_extend(out, fconf.filetypes or {})
        end
    end
    return out
end

--- Toggle / switch rendering for one buffer.
---@param buf integer
---@param action "toggle"|"on"|"off"
---@return nil
local function set_buffer(buf, action)
    local st = state.get(buf)
    if st == nil then
        return
    end
    local on = action == "on" or (action == "toggle" and not st.enabled)
    engine.set_enabled(buf, on)
end

--- The :LvimRender command body.
---@param action string  "toggle" (default) | "on" | "off"
---@param scope string?  "all" flips every attached buffer and the master switch with it
---@return nil
local function command(action, scope)
    action = action ~= "" and action or "toggle"
    if action == "table" then
        require("lvim-render.table_editor").open()
        return
    end
    if action == "split" then
        local verb = scope or "toggle"
        if verb == "open" then
            split.open()
        elseif verb == "close" then
            split.close()
        elseif verb == "redraw" then
            split.redraw()
        else
            split.toggle()
        end
        return
    end
    if scope == "all" then
        local on = action == "on" or (action == "toggle" and not config.enabled)
        config.enabled = on
        for buf in pairs(state.buffers) do
            engine.set_enabled(buf, on)
        end
        return
    end
    set_buffer(api.nvim_get_current_buf(), action)
end

--- Wire the provider and the lifecycle autocmds. Once.
---@return nil
local function attach_events()
    engine.start()
    local group = api.nvim_create_augroup("LvimRender", { clear = true })

    api.nvim_create_autocmd("FileType", {
        group = group,
        pattern = attach_patterns(),
        callback = function(ev)
            engine.attach(ev.buf)
        end,
    })

    -- A window starts showing an attached buffer: own its options; stops: give them back.
    api.nvim_create_autocmd("BufWinEnter", {
        group = group,
        callback = function()
            engine.on_win_enter(api.nvim_get_current_win())
        end,
    })
    api.nvim_create_autocmd("WinClosed", {
        group = group,
        callback = function(ev)
            engine.on_win_closed(tonumber(ev.match) or -1)
        end,
    })

    -- The reveal follows the cursor; only the lines whose membership changed are redrawn.
    api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
        group = group,
        callback = function()
            engine.on_cursor_moved()
        end,
    })

    -- Entering or leaving a rendering mode repaints the current window (insert ↔ normal is the
    -- one the eye notices).
    api.nvim_create_autocmd("ModeChanged", {
        group = group,
        callback = function(ev)
            local from, to = ev.match:match("^(.*):(.*)$")
            engine.on_mode_changed(from or "", to or "")
        end,
    })

    -- MITIGATION FOR AN UPSTREAM REDRAW DEFECT: Neovim's incremental scroll tears the grid over
    -- `conceal_lines` runs carrying `virt_lines` blocks — rows drawn twice, persisting until the
    -- next repaint (reproduced in `nvim --clean` with manually-set marks and wheel scrolling, no
    -- plugin code: 4/18 torn captures). A window that just scrolled over boxed-table state asks
    -- for one honest repaint, so a tear lasts a frame instead of sitting on screen. Remove when
    -- the upstream redraw is fixed.
    api.nvim_create_autocmd("WinScrolled", {
        group = group,
        callback = function()
            for key in pairs(vim.v.event) do
                if key ~= "all" then
                    engine.on_win_scrolled(tonumber(key) or -1)
                end
            end
        end,
    })

    api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
        group = group,
        callback = function(ev)
            engine.detach(ev.buf)
        end,
    })
end

--- Rendering state of a buffer, for a statusline or a fixture.
---@param buf integer?  defaults to the current buffer
---@return { attached: boolean, enabled: boolean, inert: string|nil, format: string|nil }
function M.status(buf)
    buf = bufnr(buf)
    local st = state.get(buf)
    if st == nil then
        return { attached = false, enabled = false, inert = nil, format = nil }
    end
    return {
        attached = true,
        enabled = st.enabled,
        inert = st.inert,
        format = st.format,
        mirror = split.is_mirror(buf),
        split = split.status(buf).open,
    }
end

--- Rebuild the fold outline of a buffer now, bypassing the debounce. Public for the same reason
--- `status` is: "is the outline current" is a question worth being able to ask.
---@param buf integer?
---@return nil
function M.refresh(buf)
    buf = bufnr(buf)
    if state.get(buf) ~= nil then
        fold.rebuild(buf)
        fold.refresh(buf, 0, api.nvim_buf_line_count(buf) - 1)
    end
end

--- The side-by-side preview: a mirror buffer rendered in full beside the source. Public for the
--- same reason `status` is — "is a preview open, and of what" is a question worth being able to ask.
---@param action "toggle"|"open"|"close"|"redraw"|nil
---@param buf integer?
---@return boolean
function M.split(action, buf)
    buf = bufnr(buf)
    if action == "open" then
        return split.open(buf)
    elseif action == "close" then
        return split.close(buf)
    elseif action == "redraw" then
        return split.redraw(buf)
    end
    return split.toggle(buf)
end

--- Merge user options into the live config and start rendering.
---@param opts LvimRenderConfig?
---@return nil
function M.setup(opts)
    merge(config, opts or {})
    state.ready = true
    highlights.setup()
    -- The math maps merge user config over lvim-tex's shared data; a repeat setup() rebuilds.
    require("lvim-render.render").invalidate_math()

    -- A FORMAT WHOSE GRAMMAR IS NOT NAMED AFTER ITS FILETYPE says so, and the mapping is
    -- registered before anything asks for a parser: `tex` is parsed by `latex`, and without this
    -- every query compiled against a language that does not exist.
    for _, format in ipairs(engine.formats) do
        local fconf = config[format]
        if type(fconf) == "table" and fconf.enabled and type(fconf.language) == "string" then
            pcall(vim.treesitter.language.register, fconf.language, fconf.filetypes or {})
        end
    end

    -- The fence-visibility mode edits the LANGUAGE's highlight query (strip conceal_lines), so it
    -- applies per format language, before any buffer attaches or re-attaches. EVERY implemented
    -- format, not markdown alone: the mechanism is language-agnostic, and a format whose query
    -- hides nothing simply records that it had nothing to strip.
    for _, format in ipairs(engine.formats) do
        local fconf = config[format]
        if type(fconf) == "table" and fconf.enabled and fconf.code ~= nil then
            queries.apply(format, fconf.code.fences)
        end
    end

    -- Registered on every setup(): a repeat call may have changed the callout types, and the source
    -- reads them live, but lvim-cmp may also have loaded only since the first call.
    cmp.setup()

    -- SELF-REGISTER the grammars the community parser catalogue does not carry, so installing this
    -- plugin is enough and no central config is edited for them. Optional cross-plugin call: with
    -- no lvim-pkg the org buffer simply attaches inert and health names the missing grammar.
    local ok_pkg, pkg = pcall(require, "lvim-pkg")
    if ok_pkg and type(pkg.register_parser) == "function" then
        pkg.register_parser("org", {
            filetypes = { "org" },
            source = {
                -- Self-contained: grammar and queries in one repository (its `queries/` holds
                -- highlights + markup only — the injections this plugin needs are shipped by
                -- lvim-render itself, as an `; extends` file).
                type = "self_contained",
                parser_url = "https://github.com/nvim-orgmode/tree-sitter-org",
            },
        })
    end

    if not ready then
        ready = true
        attach_events()

        api.nvim_create_user_command("LvimRender", function(ev)
            command(ev.fargs[1] or "toggle", ev.fargs[2])
        end, {
            nargs = "*",
            complete = function(lead, line)
                local words = vim.split(line, "%s+")
                if #words <= 2 then
                    return vim.tbl_filter(function(word)
                        return word:find(lead, 1, true) == 1
                    end, { "toggle", "on", "off", "split", "table" })
                end
                local second = words[2] == "split" and { "toggle", "open", "close", "redraw" } or { "all" }
                return vim.tbl_filter(function(word)
                    return word:find(lead, 1, true) == 1
                end, second)
            end,
            desc = "lvim-render: toggle rendering (`all` every buffer, `split` the preview, `table` the editor)",
        })
    end

    -- A repeat setup() may have changed formats or filetypes: sweep what is already open.
    for _, buf in ipairs(api.nvim_list_bufs()) do
        if api.nvim_buf_is_loaded(buf) and state.get(buf) == nil then
            local ft = vim.bo[buf].filetype
            if ft ~= "" and engine.format_for(ft) ~= nil then
                engine.attach(buf)
            end
        end
    end
end

return M
