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
---@field icon_gap integer?  spaces drawn AFTER the level icon. A format whose marker leaves its
---   own trailing space on screen needs none (markdown's `## `, org's `** `); LaTeX's braces
---   conceal to nothing, so without it the title starts against the glyph
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
---@field conceal_environment boolean?  LaTeX: hide the `\begin{…}` / `\end{…}` rows of a list
---@field environments table<string, boolean>?  LaTeX: which environments count as lists, for the
---   nesting depth and for the concealed delimiter rows

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
---@field commands table<string, string>?  LaTeX: command → the style its argument is drawn in
---   (`\textbf` → "bold"); a command not named here is left exactly as written

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
---@field header boolean   draw the opening fence as a full-width band carrying the chip (needs
---   `fences = "show"` — a `conceal_lines`-hidden row cannot be drawn on)
---@field air integer      blank rows between the band and the first line of code
---@field pad integer      spaces of inset left and right of the code, on the CODE rows only
---@field width "full"|"content"  how wide the BODY is drawn: to the window edge, or a box as wide
---   as the longest line plus the padding (the header stays full width either way)
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
---@field info string      the count chunk, drawn in the level's STRONG tint: `{count}` is the
---   number of hidden lines
---@field position "right"|"left"  which end of the collapsed row the count box sits at
---@field count_tint number  blend of the level's accent toward the background for the count box
---   (and for the whole fold line while the cursor is on it)

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

