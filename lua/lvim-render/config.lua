-- lvim-render.config: the LIVE config — setup() merges user options into this table IN PLACE
-- (lvim-utils.utils.merge), so every `require("lvim-render.config")` reader sees the effective
-- values and there is no second copy.
--
-- SHAPE: what is COMMON to every format lives at the top level (timing, gates, render/reveal/
-- conceal behaviour, folding, the palette mapping); everything a FORMAT owns lives in its own
-- block (`markdown = { … }`, later `org`, `typst`, …) — per the owner's instruction of
-- 2026-07-27. Folding is deliberately common: a heading must fold identically in every format.
--
-- Every glyph, timeout, format string, level and colour is an option: the plugin decorates the
-- user's own documents, and a decorator with hardcoded taste is one the user cannot live with.
-- The default bullets and the rule glyph are plain Unicode ON PURPOSE — they are the typography
-- of the rendered document itself, not UI chrome; the Nerd icons live where a SYMBOL is meant
-- (heading levels).
--
---@module "lvim-render.config"

---@class LvimRenderHeadingLevel
---@field icon string  the level glyph drawn before the title (Nerd Font, one cell; "" for none)
---@field pad integer  virtual indent cells before the icon, so deeper levels can step right

---@class LvimRenderHeadingsConfig
---@field enabled boolean
---@field band boolean            colour the whole heading line with the level's tinted band
---@field conceal_markers boolean hide the `#` markers (needs 'conceallevel' 2, which attach sets)
---@field text "accent"|"theme"  who colours the heading TEXT: "accent" (default) paints it with
---   the level's own colour — six visibly different headings whatever the theme does; "theme"
---   leaves the text to the colorscheme's own markup.heading groups and keeps only band + icon
---@field setext_underline string what a setext `===`/`---` underline row is redrawn with, repeated
---   to the underline's own width; "" leaves the raw underline characters as they are
---@field levels LvimRenderHeadingLevel[]  exactly six entries, H1 first

---@class LvimRenderEnumConfig
---@field enabled boolean  render a typst `+` item as its ORDINAL rather than as a bullet: `+` is
---   an auto-numbered enum, and drawing it as a dot throws away the one thing that distinguishes
---   it from `-`
---@field format string    the ordinal template; `{n}` is the item's position in its run

---@class LvimRenderListsConfig
---@field enabled boolean
---@field bullets string[]  the glyph per nesting depth; deeper lists cycle through the list again
---@field enum LvimRenderEnumConfig?  formats with an auto-numbered list marker (typst `+`)

---@class LvimRenderTermsConfig
---@field enabled boolean
---@field icon string  drawn over the `/` marker of a typst term item
---@field bold boolean  paint the term (the part before the `:`) bold

---@class LvimRenderRuleConfig
---@field enabled boolean
---@field glyph string  repeated across the window's text width in place of the `---` line
---@field icon string   centred in the drawn line (`─── ◆ ───`); "" for an unbroken line

---@class LvimRenderEmphasisConfig
---@field enabled boolean  conceal the `*`/`_`/`~~` delimiters; the styling itself is the
---   treesitter groups' job

---@class LvimRenderInlineCodeConfig
---@field enabled boolean
---@field pad string  what each backtick delimiter renders AS (one character, or "" to hide it):
---   " " gives the pill one padding cell each side at zero cost — the delimiter cell itself is
---   concealed TO the pad character, no virtual text involved

---@class LvimRenderLinksConfig
---@field enabled boolean
---@field icons { link: string, image: string, auto: string, wiki: string, embed: string }
---   rendered verbatim before the label (include a trailing space for a gap; "" for no icon):
---   inline/reference links, images, `<https://…>` autolinks, `[[wikilinks]]`, `![[embeds]]`
---@field conceal boolean  hide the brackets and the destination, keep the label

---@class LvimRenderEntitiesConfig
---@field enabled boolean
---@field extra table<string, string>  user additions/overrides, name → character (single char)

---@class LvimRenderCheckboxState
---@field char string  the character between the brackets (`[x]` → "x"); case-sensitive
---@field icon string  the single-cell glyph the whole `[c]` token renders as

---@class LvimRenderCheckboxesConfig
---@field enabled boolean
---@field states LvimRenderCheckboxState[]  matched in order; accents live in
---   `highlights.checkboxes` BY INDEX

