-- lvim-render.health: `:checkhealth lvim-render`.
--
-- The checks are the ones that explain an actual symptom: a missing grammar renders nothing while
-- every line of the plugin works; a foldexpr another plugin set explains why no folds appear; a
-- two-cell glyph explains a heading whose band is one column short. Formats whose renderer has not
-- shipped yet are reported as exactly that — a phase status, not an error.
--
---@module "lvim-render.health"

local config = require("lvim-render.config")
local engine = require("lvim-render.engine")
local fold = require("lvim-render.fold")
local queries = require("lvim-render.queries")
local split = require("lvim-render.split")
local state = require("lvim-render.state")

local fn = vim.fn
local health = vim.health

local M = {}

--- Report on one configurable glyph. One or two cells pass (a trailing space is a spacing choice,
--- not a defect); wider means a double-width character where a single one was assumed; EMPTY is
--- reported as "nothing drawn" — a legitimate way to switch a glyph off.
---@param label string
---@param value any
---@return nil
local function check_glyph(label, value)
    if type(value) ~= "string" then
        health.error(("%s must be a string, got %s"):format(label, type(value)))
        return
    end
    if value == "" then
        health.ok(("%s is empty (nothing drawn)"):format(label))
        return
    end
    local cells = fn.strdisplaywidth(value)
    if cells <= 2 then
        health.ok(("%s = %q (%d cell%s)"):format(label, value, cells, cells == 1 and "" or "s"))
    else
        health.warn(("%s = %q occupies %d cells — the rendered columns will not line up"):format(label, value, cells))
    end
end