---@class LvimRenderWinOptions  filetype (or "*") -> { option name -> value }; window-local
---   options this plugin owns while it renders that filetype, restored when it stops

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
---@field language string?     THE GRAMMAR'S NAME, when it is not the filetype's (latex); absent
---   where the filetype already names the parser
---@field headings LvimRenderHeadingsConfig
---@field lists LvimRenderListsConfig
---@field rule LvimRenderRuleConfig?  absent where the format has no horizontal rule (typst)
---@field terms LvimRenderTermsConfig?  typst `/ Term: description`
---@field labels { enabled: boolean, icon: string, conceal: boolean }?  typst `<name>`
---@field refs { enabled: boolean, icon: string }?  typst `@name`
---@field citations { enabled: boolean, icon: string }?  LaTeX `\cite{key}`
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
---@field typst_aliases table<string, string>  typst symbol name → the LaTeX command carrying the
---   same glyph, so the shared LaTeX-keyed maps answer for typst too

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
---@field win_options LvimRenderWinOptions
---@field split LvimRenderSplitConfig
---@field tables_editor { title: string, width: number, height: number, border: string[]|string, table_mode: boolean, keys: table<string, string|false> }
---   the full-screen table editor: its title, its size (fractions of the editor), and its own
---   buffer-local keys. The key that OPENS it is the reader's, through `:LvimRender table`
---@field tables_insert_opens_editor boolean  entering insert inside a boxed table opens the
---   full-screen editor instead of leaving the cursor's own row un-concealed underneath the box
---@field tables_box_reveal boolean  a table drawn as a BOX reveals on insert like every other
---   element. False by default: a boxed table is not edited in the buffer — its rows are hidden
---   and `:LvimRender table` is where its cells change — so the reveal would only break the view
---@field tables_nav_mode "widget"|"stop"|"raw"  how j/k treat a table drawn as a box: walk its rows
---   with a plugin-owned index while the cursor parks on the nearest displayed row — above the
---   table entering from above, below it entering from below ("widget"),
---   treat the whole table as one stop the cursor rests on ("stop"), or leave j/k alone ("raw" —
---   the cursor then lands on hidden rows and Neovim scrolls the whole block into view natively)
---@field tables_nav_keys { down: string|false, up: string|false }  the buffer-local motions that
---   implement the nav mode. They PREDICT their landing row (honouring closed folds) and run the
---   native motion untouched whenever it lands outside a boxed table — the cursor never touches a
---   hidden row, which is what keeps the view from jumping
---@field tables_nav_wheel boolean  step the mouse wheel over boxed tables through the plugin's own
---   view model (buffer-local <ScrollWheelDown>/<ScrollWheelUp>, honouring 'mousescroll'): Neovim
---   cannot scroll DOWN one line at a time over a box's hidden rows — a notch snaps past the whole
---   table (12-20 lines instead of 3, measured). A window under the mouse pointer that is not the
---   current one gets the native scroll untouched
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
---@field latex LvimRenderFormatConfig
---@field math LvimRenderMathConfig  common — math is an element of markdown AND org, not a format
---@field highlights table<string, LvimRenderHighlightSpec|LvimRenderHighlightSpec[]>  the shared
---   palette mapping — common so every format reads the same H1 the same colour
---@field floats { enabled: boolean, header: boolean }  rendering inside FLOATING windows (LSP hover
---   and friends): whether to render at all, and whether a code block draws its header band there
local M = {
    enabled = true,
    -- BUFFERS IN A FLOATING WINDOW — an LSP hover, a peek, a documentation popup. Neovim's own
    -- `vim.lsp.util.open_floating_preview` gives its scratch buffer `filetype = markdown`, so the
    -- renderer reaches those popups whether or not it was meant to.
    floats = {
        -- Render there at all. A hover of documentation IS markdown and reads better rendered.
        enabled = true,
        -- The code block's HEADER BAND (and its language chip) inside a float. Off: a full-width
        -- band carrying a chip is chrome, and chrome inside someone else's popup reads as ours
        -- intruding on theirs — the block itself still gets its background, its padding and its
        -- injected syntax. Everything else about the block follows the format's own `code` config.
        header = false,
    },
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
    -- WINDOW OPTIONS THIS PLUGIN OWNS while a window shows a rendered buffer — the same contract
    -- as `conceal` above: recorded on attach, re-asserted at the buffer-reenter seam, and put back
    -- exactly as they were when rendering stops or the buffer is detached. This is where a
    -- rendered document gets window chrome of its own: a decorated document is a page, and the
    -- rulers that help while writing code (the column marker, the cursor's own column) are noise
    -- across a table's box or a heading band.
    --
    -- `["*"]` applies to EVERY rendered filetype; a filetype key adds to it and wins on a clash.
    -- Any window-local option name is accepted, so this list is meant to be edited — add what a
    -- document should look like, or set it to `{}` and nothing here is touched at all.
    -- EMPTY BY DEFAULT: this plugin renders a document, it does not have opinions about the
    -- reader's window chrome. Fill it in the host config, e.g.
    --   win_options = {
    --       ["*"] = { colorcolumn = "", cursorcolumn = false },  -- no rulers across a document
    --       markdown = { linebreak = true },
    --   }
    win_options = {},
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
            -- Closing without writing anything back. Mapped by the EDITOR onto its own buffer: the
            -- panel hosts this module's buffer, so a key the chassis binds to its own never reaches
            -- it, and the footer's `q` was a button nobody could press.
            cancel = "q",
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
    -- How j/k treat a table drawn as a BOX. Its rows are HIDDEN — that is what lets it fit a
    -- wrapping window at all — and a hidden row has no screen position, so Neovim can neither put
    -- a visible cursor on it nor scroll to it. Measured, then confirmed independently: there is no
    -- mapping between a cursor's buffer row, its screen row inside another extmark's `virt_lines`,
    -- and the window's topline; CTRL-Y scrolls but drags the cursor, and `winrestview` normalises a
    -- topline inside the hidden run away. Three honest answers, none of them a cursor walking
    -- hidden lines:
    --
    --   "widget" (default) — the real cursor parks on the DISPLAYED row above the table and j/k
    --     move a logical row index inside the box, which repaints with that row active. Walking the
    --     table row by row, without ever asking the view to scroll to a zero-height line. Leaving
    --     either end hands the cursor back to the buffer. The view never jumps: a box that does
    --     not fit under the parked row pages inside itself, the page following the active row,
    --     and each step down slides the view one line — as `j` does at the bottom of a window.
    --   "stop"   — the table is ONE stop the cursor rests on (the displayed row the box hangs
    --     from), like a closed fold's line; `i` opens the editor from there and the next `j`
    --     crosses the table whole.
    --   "raw"    — no special handling: j/k are Neovim's own, and a cursor landing on a hidden
    --     row makes Neovim scroll the whole block into view natively.
    tables_nav_mode = "widget",
    -- The buffer-local motions that implement the mode above. They PREDICT their landing row
    -- (honouring closed folds) and run the native motion untouched whenever it lands outside a
    -- boxed table — the cursor never touches a hidden row, which is what keeps the view from
    -- jumping. Set either to false to leave that key alone.
    tables_nav_keys = { down = "j", up = "k" },
    -- The mouse wheel over boxed tables, stepped through the plugin's own view model
    -- (buffer-local wheel mappings, 'mousescroll' rows per notch): Neovim cannot scroll DOWN one
    -- line at a time over a box's hidden rows — a native notch snaps past the whole table. A
    -- window under the pointer that is not the current one keeps the native scroll.
    tables_nav_wheel = true,
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
            -- Where the count box sits on the collapsed row: "right" (the far end, in line with
            -- the other right-hand chrome) or "left" (straight after the title).
            position = "right",
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
            -- WHERE THE CHIP SITS ON THE HEADER BAND: "left" | "center" | "right".
            position = "right",
            -- "devicon" takes the language's colour from the ICON plugin — the glyph and the
            -- chip's tint both come from there, so a code block is the same colour the file type
            -- is everywhere else in the editor. "accent" uses this plugin's own single colour.
            icon_color = "devicon",
            -- THE OPENING FENCE AS A BAND. Its text is concealed anyway, so the row is free: it
            -- becomes a full-width strip carrying the language chip. Needs `fences = "show"` —
            -- with "hide" the row is removed from the display and nothing can be drawn on it.
            header = true,
            -- Blank rows between the band and the first line of code — the same "air" the framed
            -- windows put under a title.
            air = 1,
            -- Spaces of inset left and right of the code, on the CODE rows only: the band is the
            -- chrome, the code should not touch its edge.
            pad = 2,
            -- How wide the BODY is drawn: "full" reaches the window edge like the header above it,
            -- "content" narrows it to a box as wide as the longest line plus the padding.
            width = "full",
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
            -- WHERE THE CHIP SITS ON THE HEADER BAND: "left" | "center" | "right".
            position = "right",
            -- "devicon" takes the language's colour from the ICON plugin — the glyph and the
            -- chip's tint both come from there, so a code block is the same colour the file type
            -- is everywhere else in the editor. "accent" uses this plugin's own single colour.
            icon_color = "devicon",
            -- THE OPENING FENCE AS A BAND. Its text is concealed anyway, so the row is free: it
            -- becomes a full-width strip carrying the language chip. Needs `fences = "show"` —
            -- with "hide" the row is removed from the display and nothing can be drawn on it.
            header = true,
            -- Blank rows between the band and the first line of code — the same "air" the framed
            -- windows put under a title.
            air = 1,
            -- Spaces of inset left and right of the code, on the CODE rows only: the band is the
            -- chrome, the code should not touch its edge.
            pad = 2,
            -- How wide the BODY is drawn: "full" reaches the window edge like the header above it,
            -- "content" narrows it to a box as wide as the longest line plus the padding.
            width = "full",
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
            -- WHERE THE CHIP SITS ON THE HEADER BAND: "left" | "center" | "right".
            position = "right",
            -- "devicon" takes the language's colour from the ICON plugin — the glyph and the
            -- chip's tint both come from there, so a code block is the same colour the file type
            -- is everywhere else in the editor. "accent" uses this plugin's own single colour.
            icon_color = "devicon",
            -- THE OPENING FENCE AS A BAND. Its text is concealed anyway, so the row is free: it
            -- becomes a full-width strip carrying the language chip. Needs `fences = "show"` —
            -- with "hide" the row is removed from the display and nothing can be drawn on it.
            header = true,
            -- Blank rows between the band and the first line of code — the same "air" the framed
            -- windows put under a title.
            air = 1,
            -- Spaces of inset left and right of the code, on the CODE rows only: the band is the
            -- chrome, the code should not touch its edge.
            pad = 2,
            -- How wide the BODY is drawn: "full" reaches the window edge like the header above it,
            -- "content" narrows it to a box as wide as the longest line plus the padding.
            width = "full",
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
    latex = {
        enabled = true,
        filetypes = { "tex", "latex", "plaintex" },
        -- THE GRAMMAR'S NAME, when it is not the filetype's. Neovim resolves a buffer's parser
        -- from its filetype, and nothing in the runtime says that a `tex` buffer is parsed by the
        -- `latex` grammar — so the query compiled against "tex", found no such language, and the
        -- whole format rendered nothing at all. Declared here and registered by `setup()`, which
        -- also makes plain `vim.treesitter.start` work in a .tex buffer for everyone else.
        language = "latex",
        headings = {
            enabled = true,
            band = true,
            conceal_markers = true,
            text = "accent",
            -- `\\section{Title}` conceals to NOTHING — command and braces alike — so the icon has
            -- no marker space to sit against and needs a gap of its own. The other formats leave
            -- their marker's trailing space on screen and inherit theirs.
            icon_gap = 1,
            -- LaTeX has no underlined heading form; the key stays for shape parity.
            setext_underline = "",
            levels = {
                { icon = "󰉫", pad = 1 },
                { icon = "󰉬", pad = 1 },
                { icon = "󰉭", pad = 1 },
                { icon = "󰉮", pad = 1 },
                { icon = "󰉯", pad = 1 },
                { icon = "󰉰", pad = 1 },
            },
        },
        lists = {
            enabled = true,
            bullets = { "●", "○", "◆", "◇" },
            -- `enumerate` numbers its items, and LaTeX writes no number in the source at all —
            -- so the marker renders as the item's position in its environment.
            enum = { enabled = true, format = "{n}." },
            -- The `\\begin{itemize}` / `\\end{itemize}` ROWS are the environment's punctuation, not
            -- its content: hidden, a LaTeX list reads like a list in every other format. Off
            -- leaves them on screen.
            conceal_environment = true,
            -- Which environments count as lists — for the nesting DEPTH and for the rows above.
            -- `document` and `center` are environments too, and counting them put a top-level
            -- itemize two levels in (measured: `○` where `●` belonged).
            environments = { itemize = true, enumerate = true, description = true },
        },
        emphasis = {
            enabled = true,
            -- COMMAND → how its argument is drawn. The command name and its braces conceal; the
            -- text inside keeps its place and takes the style. Any command not named here is left
            -- exactly as written — a renderer that guessed at unknown macros would hide code.
            commands = {
                ["\\textbf"] = "bold",
                ["\\textit"] = "italic",
                ["\\emph"] = "italic",
                ["\\underline"] = "underline",
                ["\\texttt"] = "code",
                ["\\textsc"] = "bold",
                ["\\sout"] = "strike",
            },
        },
        code = {
            enabled = true,
            band = true,
            label = true,
            icon = "󰅩",
            fences = "show",
            position = "right",
            icon_color = "devicon",
            header = true,
            air = 1,
            pad = 2,
            width = "full",
        },
        links = {
            enabled = true,
            -- `\url{…}` and `\href{…}{label}`; the icons match the markdown block's.
            icons = { link = "󰌷 ", image = "󰋩 ", auto = "󰖟 ", wiki = "󰌹 ", embed = "󰋩 " },
            conceal = true,
        },
        -- `\label{sec:x}` — the anchor. nf-md-tag, the command and braces concealed behind it.
        labels = { enabled = true, icon = "󰓹 ", conceal = true },
        -- `\ref{sec:x}` / `\eqref` / `\pageref` — a pointer at one.
        refs = { enabled = true, icon = "󰌹 " },
        -- `\cite{key}` — a pointer at the bibliography.
        citations = { enabled = true, icon = "󰂺 " },
        -- `\%` → `%`: the backslash conceals, the character shows plain.
        escapes = { enabled = true },
        -- The rule LaTeX actually has is a command, not a block element; the block stays for
        -- shape parity with the other formats and draws nothing.
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
        -- TYPST SPELLS THE SAME SYMBOLS DIFFERENTLY. The shared table is keyed by LaTeX commands
        -- (`\\infty`), and typst writes `infinity`, `oo`, `arrow.r`, `eq.not` — names that never
        -- matched, so a symbol with a perfectly good single-character rendering stayed raw. This
        -- maps a typst name (dotted ones included — the grammar gives them as `field` nodes) onto
        -- the LaTeX command that carries the glyph. Merged over by `setup()`, so a name typst adds
        -- tomorrow is one config line, not a plugin release.
        typst_aliases = {
            oo = "infty",
            infinity = "infty",
            integral = "int",
            ["integral.double"] = "iint",
            ["integral.cont"] = "oint",
            product = "prod",
            diff = "partial",
            gradient = "nabla",
            nothing = "emptyset",
            without = "setminus",
            union = "cup",
            sect = "cap",
            prop = "propto",
            ["eq.not"] = "neq",
            ["lt.eq"] = "leq",
            ["gt.eq"] = "geq",
            ["plus.minus"] = "pm",
            ["minus.plus"] = "mp",
            ["in.not"] = "notin",
            ["arrow.r"] = "rightarrow",
            ["arrow.l"] = "leftarrow",
            ["arrow.t"] = "uparrow",
            ["arrow.b"] = "downarrow",
            ["arrow.l.r"] = "leftrightarrow",
            ["arrow.r.double"] = "Rightarrow",
            ["arrow.l.double"] = "Leftarrow",
            ["angle.l"] = "langle",
            ["angle.r"] = "rangle",
            ["dots.h"] = "ldots",
            ["dots.v"] = "vdots",
            ["dots.down"] = "ddots",
            ["tilde.equiv"] = "cong",
            ["tilde.op"] = "sim",
            ["not"] = "neg",
            ["and"] = "wedge",
            ["or"] = "vee",
            convolve = "ast",
            dot = "cdot",
            ["dot.op"] = "cdot",
        },
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
        -- The header band: blue, end to end, a shade above the body it sits on.
        code_header = { accent = "blue", tint = 0.15, fg = false },
        -- The chip is built from the ICON'S OWN colour at draw time (a devicon differs per
        -- language), so only its tint is configurable here — the accent comes from the glyph.
        code_chip = { tint = 0.15, bold = true },
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