---@class LvimRenderCodeBlockConfig
---@field enabled boolean
---@field band boolean   background band over the whole block (BACKGROUND-only, so the injected
---   language's own colours survive on top — §2a discipline)
---@field label boolean  language chip (devicon + language name)
---@field icon string    fallback chip glyph when lvim-icons is absent or has no icon for the
---   language
---@field fences "show"|"hide"  "show" (default) keeps the fence LINES visible — only the
---   backticks conceal and the chip sits at the line start; Neovim's own markdown query hides
---   those lines outright (`conceal_lines`), so "show" installs an amended highlight query with
---   just that directive stripped (the official `vim.treesitter.query.set` seam). "hide" keeps
---   the native behaviour, with the chip right-aligned on the first content row
---@field position "left"|"center"|"right"  where the chip sits ON THE FENCE LINE (fences =
---   "show"): "left" keeps the language text in place behind the inline icon; "center"/"right"
---   conceal the language text too and draw icon + name there. With fences = "hide" the chip is
---   always right-aligned on the first content row (anything else would cover code)
---@field icon_color "accent"|"devicon"  "accent" (default) paints the chip icon with
---   `highlights.code_icon` — one distinct colour everywhere; "devicon" uses the language's own
---   lvim-icons colour when available (accent as the fallback)

---@class LvimRenderQuotesConfig
---@field enabled boolean
---@field border string  the glyph each `>` marker is redrawn as (one cell)
---@field repeat_on_wrap boolean  repeat the border on WRAPPED rows of a quote line. Off by
---   default: the repeat paints over the first text cell of every continuation row (measured)
---   unless 'breakindent'/'showbreak' keep that column free — turn it on when yours do

---@class LvimRenderCalloutType
---@field key string    what follows `[!` — matched case-insensitively (`[!NOTE]`, `[!note]`)
---@field icon string   single-cell glyph
---@field label string  the title drawn instead of the raw `[!KEY]` token

---@class LvimRenderTableBorders
---@field horizontal string
---@field vertical string
---@field top_left string
---@field top_mid string
---@field top_right string
---@field mid_left string
---@field cross string
---@field mid_right string
---@field bottom_left string
---@field bottom_mid string
---@field bottom_right string

---@class LvimRenderTablesConfig
---@field enabled boolean
---@field max_rows integer   a table with more rows than this DEGRADES to styled pipes only —
---   the full box needs every cell measured, and a huge table must never own the redraw
---@field max_width integer  the assembled box wider than this (or than the window) degrades the
---   same way. THE RULE, stated: the box is all-or-nothing per table — columns size to the
---   WIDEST RENDERED CELL, and when that cannot fit, the whole table falls back to styled
---   borders aligned to the text as written. A silently broken box is never an outcome
---@field wrap_cells boolean  when the window WRAPS and the natural box is wider than it, shrink
---   the columns to fit and split every cell across as many lines as it then needs. The table is
---   drawn whole as virtual lines in that mode, so a wrapped cell can take the extra rows; the
---   source rows are hidden while it is. Off → such a table degrades to styled pipes as before
---@field box boolean        top and bottom border lines (virtual lines above/below the table)
---@field head boolean       tinted band over the header row
---@field min_col integer    the narrowest a column may be
---@field borders LvimRenderTableBorders

---@class LvimRenderCalloutsConfig
---@field enabled boolean
---@field types LvimRenderCalloutType[]  extendable; accents live in `highlights.callouts`
---   keyed by `key`, falling back to the quote depth accent when absent

---@class LvimRenderFoldTextConfig
---@field enabled boolean  render the collapsed line (icon + title + hidden-line count) instead of
---   Neovim's raw `+--` foldtext
---@field title string     the leading chunk, drawn in the heading level's own group: `{icon}`,
---   `{title}`
---@field info string      the trailing chunk, drawn in LvimRenderFoldInfo: `{count}` is the number
---   of hidden lines

---@class LvimRenderFoldKeysConfig
---@field cycle string|false      buffer-local key cycling the heading under the cursor through
---   collapsed → children shown → whole subtree; false takes no key at all
---@field cycle_all string|false  the same three states for the whole document (fold level
---   0 → 1 → everything)

---@class LvimRenderFoldConfig
---@field enabled boolean   own 'foldmethod'/'foldexpr'/'foldtext' while attached (the previous
---   window values are recorded and RESTORED on detach or :LvimRender off)
---@field headings boolean  a heading folds everything under it, down to the next heading of the
---   same or higher level
---@field tables boolean    a table folds as one region nested under its heading (opt-in)
---@field separate_sections boolean  keep the blank row(s) before a heading OUT of the fold above
---   them. Such a row is a SEPARATOR, not content of the section it ends: folded away with that
---   section it leaves the collapsed line and the next heading glued together with nothing
---   between them. It takes the enclosing subtree's level instead, so it still folds with the
---   parent — and 0 before a level-1 heading, where it belongs to no fold at all
---@field level integer     'foldlevel' applied on attach; the default keeps the document OPEN —
---   a renderer that collapses your file on load made a decision that was yours to make
---@field text LvimRenderFoldTextConfig
---@field keys LvimRenderFoldKeysConfig

---@class LvimRenderRevealConfig
---@field lines integer  how many lines around the cursor render RAW, beyond the cursor line
---   itself; an element (a setext heading, a table, a fenced block) touching the range reveals
---   WHOLE
---@field modes string[]  the modes in which the reveal applies at all (matched like
---   `render.modes`). Default insert/replace only: everywhere else the document stays fully
---   rendered, cursor line included
---@field quotes "element"|"row"  how a block quote (and a callout) reveals: "element" (default)
---   strips the WHOLE quote when the cursor enters it — one element, one reveal; "row" strips
---   only the edited row's border (the quieter choice for very long quotes)

---@class LvimRenderConcealConfig
---@field level integer   'conceallevel' applied to attached windows (2 hides the markers fully)
---@field cursor string   'concealcursor' likewise; "" reveals concealed text on the cursor line
---   in every mode, which is what makes editing under conceal unsurprising

---@class LvimRenderHighlightSpec
---@field group string?  use this EXISTING highlight group verbatim instead of building one —
---   every other field is then ignored; for wiring a level (or any slot) to your own group
---@field accent string  a palette colour NAME (lvim-utils.colors key), never a hex literal
---@field tint number?   blend factor toward the background for the cell behind the text
---@field bg boolean?    false paints the accent as a FOREGROUND only, no tinted cell
---@field fg boolean?    false paints NO foreground at all — a background-only band that can
---   never wash out the colours drawn on top of it (the §2a code-block discipline)
---@field bold boolean?
---@field italic boolean?
---@field underline boolean?
---@field strikethrough boolean?

---@class LvimRenderFormatConfig
---@field enabled boolean      this format renders at all
---@field filetypes string[]   buffers that carry it
---@field headings LvimRenderHeadingsConfig
---@field lists LvimRenderListsConfig
---@field rule LvimRenderRuleConfig?  absent where the format has no horizontal rule (typst)
---@field terms LvimRenderTermsConfig?  typst `/ Term: description`
---@field labels { enabled: boolean, icon: string, conceal: boolean }?  typst `<name>`
---@field refs { enabled: boolean, icon: string }?  typst `@name`
---@field emphasis LvimRenderEmphasisConfig?
---@field escapes { enabled: boolean }?
---@field mark { enabled: boolean }?
---@field emoji { enabled: boolean, extra: table<string, string> }?
---@field tags { enabled: boolean }?
---@field refdefs { enabled: boolean, icon: string }?
---@field frontmatter { enabled: boolean }?
---@field html { enabled: boolean }?
---@field inline_code LvimRenderInlineCodeConfig?
---@field links LvimRenderLinksConfig?
---@field entities LvimRenderEntitiesConfig?
---@field checkboxes LvimRenderCheckboxesConfig?
---@field code LvimRenderCodeBlockConfig?
---@field quotes LvimRenderQuotesConfig?
---@field callouts LvimRenderCalloutsConfig?
---@field tables LvimRenderTablesConfig?

---@class LvimRenderMathImageConfig
---@field enabled boolean    the EXPERIMENTAL kitty tier — the only part that spawns processes
---@field engine string      "pdflatex" | "xelatex" | "lualatex"
---@field converter string   "dvisvgm" | "dvipng" | "magick"
---@field dpi integer
---@field preamble string[]  extra \usepackage lines
---@field timeout integer    ms per compile
---@field cache { entries: integer, days: integer }
---@field conceal_source boolean  dim/hide the raw equation while the image shows

---@class LvimRenderMathConfig
---@field inline { enabled: boolean, maps: table }  `$…$` → unicode substitution
---@field block { enabled: boolean, label: string, band: boolean, maps: table }
---@field image LvimRenderMathImageConfig

---@class LvimRenderSplitConfig
---@field position "right"|"left"  which side the preview opens on
---@field width number             fraction of the columns (≤ 1) or an absolute cell count; 0 keeps
---   whatever `:vsplit` chose
---@field source "raw"|"rendered"  what the SOURCE window shows while the preview is open. "raw"
---   (default) switches the source buffer's rendering off for as long as the preview lives and
---   restores it on close — that split, raw beside rendered, is what a preview is FOR; "rendered"
---   leaves both sides decorated, which makes the preview a clone of the source
---@field winbar string          the preview window's own 'winbar', drawn only when the source
---   window carries one, so both sides start at the same height. Deliberately NOT a copy of the
---   source's: the plugin that owns that value excludes scratch buffers and clears its own string
---   back off, so a copy would not survive. "" draws none
---@field quiet_source boolean   while the preview is open, turn LSP codelens off for the source
---   BUFFER (restored on close, and only when this plugin was what turned it off). Its virtual
---   lines are not the file's own text and each one pushes the source a row out of step with the
---   preview
---@field focus "source"|"preview" where the cursor lands after opening. "source" by default: the
---   preview is for looking at, and you were in the middle of editing
---@field sync_scroll boolean      keep the preview's TOP line on the source's. Only the top line —
---   the two views render to different heights, so matching cursor lines would fight that
---@field debounce integer         ms of idle before the mirror is re-copied while typing
---@field win_options table<string, any>  window options applied to the preview window

---@class LvimRenderConfig
---@field enabled boolean        master switch — the global side of :LvimRender
---@field debounce integer       ms of idle before a reparse + outline rebuild after an edit
---@field max_file_size integer  bytes; a bigger buffer attaches INERT with a one-shot notice
---@field max_lines integer      lines; same gate, same behaviour
---@field render { modes: string[] }  modes in which decorations show at all, matched against
---   `nvim_get_mode()` exactly or by its first character; outside them the current window
---   renders raw
---@field reveal LvimRenderRevealConfig
---@field conceal LvimRenderConcealConfig
---@field split LvimRenderSplitConfig
---@field tables_editor { title: string, width: number, height: number, border: string[]|string, table_mode: boolean, keys: table<string, string|false> }
---   the full-screen table editor: its title, its size (fractions of the editor), and its own
---   buffer-local keys. The key that OPENS it is the reader's, through `:LvimRender table`
---@field tables_insert_opens_editor boolean  entering insert inside a boxed table opens the
---   full-screen editor instead of leaving the cursor's own row un-concealed underneath the box
---@field tables_box_reveal boolean  a table drawn as a BOX reveals on insert like every other
---   element. False by default: a boxed table is not edited in the buffer — its rows are hidden
---   and `:LvimRender table` is where its cells change — so the reveal would only break the view
---@field tables_nav_step_over boolean  j/k treat a boxed table as ONE stop, like a closed fold.
---   The alternative (walking its rows) cannot scroll into the table from beyond the window edge:
---   its rows are hidden, so the cursor-visibility rule has nothing to scroll to
---@field tables_nav_keys { down: string|false, up: string|false }  buffer-local motions that step
---   over a table separator row a box is hiding — the only buffer row inside a box that draws
---   nothing of its own
---@field tables_hide_cursor boolean  hide the hardware cursor while it stands inside a table drawn
---   as a box: those rows are hidden, so there is nothing for it to stand on, and the box paints
---   its own active row
---@field completion { enabled: boolean, priority: integer }  the lvim-cmp source for callout
---   types and checkbox states; ignored entirely when lvim-cmp is not installed
---@field priorities { band: integer, heading_text: integer }  extmark priorities per kind
---@field fold LvimRenderFoldConfig
---@field markdown LvimRenderFormatConfig
---@field org LvimRenderFormatConfig
---@field typst LvimRenderFormatConfig
---@field asciidoc LvimRenderFormatConfig
---@field latex LvimRenderFormatConfig
---@field math LvimRenderMathConfig  common — math is an element of markdown AND org, not a format
---@field highlights table<string, LvimRenderHighlightSpec|LvimRenderHighlightSpec[]>  the shared
---   palette mapping — common so every format reads the same H1 the same colour
local M = {
    enabled = true,
    debounce = 50,
    max_file_size = 2 * 1024 * 1024,
    max_lines = 20000,
    -- Every mode renders (matched exactly or by first character — "n" covers "no"/"niI"). The
    -- raw view is the REVEAL's job, not a whole-window mode gate: remove "i" here and insert
    -- mode goes entirely raw instead.
    render = { modes = { "n", "v", "V", "\22", "s", "S", "i", "R", "c", "t" } },
    -- Raw ONLY in insert/replace (the owner's rule): in every other mode the document stays
    -- fully rendered, cursor line included. While a reveal mode is active, the element under
    -- the cursor (± `lines`) is raw. This must AGREE with `conceal.cursor` below — health
    -- checks the two say the same thing per mode.
    reveal = { lines = 0, modes = { "i", "R" }, quotes = "element" },
    -- 'conceallevel'/'concealcursor' are window-local and USER-OWNED, exactly like the fold
    -- options: recorded on attach, re-asserted at the buffer-reenter reinit seam, restored on
    -- detach, and a fighting owner is reported by health — never silently tolerated.
    -- "nvc": conceal stays active at the cursor in normal/visual/cmdline; insert reveals it.
    conceal = { level = 2, cursor = "nvc" },
    -- The side-by-side preview (`:LvimRender split`). A MIRROR buffer, not the same buffer in two
    -- windows: inline virtual text and virtual lines cannot be ephemeral, so every icon and border
    -- is a real buffer extmark that every window showing that buffer draws — and window-scoped
    -- extmark namespaces do not exist in 0.12 or 0.13 (both probed). One buffer therefore cannot be
    -- raw on one side and rendered on the other; two buffers can.
    split = {
        position = "right",
        width = 0,
        -- What the SOURCE window shows while the preview is open. "raw" is the point of a split
        -- preview: one side is the text you edit, the other is what it becomes. Rendering both
        -- sides makes the preview a clone that shows nothing the source does not.
        source = "raw",
        -- The preview's own winbar, drawn only when the SOURCE window has one — chrome above the
        -- text decides where the text starts, and one row of difference between the two sides is
        -- exactly the misalignment it exists to avoid. Statusline syntax; "" draws none.
        winbar = "%#LvimRenderCodeLabel# %t",
        -- Suppress VIRTUAL LINES in the raw source while the preview is open — codelens
        -- ("1 reference" above a heading) is the common one. They are not the file's own text,
        -- and each one pushes the source down a row, which is exactly the misalignment the
        -- winbar above exists to avoid.
        quiet_source = true,
        focus = "source",
        sync_scroll = true,
        debounce = 120,
        win_options = { number = false, relativenumber = false, signcolumn = "no", cursorline = false },
    },
    -- The full-screen TABLE EDITOR (`:LvimRender table`). A table cannot be edited comfortably in
    -- the buffer under 'wrap' — concealed text still takes its width when a line wraps, so a row
    -- with links comes apart and no decoration can prevent it. The editor is a window of its own,
    -- with its own width and its own 'nowrap', so nothing there fights the reader's settings.
    tables_editor = {
        title = "󰓫  Table",
        width = 0.9,
        height = 0.8,
        -- NO RING. Eight cells, all blank by default: the grid is the shape, and a drawn frame
        -- around it competes with the box glyphs inside. The title still lands on the top edge —
        -- it is a native border-title, which needs a border to sit on but not a visible one.
        -- Any Neovim 'border' value works here: a list of eight cells, or a name like "rounded".
        border = { " ", " ", " ", " ", " ", " ", " ", " " },
        -- Turn lvim-table's TABLE MODE on in the editor's buffer when that sibling is installed: it
        -- realigns the block as you type, so the grid never drifts while a cell grows, and it adds
        -- its cell text objects and row/column operators on top. Optional — without it the editor's
        -- own `<C-a>` realign and structure keys do the same work by hand.
        table_mode = true,
        -- Buffer-local, only inside the editor. No <Leader> key opens it: the OPENING key belongs
        -- to the reader's own central keymap (`:LvimRender table` is the seam) — these are the
        -- editor's internal keys, which stay with the plugin that owns the window.
        keys = {
            commit = "<CR>",
            next_cell = "<Tab>",
            prev_cell = "<S-Tab>",
            row_add = "<C-r>",
            row_delete = "<C-d>",
            column_add = "<C-c>",
            column_delete = "<C-x>",
            realign = "<C-a>",
            -- The set's canonical cheatsheet key.
            help = "g?",
        },
    },
    -- Entering insert inside a table drawn as a BOX opens the EDITOR instead. 'concealcursor' is
    -- "nvc", so Neovim un-conceals the cursor's own line in insert and that one row would surface
    -- under the box, editable and detached from its table — while there is nothing to type into in
    -- place, since the rows are hidden by design. Set false to just enter insert (and see that row).
    tables_insert_opens_editor = true,
    -- Does a table drawn as a BOX reveal on insert, like every other element? NO by default: its
    -- rows are hidden and its cells are changed in the editor (`:LvimRender table`), so tearing
    -- the box apart on `i` would break the view for an edit that does not happen there. Set true
    -- to get the old behaviour — the table shown raw, in place, whenever you enter insert in it.
    tables_box_reveal = false,
    -- Does j/k treat a table drawn as a BOX as ONE stop, the way it treats a closed fold?
    --
    -- TRUE (default) — the cursor RESTS ON the table as one stop and `i` there opens the editor,
    -- exactly as a closed fold is one stop that `zo` opens. It never jumps over: a table you cannot
    -- put the cursor on is a table you cannot open. The alternative was
    -- tried and is structurally broken, not merely awkward: the box HIDES the table's rows, so they
    -- have no screen height, and Neovim's rule that the cursor stays visible then fights every
    -- scroll. Measured: CTRL-Y scrolls (topline 132→131→130) but drags the cursor with it
    -- (136→135→134); `winrestview` does not move at all, because the view snaps back to the
    -- nearest thing it can show — which left `k` unable to scroll up out of a table entirely.
    --
    -- FALSE — the cursor walks the rows one by one and the box paints the row it is on, which
    -- reads nicely as long as the whole table is already on screen; approach one from beyond the
    -- window's edge and the view will stick, for the reason above.
    tables_nav_step_over = true,
    -- j/k inside an attached buffer STEP OVER a table separator row that a box is hiding: the box
    -- draws its own junction line, so the source's `|---|---|` shows nothing of its own and
    -- stopping on it is a stop for nothing. Set either to false to leave that key alone.
    tables_nav_keys = { down = "j", up = "k" },
    -- The hardware cursor inside a table drawn as a BOX. Its rows are hidden, so the cursor has
    -- nothing to stand on there and would sit in a blank column while the box paints the active
    -- row itself. Hidden through lvim-utils' own cursor registry, never a hand-rolled 'guicursor'.
    tables_hide_cursor = true,
    -- Callout types and checkbox states are configurable sets, which makes them the two things no
    -- other completion source can know: an LSP has never heard of a type someone added to their
    -- own config. Registered with lvim-cmp when it is there, silent when it is not.
    completion = { enabled = true, priority = 40 },
    -- Extmark priorities. `band` sits BELOW the syntax/treesitter layers (50/100) so a band's
    -- background can never wash out foreground colours; `heading_text` sits ABOVE treesitter and
    -- is what `headings.text = "accent"` paints the title with.
    priorities = { band = 10, heading_text = 110 },
    fold = {
        enabled = true,
        headings = true,
        tables = false,
        -- Keep the blank line(s) between two sections OUT of the fold above them. Such a row is a
        -- separator, not content: folded away with the section, it leaves the collapsed line and
        -- the next heading glued together with nothing between them.
        separate_sections = true,
        level = 99,
        text = {
            enabled = true,
            title = "{icon} {title}",
            -- `➤` per the separator canon: the collapsed heading POINTS at what it hides.
            info = " ➤ {count} lines ",
            -- The count box is the level's OWN accent blended harder than its band, so it reads
            -- as a box on the line rather than as more line. The whole row rises to this tint
            -- while the cursor is on it — the two then match exactly (the tint canon's active
            -- row). The band's own tint stays the level's, in `highlights.h<n>`.
            count_tint = 0.4,
        },
        keys = { cycle = "<Tab>", cycle_all = "<S-Tab>" },
    },
    markdown = {
        enabled = true,
        filetypes = { "markdown" },
        headings = {
            enabled = true,
            band = true,
            conceal_markers = true,
            text = "accent",
            setext_underline = "─",
            -- nf-md-format_header_1..6 (U+F026B–U+F0270), each verified one cell.
            levels = {
                { icon = "󰉫", pad = 1 },
                { icon = "󰉬", pad = 2 },
                { icon = "󰉭", pad = 3 },
                { icon = "󰉮", pad = 4 },
                { icon = "󰉯", pad = 5 },
                { icon = "󰉰", pad = 6 },
            },
        },
        lists = {
            enabled = true,
            bullets = { "●", "○", "◆", "◇" },
        },
        rule = {
            enabled = true,
            glyph = "─",
            -- Centred in the line; deliberately the same plain-Unicode family as the bullets —
            -- document typography, not UI chrome. Any single-cell glyph works.
            icon = "◆",
        },
        emphasis = { enabled = true },
        inline_code = { enabled = true, pad = " " },
        links = {
            enabled = true,
            -- nf-md-link (U+F0337) / nf-md-image (U+F02E9), one cell each; the trailing space is
            -- part of the value on purpose — the gap is yours to keep or drop.
            icons = {
                link = "󰌷 ",
                image = "󰋩 ",
                -- nf-md-web / nf-md-link_box_variant / the image glyph again for embeds.
                auto = "󰖟 ",
                wiki = "󰌹 ",
                embed = "󰋩 ",
            },
            conceal = true,
        },
        entities = { enabled = true, extra = {} },
        checkboxes = {
            enabled = true,
            -- nf-md checkbox glyphs, one cell each; accents in highlights.checkboxes by index.
            states = {
                { char = " ", icon = "󰄱" },
                { char = "x", icon = "󰄲" },
                { char = "X", icon = "󰄲" },
                { char = "-", icon = "󰡖" },
                { char = "~", icon = "󰅗" },
            },
        },
        code = {
            enabled = true,
            band = true,
            label = true,
            -- nf-md-code_braces fallback when lvim-icons is absent for the language.
            icon = "󰅩",
            fences = "show",
            position = "left",
            icon_color = "accent",
        },
        quotes = {
            enabled = true,
            border = "▍",
            repeat_on_wrap = false,
        },
        -- `\*` → `*`: the backslash conceals, the character shows plain.
        escapes = { enabled = true },
        -- `==text==` → a highlighter-pen span; the markers conceal.
        mark = { enabled = true },
        -- `:smile:` → 😄. The user's OWN emoji rendered faithfully (data/emoji.lua — the common
        -- single-codepoint gemoji names; `extra` adds/overrides, one character per name).
        emoji = { enabled = true, extra = {} },
        -- `#tag` accenting. OFF by default: the token collides with plain prose too easily; the
        -- needs-checking row resolved as opt-in (see the work log).
        tags = { enabled = false },
        -- `[id]: url` reference definitions: an icon marks the line; the text stays readable.
        refdefs = { enabled = true, icon = "󰌷 " },
        -- `---`/`+++` frontmatter: a background band under the injected yaml/toml colours.
        frontmatter = { enabled = true },
        -- Basic HTML tags (<b>/<i>/<u>/<s>/<mark>…): tags conceal, the span takes the attribute.
        -- An unpaired or non-basic tag stays raw.
        html = { enabled = true },
        tables = {
            enabled = true,
            max_rows = 400,
            max_width = 200,
            box = true,
            head = true,
            -- ON by default, because under 'wrap' it is the only thing that WORKS — measured:
            -- CONCEALED TEXT STILL TAKES ITS WIDTH WHEN A LINE WRAPS. A 52-column line whose
            -- visible form is 10 columns still occupies two screen rows in a 40-column window. A
            -- markdown table row with links is two to three times longer raw than rendered, so
            -- Neovim wraps it by the RAW length and the columns come apart — and no decoration can
            -- prevent that, because a decoration cannot shorten a line. The only two answers are
            -- 'nowrap', or hiding the source rows outright and drawing the table as virtual lines.
            -- This is the second.
            --
            -- ITS COSTS, equally measured, since they are real: the box is ONE block of virtual
            -- lines hanging off the row above the table (virtual lines do not draw on a
            -- `conceal_lines` row), so it can only be drawn while the WHOLE table is on screen —
            -- it pops in and out as you scroll past, scrolling THROUGH it is one jump rather than
            -- line by line, and a table taller than the window gets nothing at all. Those are the
            -- price of a table that is readable instead of broken; the full-screen table editor is
            -- the answer for the ones this cannot serve.
            wrap_cells = true,
            min_col = 3,
            borders = {
                horizontal = "─",
                vertical = "│",
                top_left = "┌",
                top_mid = "┬",
                top_right = "┐",
                mid_left = "├",
                cross = "┼",
                mid_right = "┤",
                bottom_left = "└",
                bottom_mid = "┴",
                bottom_right = "┘",
            },
        },
        callouts = {
            enabled = true,
            types = {
                { key = "note", icon = "󰋽", label = "Note" },
                { key = "tip", icon = "󰌶", label = "Tip" },
                { key = "important", icon = "󰅾", label = "Important" },
                { key = "warning", icon = "󰀪", label = "Warning" },
                { key = "caution", icon = "󰳦", label = "Caution" },
            },
        },
    },
    -- The org renderer lands with its phase (it waits on the org grammar reaching lvim-pkg); the
    -- config surface is fixed NOW so nothing moves later. Until then org buffers attach inert and
    -- health says why.
    org = {
        enabled = true,
        filetypes = { "org" },
        headings = {
            enabled = true,
            band = true,
            -- The `*` run: concealed like markdown's `#` run, its trailing space kept as the gap.
            conceal_markers = true,
            text = "accent",
            -- Org has no setext form; the key stays for shape parity and draws nothing.
            setext_underline = "",
            levels = {
                { icon = "󰉫", pad = 1 },
                { icon = "󰉬", pad = 2 },
                { icon = "󰉭", pad = 3 },
                { icon = "󰉮", pad = 4 },
                { icon = "󰉯", pad = 5 },
                { icon = "󰉰", pad = 6 },
            },
        },
        lists = {
            enabled = true,
            bullets = { "●", "○", "◆", "◇" },
        },
        checkboxes = {
            enabled = true,
            -- Org writes its states inside the same `[c]` token markdown does, so the state set is
            -- the same shape — `X` is org's own spelling of a ticked box.
            states = {
                { char = " ", icon = "󰄱" },
                { char = "X", icon = "󰄲" },
                { char = "x", icon = "󰄲" },
                { char = "-", icon = "󰡖" },
            },
        },
        -- `*bold*`, `/italic/`, `_underline_`, `+strike+`: the delimiters conceal ONLY when a
        -- pair is found (a lone `*` is multiplication, not emphasis).
        emphasis = { enabled = true },
        -- `=verbatim=` and `~code~` — org's two inline-code spellings.
        inline_code = { enabled = true, pad = " " },
        code = {
            enabled = true,
            band = true,
            label = true,
            icon = "󰅩",
            fences = "show",
            position = "left",
            icon_color = "accent",
        },
        -- `#+begin_quote` … `#+end_quote`: the border rides the CONTENT rows, not the markers.
        quotes = { enabled = true, border = "▍", repeat_on_wrap = false },
        links = {
            enabled = true,
            -- `[[target][label]]` keeps the label behind the icon; `[[target]]` keeps the target.
            icons = { link = "󰌷 ", image = "󰋩 ", auto = "󰖟 ", wiki = "󰌹 ", embed = "󰋩 " },
            conceal = true,
        },
        -- `:PROPERTIES:` drawers and `#+TITLE:`-style directives: a background band, the same
        -- treatment markdown gives frontmatter — metadata, present but visually quiet.
        frontmatter = { enabled = true },
    },
    -- Typst: same shape, renderer lands at its phase (the grammar is already in the registry).
    typst = {
        enabled = true,
        filetypes = { "typst" },
        headings = {
            enabled = true,
            band = true,
            conceal_markers = true,
            text = "accent",
            -- Typst has no setext heading form; the key stays for shape parity and draws nothing.
            setext_underline = "",
            levels = {
                { icon = "󰉫", pad = 1 },
                { icon = "󰉬", pad = 2 },
                { icon = "󰉭", pad = 3 },
                { icon = "󰉮", pad = 4 },
                { icon = "󰉯", pad = 5 },
                { icon = "󰉰", pad = 6 },
            },
        },
        lists = {
            enabled = true,
            bullets = { "●", "○", "◆", "◇" },
            -- `+` is typst's AUTO-NUMBERED marker. Drawing it as a dot would erase the one thing
            -- that distinguishes it from `-`, so it renders as its position in the run instead.
            enum = { enabled = true, format = "{n}." },
        },
        -- `/ Term: description` — typst's definition list.
        terms = { enabled = true, icon = "◆", bold = true },
        emphasis = { enabled = true },
        inline_code = { enabled = true, pad = " " },
        code = {
            enabled = true,
            band = true,
            label = true,
            icon = "󰅩",
            fences = "show",
            position = "left",
            icon_color = "accent",
        },
        links = {
            enabled = true,
            -- Only a BARE url is a link element in typst; `#link(…)` is a function call and stays
            -- code. The other icon slots exist for shape parity with the markdown block.
            icons = { link = "󰌷 ", image = "󰋩 ", auto = "󰖟 ", wiki = "󰌹 ", embed = "󰋩 " },
            conceal = true,
        },
        -- `<name>` — a typst label. nf-md-tag; the angle brackets conceal behind it.
        labels = { enabled = true, icon = "󰓹 ", conceal = true },
        -- `@name` — a reference to a label. The `@` itself becomes the icon.
        refs = { enabled = true, icon = "󰌹 " },
        -- `\#` → `#`: the backslash conceals, the character shows plain.
        escapes = { enabled = true },
    },
    -- AsciiDoc: inert until its grammar is reachable (it is absent from the parser registry);
    -- health reports the blocked state truthfully.
    asciidoc = {
        enabled = true,
        filetypes = { "asciidoc" },
        headings = {
            enabled = true,
            band = true,
            conceal_markers = true,
            text = "accent",
            setext_underline = "",
            levels = {
                { icon = "󰉫", pad = 0 },
                { icon = "󰉬", pad = 0 },
                { icon = "󰉭", pad = 0 },
                { icon = "󰉮", pad = 0 },
                { icon = "󰉯", pad = 0 },
                { icon = "󰉰", pad = 0 },
            },
        },
        lists = {
            enabled = true,
            bullets = { "●", "○", "◆", "◇" },
        },
        rule = {
            enabled = true,
            glyph = "─",
            icon = "◆",
        },
    },
    -- Standalone .tex buffers are lvim-tex's conceal domain: OFF by default, explicit opt-in only,
    -- documented as a double-decoration risk. LaTeX MATH inside markdown/org is `math` below.
    latex = {
        enabled = false,
        filetypes = { "tex" },
        headings = {
            enabled = false,
            band = false,
            conceal_markers = false,
            text = "accent",
            setext_underline = "",
            levels = {
                { icon = "󰉫", pad = 0 },
                { icon = "󰉬", pad = 0 },
                { icon = "󰉭", pad = 0 },
                { icon = "󰉮", pad = 0 },
                { icon = "󰉯", pad = 0 },
                { icon = "󰉰", pad = 0 },
            },
        },
        lists = {
            enabled = false,
            bullets = { "●", "○", "◆", "◇" },
        },
        rule = {
            enabled = false,
            glyph = "─",
            icon = "◆",
        },
    },
    -- Math is COMMON, not a format: `$…$` / `$$…$$` appear inside markdown and org alike. The
    -- unicode substitution lands at its phase; `image` is the experimental kitty tier — the only
    -- part of the plugin that spawns processes, and off until asked for.
    math = {
        inline = { enabled = true, maps = {} },
        block = { enabled = true, label = "math", band = true, maps = {} },
        image = {
            enabled = false,
            engine = "pdflatex",
            converter = "dvisvgm",
            dpi = 220,
            preamble = {},
            timeout = 5000,
            cache = { entries = 500, days = 30 },
            conceal_source = true,
        },
    },
    highlights = {
        h1 = { accent = "blue", tint = 0.2, bold = true },
        h2 = { accent = "teal", tint = 0.2, bold = true },
        h3 = { accent = "green", tint = 0.2, bold = true },
        h4 = { accent = "yellow", tint = 0.2, bold = true },
        h5 = { accent = "orange", tint = 0.2, bold = true },
        h6 = { accent = "magenta", tint = 0.2, bold = true },
        -- One spec per nesting depth, cycled like the glyphs; fg-only, because a coloured cell
        -- behind a single bullet reads as a smudge.
        bullets = {
            { accent = "blue", bg = false },
            { accent = "yellow", bg = false },
            { accent = "green", bg = false },
            { accent = "orange", bg = false },
        },
        -- The rule line carries COLOUR (owner's rule): line and icon each their own accent.
        rule = { accent = "blue", bg = false },
        rule_icon = { accent = "orange", bg = false },
        fold_info = { accent = "comment", bg = false },
        -- Code-block band: BACKGROUND only (`fg = false`), so the injected language's own
        -- foreground colours are never touched — the §2a invariant, enforced by construction.
        -- `bg_dark` at full tint = the palette's own darker surface (the panel canon), darker
        -- than the editor background.
        code = { accent = "bg_dark", tint = 1, fg = false },
        code_label = { accent = "blue", bg = false },
        code_icon = { accent = "orange", bg = false },
        -- The inline-code pill: background only, the treesitter raw-text colour stays.
        code_inline = { accent = "yellow", tint = 0.15, fg = false },
        link = { accent = "blue", bg = false },
        -- A typst term (`/ Term: …`): the defined word, foreground-only and bold, so the two
        -- halves of the row read apart without a band behind either.
        term = { accent = "teal", bg = false, bold = true },
        table_border = { accent = "blue", bg = false },
        table_head = { accent = "blue", tint = 0.2, bold = true },
        -- The header row while the CURSOR is on it: the same accent, blended harder. A header is
        -- already a coloured band, so replacing it with the editor's CursorLine would swap its
        -- colour instead of marking it — the tint canon says the active row raises its OWN accent.
        table_head_cursor = { accent = "blue", tint = 0.4, bold = true },
        -- Math: band background-only (the ceiling text stays readable), label + substituted
        -- symbols each their own accent.
        math = { accent = "bg_dark", tint = 1, fg = false },
        math_label = { accent = "purple", bg = false },
        math_symbol = { accent = "teal", bg = false },
        mark = { accent = "yellow", tint = 0.35, fg = false },
        tag = { accent = "cyan", tint = 0.2 },
        metadata = { accent = "bg_dark", tint = 1, fg = false },
        -- The basic-HTML attribute groups: pure text attributes, no colours of their own.
        html_bold = { fg = false, bg = false, bold = true },
        html_italic = { fg = false, bg = false, italic = true },
        html_underline = { fg = false, bg = false, underline = true },
        html_strike = { fg = false, bg = false, strikethrough = true },
        -- One spec per quote nesting depth, cycled when deeper.
        quotes = {
            { accent = "blue", bg = false },
            { accent = "yellow", bg = false },
            { accent = "green", bg = false },
        },
        -- By INDEX into markdown.checkboxes.states.
        checkboxes = {
            { accent = "blue", bg = false },
            { accent = "green", bg = false },
            { accent = "green", bg = false },
            { accent = "yellow", bg = false },
            { accent = "red", bg = false },
        },
        -- By callout KEY; a type without an entry falls back to the quote depth accent.
        callouts = {
            note = { accent = "blue", bg = false, bold = true },
            tip = { accent = "teal", bg = false, bold = true },
            important = { accent = "purple", bg = false, bold = true },
            warning = { accent = "yellow", bg = false, bold = true },
            caution = { accent = "red", bg = false, bold = true },
        },
    },
}

return M