--- Report on one format template's placeholder names — an unknown `{name}` is drawn verbatim,
--- which is visible but puzzling; naming the known ones turns a puzzle into a one-word fix.
---@param label string
---@param value any
---@param known string[]
---@return nil
local function check_template(label, value, known)
    if type(value) ~= "string" then
        health.error(("%s must be a string, got %s"):format(label, type(value)))
        return
    end
    local lookup = {}
    for _, name in ipairs(known) do
        lookup[name] = true
    end
    local unknown = {}
    for name in value:gmatch("{(%w+)}") do
        if not lookup[name] then
            unknown[#unknown + 1] = name
        end
    end
    if #unknown == 0 then
        health.ok(("%s = %q"):format(label, value))
    else
        health.warn(("%s = %q uses unknown placeholder(s): %s"):format(label, value, table.concat(unknown, ", ")), {
            "Known here: " .. table.concat(known, ", ") .. ". Unknown ones are drawn as written.",
        })
    end
end

--- Run the checks.
---@return nil
function M.check()
    health.start("lvim-render")

    if fn.has("nvim-0.11") == 1 then
        health.ok("Neovim " .. tostring(vim.version()))
    else
        health.error("Neovim 0.11 or newer is required (decoration providers, treesitter range parsing)")
    end

    if pcall(require, "lvim-utils.utils") then
        health.ok("lvim-utils found")
    else
        health.error("lvim-utils is not on the runtimepath (setup() cannot merge options)")
    end

    if pcall(require, "lvim-ts") then
        health.ok("lvim-ts found — grammars resolve and install through it")
    else
        health.info("lvim-ts not found — grammar resolution falls back to the runtime mapping")
    end

    if require("lvim-render.render").math_available() then
        health.ok("lvim-tex found — math substitutes through the SHARED symbol table (one map across the set)")
    elseif config.math.inline.enabled or config.math.block.enabled then
        health.warn(
            "lvim-tex is not on the runtimepath — math spans keep their delimiters concealed but nothing substitutes",
            {
                "Install lvim-tech/lvim-tex (its conceal data is the shared symbol table),",
                "or provide your own maps via math.inline.maps / math.block.maps.",
            }
        )
    end

    if vim._foldupdate ~= nil then
        health.ok("vim._foldupdate available — folds refresh in place after an edit")
    else
        health.warn("vim._foldupdate is missing on this build — folds refresh only on Neovim's own re-evaluation")
    end

    -- ── formats ─────────────────────────────────────────────────────────────
    health.start("lvim-render: formats")
    local implemented = {}
    for _, format in ipairs(engine.formats) do
        implemented[format] = true
    end
    for _, format in ipairs({ "markdown", "org", "typst", "asciidoc", "latex" }) do
        local fconf = config[format]
        if type(fconf) ~= "table" then
            health.error(("config.%s is missing"):format(format))
        elseif not fconf.enabled then
            health.info(("%s: disabled in the config"):format(format))
        elseif not implemented[format] then
            health.info(
                ("%s: configured, renderer lands in a later phase — buffers do not attach yet"):format(format)
            )
        else
            local lang = format
            local ok = pcall(vim.treesitter.language.add, lang)
            if ok then
                health.ok(
                    ("%s: renderer active, %q grammar present (filetypes: %s)"):format(
                        format,
                        lang,
                        table.concat(fconf.filetypes or {}, ", ")
                    )
                )
            elseif format == "org" then
                -- Org's grammar is not in the community catalogue; this plugin contributes it to
                -- lvim-pkg from its own setup(), so the fix is an install and never a config edit.
                health.error('org: the "org" grammar is not installed — buffers attach inert', {
                    "lvim-render registers the grammar with lvim-pkg itself (self-contained,",
                    "from nvim-orgmode/tree-sitter-org); install it through lvim-installer or",
                    'require("lvim-pkg").install("parser", { "org" }, function() end).',
                    "Without lvim-pkg, put an `org` parser anywhere on the runtimepath.",
                })
            else
                health.error(("%s: the %q grammar is not installed — buffers attach inert"):format(format, lang), {
                    "Install it through lvim-ts / lvim-pkg (ensure_installed).",
                })
            end
        end
    end

    -- ── attached buffers ────────────────────────────────────────────────────
    health.start("lvim-render: buffers")
    local any = false
    for buf, st in pairs(state.buffers) do
        any = true
        if st.inert ~= nil then
            health.warn(("buffer %d (%s): attached INERT — %s"):format(buf, st.format, st.inert))
        else
            health.ok(
                ("buffer %d (%s): %s, %d headings in the outline"):format(
                    buf,
                    st.format,
                    st.enabled and "rendering" or "off",
                    #st.outline
                )
            )
        end
    end
    if not any then
        health.info("no attached buffers right now")
    end

    -- ── window ownership ────────────────────────────────────────────────────
    health.start("lvim-render: windows")
    local owned = false
    for win, saved in pairs(state.wins) do
        owned = true
        local prev = saved.foldexpr
        if config.fold.enabled and config.fold.headings and prev ~= "0" and prev ~= "" then
            health.warn(
                ("window %d: 'foldexpr' was already %q before attach — that owner and this plugin want the same option"):format(
                    win,
                    prev
                ),
                {
                    "The previous value is restored on :LvimRender off / detach.",
                    "If the other owner re-sets it later, folds may silently change hands.",
                }
            )
        else
            health.ok(("window %d: options owned (restored on detach)"):format(win))
        end
        -- The LIVE value against what the plugin asserts: 'conceallevel'/'concealcursor' are
        -- re-asserted at every BufWinEnter, so a mismatch HERE means another autocmd wrote them
        -- afterwards and is actively fighting (a live incident: a window-option enforcer
        -- re-applied conceallevel=0 on the same events).
        if vim.api.nvim_win_is_valid(win) then
            local live_cl = vim.wo[win].conceallevel
            local live_cc = vim.wo[win].concealcursor
            if live_cl ~= config.conceal.level or live_cc ~= config.conceal.cursor then
                health.error(
                    ("window %d: conceal options are %d/%q but the plugin asserts %d/%q — another owner is overwriting them"):format(
                        win,
                        live_cl,
                        live_cc,
                        config.conceal.level,
                        config.conceal.cursor
                    ),
                    {
                        "Some other config/plugin sets these on BufWinEnter/FileType after this plugin does.",
                        "Exclude this filetype from that machinery, or markers will not conceal.",
                        ("This window's pre-attach values (%d/%q) are restored on :LvimRender off."):format(
                            saved.conceallevel,
                            saved.concealcursor
                        ),
                    }
                )
            else
                health.ok(
                    ("window %d: conceallevel=%d concealcursor=%q held (was %d/%q before attach)"):format(
                        win,
                        live_cl,
                        live_cc,
                        saved.conceallevel,
                        saved.concealcursor
                    )
                )
            end
        end
    end
    if not owned then
        health.info("no windows currently carry the plugin's options")
    end

    -- ── the side-by-side preview ────────────────────────────────────────────
    -- Reported per open preview rather than as a config echo: the thing that goes wrong here is a
    -- mirror that stopped tracking its source, which only a live pair can show.
    health.start("lvim-render: preview")
    local previews = 0
    for buf in pairs(state.buffers) do
        if vim.api.nvim_buf_is_valid(buf) and not split.is_mirror(buf) then
            local sp = split.status(buf)
            if sp.open then
                previews = previews + 1
                local src_lines = vim.api.nvim_buf_line_count(buf)
                local mirror_lines = vim.api.nvim_buf_line_count(sp.buf)
                if src_lines ~= mirror_lines then
                    health.warn(
                        ("buffer %d: the preview holds %d lines to the source's %d — the mirror is behind"):format(
                            buf,
                            mirror_lines,
                            src_lines
                        ),
                        {
                            "It catches up after `split.debounce` ms of idle, or at once on :LvimRender split redraw.",
                            "A permanent difference means the sync autocommands were cleared from outside.",
                        }
                    )
                else
                    health.ok(
                        ("buffer %d: preview open in window %d, %d lines in step"):format(buf, sp.win, mirror_lines)
                    )
                end
                local src_st = state.get(buf)
                if config.split.source == "raw" and (src_st == nil or not src_st.raw) then
                    health.warn(
                        ("buffer %d: the preview is open but the source is still rendering"):format(buf),
                        { 'split.source = "raw" asks for the opposite; something re-enabled it after the open.' }
                    )
                end
                local mst = state.get(sp.buf)
                if mst == nil then
                    health.error(
                        ("buffer %d: the preview buffer is not attached to the renderer — it shows raw text"):format(
                            buf
                        ),
                        { "Its filetype was changed after the preview opened." }
                    )
                end
            end
        end
    end
    if previews == 0 then
        health.info("no preview open right now (:LvimRender split opens one)")
    end

    -- ── completion ──────────────────────────────────────────────────────────
    -- lvim-cmp is a sibling, not a dependency: its absence is INFO, never a warning. What is worth
    -- reporting is the one case that looks broken from the user's side — it is installed, the
    -- source is switched on, and the registration still did not happen.
    health.start("lvim-render: completion")
    if not config.completion.enabled then
        health.info("completion.enabled = false — no source is registered")
    else
        local ok_cmp, cmp_plugin = pcall(require, "lvim-cmp")
        if not ok_cmp then
            health.info("lvim-cmp is not installed — callout/checkbox completion is simply off")
        elseif type(cmp_plugin.register_source) ~= "function" then
            health.warn("lvim-cmp is installed but exposes no register_source — the source could not be registered")
        else
            local types = #((config.markdown.callouts or {}).types or {})
            local states = #((config.markdown.checkboxes or {}).states or {})
            health.ok(
                ("registered with lvim-cmp at priority %d — %d callout types, %d checkbox states"):format(
                    config.completion.priority,
                    types,
                    states
                )
            )
        end
    end

    -- ── fold expression boundaries ──────────────────────────────────────────
    for buf, e in pairs(fold.errors) do
        health.error(
            ("buffer %d: the %s raised %q (%d time%s) — the builtin fold line was drawn instead"):format(
                buf,
                e.where,
                e.err,
                e.count,
                e.count == 1 and "" or "s"
            ),
            { "Without this boundary Neovim would draw an EMPTY fold line and no message at all." }
        )
    end

    -- ── configuration ───────────────────────────────────────────────────────
    health.start("lvim-render: configuration")

    for _, key in ipairs({ "debounce", "max_file_size", "max_lines" }) do
        local value = config[key]
        if type(value) == "number" and value > 0 then
            health.ok(("%s = %d"):format(key, value))
        else
            health.error(("%s must be a positive number, got %s"):format(key, tostring(value)))
        end
    end

    if type(config.reveal.lines) == "number" and config.reveal.lines >= 0 then
        health.ok(("reveal.lines = %d"):format(config.reveal.lines))
    else
        health.error("reveal.lines must be a non-negative number")
    end

    if config.conceal.level < 2 and config.markdown.headings.conceal_markers then
        health.warn(("conceal.level = %d — heading markers cannot fully hide below 2"):format(config.conceal.level))
    else
        health.ok(("conceal.level = %d"):format(config.conceal.level))
    end

    -- Typst's enum ordinal is a template like the fold line's: an unknown placeholder is drawn
    -- verbatim, which is visible but puzzling until something names the one placeholder there is.
    local enum = config.typst.lists.enum
    if enum ~= nil and enum.enabled then
        check_template("typst.lists.enum.format", enum.format, { "n" })
    end
    check_glyph("typst.terms.icon", config.typst.terms.icon)
    check_glyph("typst.labels.icon", config.typst.labels.icon)
    check_glyph("typst.refs.icon", config.typst.refs.icon)

    if config.markdown.headings.text ~= "accent" and config.markdown.headings.text ~= "theme" then
        health.error(
            ('markdown.headings.text must be "accent" or "theme", got %s'):format(
                tostring(config.markdown.headings.text)
            )
        )
    end

    if config.conceal.cursor:match("^[nvic]*$") == nil then
        health.error(
            ("conceal.cursor = %q contains letters 'concealcursor' does not accept (n, v, i, c)"):format(
                config.conceal.cursor
            )
        )
    end

    if config.split.position ~= "right" and config.split.position ~= "left" then
        health.error(('split.position must be "right" or "left", got %s'):format(tostring(config.split.position)))
    end
    if config.split.source ~= "raw" and config.split.source ~= "rendered" then
        health.error(('split.source must be "raw" or "rendered", got %s'):format(tostring(config.split.source)))
    elseif config.split.source == "rendered" then
        health.info('split.source = "rendered" — both sides of a preview render, so it shows the source twice')
    end
    if config.split.focus ~= "source" and config.split.focus ~= "preview" then
        health.error(('split.focus must be "source" or "preview", got %s'):format(tostring(config.split.focus)))
    end
    if type(config.split.debounce) ~= "number" or config.split.debounce < 0 then
        health.error("split.debounce must be a non-negative number")
    end
    -- `width` is dual-scale on purpose (≤ 1 is a fraction, > 1 is cells), so the only wrong value
    -- is a negative one — and 0 means "leave whatever :vsplit chose", not "no width".
    if type(config.split.width) ~= "number" or config.split.width < 0 then
        health.error("split.width must be 0 (leave it to :vsplit), a fraction ≤ 1, or a cell count")
    end

    -- The table editor: its keys are buffer-local and its border is a Neovim border value; a
    -- broken one of either is invisible until the day the editor is opened.
    local ed = config.tables_editor
    if type(ed) ~= "table" then
        health.error("tables_editor must be a table")
    else
        if type(ed.width) ~= "number" or ed.width <= 0 or type(ed.height) ~= "number" or ed.height <= 0 then
            health.error("tables_editor.width / .height must be positive numbers (fractions of the editor)")
        end
        if type(ed.border) ~= "string" and type(ed.border) ~= "table" then
            health.error("tables_editor.border must be a Neovim border value — a name, or a list of eight cells")
        elseif type(ed.border) == "table" and #ed.border ~= 8 then
            health.warn(("tables_editor.border has %d cells; Neovim expects eight"):format(#ed.border))
        end
        local taken = {}
        for name, key in pairs(ed.keys or {}) do
            if type(key) == "string" and key ~= "" then
                if taken[key] then
                    health.error(
                        ("tables_editor.keys.%s and .%s are both %q — one of them never fires"):format(
                            name,
                            taken[key],
                            key
                        )
                    )
                end
                taken[key] = name
            end
        end
        if next(taken) ~= nil then
            health.ok(("tables_editor: %d keys bound, no collisions"):format(vim.tbl_count(taken)))
        end
    end

    -- The code block's chrome, per format: a band that cannot be drawn, an inset nobody asked for,
    -- or a width nobody recognises all fail SILENTLY at draw time — named here instead.
    for _, format in ipairs({ "markdown", "org", "typst" }) do
        local cconf = (config[format] or {}).code
        if type(cconf) == "table" then
            local where = format .. ".code"
            if cconf.position ~= "left" and cconf.position ~= "center" and cconf.position ~= "right" then
                health.error(
                    ('%s.position must be "left", "center" or "right", got %s'):format(where, tostring(cconf.position))
                )
            end
            if cconf.width ~= "full" and cconf.width ~= "content" then
                health.error(('%s.width must be "full" or "content", got %s'):format(where, tostring(cconf.width)))
            end
            if type(cconf.air) ~= "number" or cconf.air < 0 then
                health.error(("%s.air must be a number of rows, got %s"):format(where, tostring(cconf.air)))
            end
            if type(cconf.pad) ~= "number" or cconf.pad < 0 then
                health.error(("%s.pad must be a number of cells, got %s"):format(where, tostring(cconf.pad)))
            end
            if cconf.header and cconf.fences ~= "show" then
                health.warn(
                    ('%s.header needs fences = "show" — a conceal_lines-hidden fence row cannot be drawn on'):format(
                        where
                    )
                )
            end
        end
    end

    local fold_pos = config.fold.text.position
    if fold_pos ~= "right" and fold_pos ~= "left" then
        health.error(('fold.text.position must be "right" or "left", got %s'):format(tostring(fold_pos)))
    end

    local nav_mode = config.tables_nav_mode
    if nav_mode ~= "widget" and nav_mode ~= "stop" and nav_mode ~= "raw" then
        health.error(('tables_nav_mode must be "widget", "stop" or "raw", got %s'):format(tostring(nav_mode)))
    elseif nav_mode == "widget" then
        health.ok("tables_nav_mode: widget — j/k walk a boxed table row by row, paging inside the box")
    else
        health.info(("tables_nav_mode: %s — a boxed table's rows are not walked"):format(nav_mode))
    end

    for name, key in pairs(config.tables_nav_keys or {}) do
        if key ~= false and (type(key) ~= "string" or key == "") then
            health.error(("tables_nav_keys.%s must be a key string or false, got %s"):format(name, tostring(key)))
        end
    end

    if type(config.completion.priority) ~= "number" then
        health.error("completion.priority must be a number")
    end

    if config.reveal.quotes ~= "element" and config.reveal.quotes ~= "row" then
        health.error(('reveal.quotes must be "element" or "row", got %s'):format(tostring(config.reveal.quotes)))
    end
    -- A reveal mode outside render.modes never fires (the whole window is raw there already) —
    -- legal, but a config that LOOKS like it does something deserves a note.
    for _, rm in ipairs(config.reveal.modes) do
        local rendered = false
        for _, m in ipairs(config.render.modes) do
            if rm == m or rm:sub(1, #m) == m then
                rendered = true
            end
        end
        if not rendered then
            health.info(
                ("reveal.modes %q is not in render.modes — that mode renders nothing, so there is nothing to reveal"):format(
                    rm
                )
            )
        end
    end

    -- The two raw-view mechanisms must SAY THE SAME THING per mode: 'concealcursor' governs the
    -- conceal marks at the cursor, `reveal.modes` governs the plugin's own overlays. Where they
    -- disagree, the cursor line is HALF-rendered — concealed text raw while glyphs stay, or the
    -- reverse — which is worse than either choice alone.
    for _, m in ipairs({ "n", "v", "i", "c" }) do
        local conceal_holds = config.conceal.cursor:find(m, 1, true) ~= nil
        local overlays_go_raw = false
        for _, rm in ipairs(config.reveal.modes) do
            if rm == m or rm:sub(1, 1) == m then
                overlays_go_raw = true
            end
        end
        if conceal_holds and overlays_go_raw then
            health.warn(
                ("mode %q: reveal.modes strips the plugin's overlays but 'concealcursor' keeps text concealed — a half-rendered cursor line"):format(
                    m
                ),
                { ("Remove %q from conceal.cursor, or drop the mode from reveal.modes."):format(m) }
            )
        elseif not conceal_holds and not overlays_go_raw then
            health.warn(
                ("mode %q: 'concealcursor' reveals the concealed text but reveal.modes keeps the overlays — a half-rendered cursor line"):format(
                    m
                ),
                { ("Add %q to conceal.cursor, or add the mode to reveal.modes."):format(m) }
            )
        end
    end
    health.ok(
        ("conceal.cursor = %q, reveal.modes = { %s } (agreement checked above)"):format(
            config.conceal.cursor,
            table.concat(config.reveal.modes, ", ")
        )
    )

    if config.fold.enabled and config.fold.headings then
        health.ok("fold: headings fold (foldexpr/foldtext owned while attached)")
        check_template("fold.text.title", config.fold.text.title, { "icon", "title", "count" })
        check_template("fold.text.info", config.fold.text.info, { "icon", "title", "count" })
        for _, name in ipairs({ "cycle", "cycle_all" }) do
            local key = config.fold.keys[name]
            if key == false then
                health.info(("fold.keys.%s is off — no key taken"):format(name))
            elseif type(key) == "string" and key ~= "" then
                health.ok(("fold.keys.%s = %q (buffer-local, attached buffers only)"):format(name, key))
            else
                health.error(("fold.keys.%s must be a key string or false"):format(name))
            end
        end
        if config.fold.keys.cycle == "<Tab>" then
            health.info(
                "<Tab> equals <C-i> in terminals without the extended keyboard protocol — "
                    .. "the jump-forward key is shadowed in attached buffers there"
            )
        end
    else
        health.info("fold is off — no window fold options are touched")
    end

    for _, format in ipairs(engine.formats) do
        ---@type LvimRenderFormatConfig|nil
        local fconf = rawget(config, format)
        -- EVERY element block is optional, and that is not defensiveness — a format only carries
        -- the blocks it can actually draw. typst and org have no horizontal RULE (typst has no
        -- thematic break at all; org's `-----` has no node in its grammar), so `fconf.rule.glyph`
        -- was a crash waiting for the first `:checkhealth` in one of those buffers.
        local headings = fconf ~= nil and fconf.headings or nil
        local lists = fconf ~= nil and fconf.lists or nil
        local rule = fconf ~= nil and fconf.rule or nil
        if fconf == nil then
            goto next_format
        end
        if headings ~= nil then
            for level, spec in ipairs(headings.levels or {}) do
                check_glyph(("%s.headings.levels[%d].icon"):format(format, level), spec.icon)
            end
            if #(headings.levels or {}) ~= 6 then
                health.error(
                    ("%s.headings.levels must have exactly six entries, got %d"):format(
                        format,
                        #(headings.levels or {})
                    )
                )
            end
            check_glyph(format .. ".headings.setext_underline", headings.setext_underline)
        end
        if lists ~= nil then
            for depth, glyph in ipairs(lists.bullets or {}) do
                check_glyph(("%s.lists.bullets[%d]"):format(format, depth), glyph)
            end
        end
        if rule ~= nil then
            check_glyph(format .. ".rule.glyph", rule.glyph)
            check_glyph(format .. ".rule.icon", rule.icon or "")
        else
            health.info(("%s: no rule block — this format has no horizontal rule to draw"):format(format))
        end

        -- ── the inline layer ────────────────────────────────────────────────
        if fconf.inline_code ~= nil and fconf.inline_code.enabled then
            local pad = fconf.inline_code.pad
            if type(pad) ~= "string" or (pad ~= "" and fn.strchars(pad) ~= 1) then
                health.error(
                    ('%s.inline_code.pad must be one character or "" — it is what each backtick CONCEALS to'):format(
                        format
                    )
                )
            else
                health.ok(("%s.inline_code.pad = %q"):format(format, pad))
            end
        end
        if fconf.links ~= nil and fconf.links.enabled then
            check_glyph(format .. ".links.icons.link", fconf.links.icons.link)
            check_glyph(format .. ".links.icons.image", fconf.links.icons.image)
        end
        if fconf.entities ~= nil and fconf.entities.enabled then
            local bad = {}
            for name, glyph in pairs(fconf.entities.extra or {}) do
                if type(glyph) ~= "string" or fn.strchars(glyph) ~= 1 then
                    bad[#bad + 1] = name
                end
            end
            if #bad == 0 then
                health.ok(
                    ("%s.entities: %d extra mapping(s)"):format(format, vim.tbl_count(fconf.entities.extra or {}))
                )
            else
                health.error(
                    ("%s.entities.extra: %s must map to exactly ONE character (conceal cannot render more)"):format(
                        format,
                        table.concat(bad, ", ")
                    )
                )
            end
        end
        if fconf.checkboxes ~= nil and fconf.checkboxes.enabled then
            local seen = {}
            for index, spec in ipairs(fconf.checkboxes.states or {}) do
                if type(spec.char) ~= "string" or #spec.char ~= 1 then
                    health.error(("%s.checkboxes.states[%d].char must be exactly one character"):format(format, index))
                elseif seen[spec.char] then
                    health.warn(
                        ("%s.checkboxes.states[%d]: char %q appears twice — the first entry wins"):format(
                            format,
                            index,
                            spec.char
                        )
                    )
                else
                    seen[spec.char] = true
                end
                check_glyph(("%s.checkboxes.states[%d].icon"):format(format, index), spec.icon)
                if (config.highlights.checkboxes or {})[index] == nil then
                    health.warn(
                        ("%s.checkboxes.states[%d] has no highlights.checkboxes[%d] accent — falls back grey"):format(
                            format,
                            index,
                            index
                        )
                    )
                end
            end
        end

        -- ── blocks ──────────────────────────────────────────────────────────
        if fconf.code ~= nil and fconf.code.enabled then
            check_glyph(format .. ".code.icon", fconf.code.icon)
            if fconf.code.position ~= "left" and fconf.code.position ~= "center" and fconf.code.position ~= "right" then
                health.error(
                    ('%s.code.position must be "left", "center" or "right", got %s'):format(
                        format,
                        tostring(fconf.code.position)
                    )
                )
            end
            if fconf.code.icon_color ~= "accent" and fconf.code.icon_color ~= "devicon" then
                health.error(
                    ('%s.code.icon_color must be "accent" or "devicon", got %s'):format(
                        format,
                        tostring(fconf.code.icon_color)
                    )
                )
            end
            if fconf.code.fences == "hide" and fconf.code.position ~= "right" then
                health.info(
                    format
                        .. '.code.position applies to the fence line; with fences = "hide" the chip is always right-aligned on the first content row'
                )
            end
            if fconf.code.fences == "show" then
                local qs = queries.state[format]
                if qs ~= nil and qs.mode == "show" and qs.stripped > 0 then
                    health.ok(
                        ('%s.code.fences = "show": %d conceal_lines directive(s) stripped from the highlight query'):format(
                            format,
                            qs.stripped
                        )
                    )
                elseif qs ~= nil and qs.mode == "show" then
                    -- Not a defect: only markdown's shipped query hides the fence LINES. Nothing to
                    -- strip means nothing is owned, which is the quieter of the two good outcomes.
                    health.ok(
                        ('%s.code.fences = "show": its highlight query hides no lines — nothing to own'):format(
                            format
                        )
                    )
                else
                    health.warn(format .. '.code.fences = "show" but the query was never resolved (setup order?)', {
                        "setup() applies this per format; a format reaching here was skipped.",
                    })
                end
            elseif fconf.code.fences ~= "hide" then
                health.error(
                    ('%s.code.fences must be "show" or "hide", got %s'):format(format, tostring(fconf.code.fences))
                )
            end
            if pcall(require, "lvim-icons") then
                health.ok("lvim-icons found — the code chip carries the language's own devicon")
            else
                health.info("lvim-icons not found — the code chip uses the fallback icon")
            end
        end
        if fconf.quotes ~= nil and fconf.quotes.enabled then
            check_glyph(format .. ".quotes.border", fconf.quotes.border)
            if fconf.quotes.repeat_on_wrap then
                health.info(
                    format
                        .. ".quotes.repeat_on_wrap is ON — the border repeats on wrapped rows and paints "
                        .. "over each continuation row's first cell unless 'breakindent'/'showbreak' keep it free (measured)"
                )
            end
        end
        if fconf.tables ~= nil and fconf.tables.enabled then
            for name, glyph in pairs(fconf.tables.borders or {}) do
                check_glyph(("%s.tables.borders.%s"):format(format, name), glyph)
            end
            if type(fconf.tables.max_rows) ~= "number" or fconf.tables.max_rows < 1 then
                health.error(format .. ".tables.max_rows must be a positive number")
            end
            if type(fconf.tables.max_width) ~= "number" or fconf.tables.max_width < 10 then
                health.error(format .. ".tables.max_width must be a number of at least 10")
            end
            health.ok(
                ("%s.tables: box=%s head=%s, degrade beyond %d rows / %d cells wide (the box is all-or-nothing per table)"):format(
                    format,
                    tostring(fconf.tables.box),
                    tostring(fconf.tables.head),
                    fconf.tables.max_rows,
                    fconf.tables.max_width
                )
            )
        end
        if fconf.links ~= nil and fconf.links.enabled then
            check_glyph(format .. ".links.icons.auto", fconf.links.icons.auto)
            check_glyph(format .. ".links.icons.wiki", fconf.links.icons.wiki)
            check_glyph(format .. ".links.icons.embed", fconf.links.icons.embed)
        end
        if fconf.refdefs ~= nil and fconf.refdefs.enabled then
            check_glyph(format .. ".refdefs.icon", fconf.refdefs.icon)
        end
        if fconf.emoji ~= nil and fconf.emoji.enabled then
            local bad = {}
            for name, glyph in pairs(fconf.emoji.extra or {}) do
                if type(glyph) ~= "string" or fn.strchars(glyph) ~= 1 then
                    bad[#bad + 1] = name
                end
            end
            if #bad == 0 then
                health.ok(("%s.emoji: %d extra mapping(s)"):format(format, vim.tbl_count(fconf.emoji.extra or {})))
            else
                health.error(
                    ("%s.emoji.extra: %s must map to exactly ONE character (conceal cannot render more)"):format(
                        format,
                        table.concat(bad, ", ")
                    )
                )
            end
        end
        if fconf.callouts ~= nil and fconf.callouts.enabled then
            local keys = {}
            for index, t in ipairs(fconf.callouts.types or {}) do
                if type(t.key) ~= "string" or t.key == "" then
                    health.error(("%s.callouts.types[%d].key must be a non-empty string"):format(format, index))
                elseif keys[t.key:lower()] then
                    health.warn(
                        ("%s.callouts.types[%d]: key %q appears twice (matching is case-insensitive)"):format(
                            format,
                            index,
                            t.key
                        )
                    )
                else
                    keys[t.key:lower()] = true
                    check_glyph(("%s.callouts.types[%d].icon"):format(format, index), t.icon)
                    if (config.highlights.callouts or {})[t.key:lower()] == nil then
                        health.info(
                            ("%s.callouts.types[%d] (%s) has no highlights.callouts entry — falls back to the quote depth accent"):format(
                                format,
                                index,
                                t.key
                            )
                        )
                    end
                end
            end
        end
        ::next_format::
    end

    -- ── the palette ─────────────────────────────────────────────────────────
    health.start("lvim-render: colours")
    local ok_colors, colors = pcall(require, "lvim-utils.colors")
    if not ok_colors or type(colors) ~= "table" then
        health.error("lvim-utils.colors is unavailable; the groups cannot be derived from the palette")
        return
    end
    ---@param label string
    ---@param spec LvimRenderHighlightSpec
    local function check_spec(label, spec)
        if type(spec.group) == "string" and spec.group ~= "" then
            health.ok(("highlights.%s uses the existing group %q verbatim"):format(label, spec.group))
            return
        end
        if type(spec.accent) ~= "string" or colors[spec.accent] == nil then
            health.error(("highlights.%s.accent = %s is not a palette colour"):format(label, tostring(spec.accent)), {
                "Use a key of lvim-utils.colors (blue, yellow, orange, teal, …), never a hex literal.",
            })
        elseif spec.tint ~= nil and (type(spec.tint) ~= "number" or spec.tint < 0 or spec.tint > 1) then
            health.error(("highlights.%s.tint must be between 0 and 1"):format(label))
        else
            health.ok(("highlights.%s = %s"):format(label, spec.accent))
        end
    end
    for _, key in ipairs({
        "h1",
        "h2",
        "h3",
        "h4",
        "h5",
        "h6",
        "rule",
        "fold_info",
        "code",
        "code_label",
        "code_icon",
        "code_inline",
        "link",
    }) do
        check_spec(key, config.highlights[key] or {})
    end
    for depth, spec in ipairs(config.highlights.bullets or {}) do
        check_spec("bullets[" .. depth .. "]", spec)
    end
    for depth, spec in ipairs(config.highlights.quotes or {}) do
        check_spec("quotes[" .. depth .. "]", spec)
    end
    for index, spec in ipairs(config.highlights.checkboxes or {}) do
        check_spec("checkboxes[" .. index .. "]", spec)
    end
    for key, spec in pairs(config.highlights.callouts or {}) do
        check_spec("callouts." .. key, spec)
    end
end

return M
