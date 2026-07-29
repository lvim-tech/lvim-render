# lvim-render

In-buffer document rendering for Neovim. The buffer you are EDITING is decorated in place —
headings become coloured bands with level icons, list markers become glyphs, `---` becomes a drawn
line, and every heading folds its subtree with a rendered fold line and an org-style cycle key.
Turn it off and the buffer is exactly as it was, fold options included.

Part of the [lvim-tech](https://github.com/lvim-tech) plugin set. It renders **markdown**,
**typst**, **org** and **latex**; the `asciidoc` block is the fixed surface its renderer will fill
once a grammar for it is packaged (health reports each format's status).

## How it works

One pipeline: treesitter parse → node walk → decoration ops → extmarks, windowed to what is on
screen. A decoration provider re-emits the cheap decorations as **ephemeral** marks on every
redraw — nothing persistent accumulates, nothing needs cleanup, and a 10k-line document costs what
one screen costs (measured: ~2 ms per screen). Inline icons, which shift text and therefore cannot
be ephemeral, live in a small persistent lane reconciled per visible row. Edits are debounced and
generation-cancelled: a superseded rebuild never paints stale decorations.

- **Headings** — level icon, tinted full-width band, `#` markers concealed; setext headings get
  the band over both rows and a redrawn underline. Every level has its own icon, pad and accent,
  and by default the TITLE TEXT takes the level's colour too (`headings.text = "accent"`) — six
  visibly different headings whatever the theme's own markup groups do; `"theme"` leaves the
  text to the colorscheme. Any level can be wired to your own highlight group verbatim:
  `highlights.h1 = { group = "MyH1" }` (used everywhere the level paints — band, icon, fold
  line).
- **Lists** — `-` / `*` / `+` markers become glyphs, cycling per nesting depth.
- **Checkboxes** — `[ ]` / `[x]` and any configured extra state (`[-]`, `[~]`, yours) render as a
  single coloured glyph in place of marker and token, per state.
- **Rules** — a `---` line is drawn across the window's text width in its own colour
  (`highlights.rule`), with a configurable icon centred in it (`─── ◆ ───`,
  `highlights.rule_icon`; `icon = ""` for an unbroken line). The line STYLE is any glyph or
  multi-char pattern, filled to the exact width — single `─`, bold `━`, double `═`, dashed `┄`
  `╌`, dotted `·`, wavy `∿` `≈`, or patterns like `"·─"` (all verified single-width; `﹏` is
  two cells and also works).
- **Math** — `$…$` and `$$…$$` through the SHARED symbol table (lvim-tex's conceal data — one
  map across the set; user maps merge over it): `\alpha^2` reads `α²`. Block math gets a
  background band and a label. THE CEILING, stated: substitution is linear — `\frac`, matrices
  and multi-char scripts stay raw text inside the band, readable and honest, never mangled (the
  kitty image tier lifts this later and stays off).
- **Frontmatter** — `---` YAML / `+++` TOML blocks sit on a background band under their own
  injected colours.
- **Long-tail inlines** — `\*` escapes (backslash concealed), `==marked==` spans, `<https://…>`
  autolinks, `[[wikilinks]]` / `[[target|alias]]` / `![[embeds]]`, `[id]: url` reference
  definitions (icon-marked), `:smile:` emoji shorthands (the user's own emoji, single-codepoint
  gemoji names, extendable), basic HTML tags (`<b>/<i>/<u>/<s>/<mark>` conceal, the span takes
  the attribute; unpaired or exotic tags stay raw), and opt-in `#tag` accenting.
- **Inline layer** — emphasis/strong/strike markers concealed (the styling stays treesitter's);
  `` `code` `` becomes a padded pill whose padding cells ARE the concealed backticks; links and
  images keep their label behind an icon with brackets and destination hidden; `&amp;`-style
  entities render as their character (the classic ~250-name table, user-extendable).
- **Code blocks** — a background-ONLY band under the block, so the injected language's own
  treesitter colours stay exactly as in a real buffer of that filetype (asserted by fixture, not
  by eye); a language chip with the language's devicon (through lvim-icons when present). By
  default the fence LINES stay visible (`code.fences = "show"`): only the backticks conceal and
  the chip sits at the line start before the language name — Neovim's own markdown query hides
  those lines whole (`conceal_lines`), so "show" installs an amended highlight query with just
  the fence-conceal directives stripped, through the official `vim.treesitter.query.set()` seam.
  `code.fences = "hide"` keeps the native behaviour, with the chip right-aligned on the block's
  first content row. The chip's POSITION on the fence line is `code.position` — "left" (icon
  before the language text), "center" or "right" (the language text conceals and the chip moves
  there). The icon's colour is `code.icon_color`: "accent" (one distinct colour,
  `highlights.code_icon`) or "devicon" (the language's own lvim-icons colour). The band uses the
  palette's darker surface by default (`highlights.code = bg_dark`).
- **Block quotes** — every `>` becomes a border glyph, per nesting depth accent, on continuation
  rows too. `quotes.repeat_on_wrap` repeats the border on wrapped rows — off by default, because
  it paints over each continuation row's first cell unless 'breakindent'/'showbreak' keep that
  column free (pair it with `breakindent` + `breakindentopt=shift:2`).
- **Callouts** — `> [!NOTE]`-style quotes take the type's accent for their borders and render
  the token as icon + label (type set extendable, matched case-insensitively).
- **Tables** — the full box: `┌─┬─┐` borders (virtual lines), drawn junction row, pipes become
  `│` via conceal, cells padded to their column by the DELIMITER row's alignment
  (`:---`/`:---:`/`---:`). Columns size to the widest RENDERED cell — a link cell measures as
  icon + label, a pill as its padded cells, CJK as double cells, never as source bytes — and a
  manually space-padded source table reflows to compact content-sized columns. THE RULE: the box
  is all-or-nothing per table; beyond `max_rows`, `max_width` or the window's width the whole
  table degrades to styled pipes aligned to your text as written — a silently broken box is
  never an outcome. Analysis is cached per edit, so a 200×10 table scrolls at screen cost.
  **Under `'wrap'` the table is drawn as a fitted virtual box** (`tables.wrap_cells`, on by
  default), because it is the only thing that works there. THE MEASUREMENT: concealed text still
  takes its width when a line wraps — a 52-column line whose visible form is 10 columns still
  occupies two screen rows in a 40-column window. A table row with links is two to three times
  longer raw than rendered, so Neovim wraps it by the RAW length and the columns come apart, and no
  decoration can prevent that because a decoration cannot shorten a line. The only two answers are
  `'nowrap'`, or hiding the source rows and drawing the table as virtual lines. The box does the
  second: the columns shrink to the window and every cell is split across as many lines as it then
  needs. ITS COSTS, equally measured: the box is ONE block of virtual lines hanging off the row
  above the table (virtual lines do not draw on a `conceal_lines` row), so it can only be drawn
  while the WHOLE table is on screen — it pops in and out as you scroll past, scrolling THROUGH it
  is one jump rather than line by line, and a table taller than the window gets nothing. The row
  the cursor is on is painted with the editor's own `CursorLine` background, since Neovim draws no
  `'cursorline'` over virtual lines — and the hardware cursor is HIDDEN while it stands in one
  (`tables_hide_cursor`), because those rows are not on screen for it to stand on. It is hidden
  through lvim-utils' own cursor registry, never a hand-rolled `'guicursor'` save/restore, so it
  composes with every other panel that hides it.

- **Folding** — a heading folds everything down to the next heading of the same or higher level,
  in the plugin's own `foldexpr` (an O(1) lookup into a cached outline). The collapsed line stays
  RENDERED: icon, title and hidden-line count, not a raw `+--` prefix — and it can never be
  silently empty: an error inside the fold expressions falls back to the builtin line and is
  reported by health. The collapsed row is a BAND, not a rule: the level's own band with the
  count as a box on it (`fold.text.count_tint` — the same accent, blended harder), filled to the
  window's width so `'fillchars'` has nothing left to draw its `─` over, and rising to the box's
  tint while the cursor is on it, so line and box become one solid tint. The blank line before
  the next heading stays OUT of the fold (`fold.separate_sections`) — a separator belongs to the
  enclosing subtree, and folded away with the section it leaves two headings glued together. `<Tab>` cycles the heading under the cursor through collapsed → children →
  whole subtree; `<S-Tab>` cycles the document (fold level 0 → 1 → everything).
- **Raw only in insert** — in normal, visual and command-line mode the document stays fully
  rendered, cursor line included. Entering insert reveals the WHOLE element under the cursor —
  the literal text, no icon, no band; a table, fenced block, quote or callout reveals entire
  (`reveal.quotes = "row"` keeps long quotes quieter); leaving insert re-renders it. Cursor
  travel in normal mode costs zero redraws; a membership change costs at most two window-local
  ones (measured). Two mechanisms say the same
  thing: `'concealcursor'` (`"nvc"`) governs the conceal marks, `reveal.modes` (`{ "i", "R" }`)
  governs the plugin's own decorations, and health warns when a configuration makes them
  disagree (a half-rendered line is worse than either choice alone).
- **Typst** — the same pipeline over typst's own grammar, not a markdown lookalike. `=`/`==`
  headings (the level is the length of the run), `- ` bullets by nesting depth, `+ ` items as
  their ORDINAL (`1.`, `2.` — `+` is typst's auto-numbered marker, and a dot for both markers
  would say the two lists are the same kind), `/ Term: description` definition rows, `*strong*`
  and `_emph_` markers concealed, `` `raw` `` pills, ```` ``` ```` blocks banded with a language
  chip, bare URLs icon-marked, `<label>` behind a tag icon, `@ref` whose `@` becomes the icon,
  `\#` escapes, and `$…$` math. Typst's OWN rule decides display versus inline math — `$ x $`
  with spaces inside the dollars is a display block (band + label), `$x$` is inline — and the
  symbols substitute through the same shared table as markdown's LaTeX (typst writes `alpha`
  where LaTeX writes `\alpha`, so one table serves both), with the same single-character ceiling.
  Headings fold exactly as markdown's do.
- **Org** — the same pipeline over org's own grammar. `*`/`**` headlines (the level is the star
  count), `-` bullets by depth, `[ ]`/`[X]` checkboxes, `#+begin_src` blocks banded with a
  language chip and `#+begin_quote` blocks bordered on their content rows (ONE node type, two
  elements — the kind is read, not assumed), `[[target][label]]` links behind an icon,
  `:PROPERTIES:` drawers and `#+TITLE:` directives on the metadata band, and headline folding.
  THE INTERESTING PART is the inline markup: org's grammar gives it no nodes at all — `*bold*` is
  a `str` between two bare `*` tokens, and a lone `*` in `2 * 3` is the same token type. Markers
  are therefore PAIRED across the paragraph (the rule the grammar's own markup query encodes) and
  concealed only when a partner is found, so a real asterisk in prose is never eaten. `=verbatim=`
  and `~code~` become pills. The org grammar is not in the community parser catalogue; the plugin
  registers it with lvim-pkg from its own `setup()`, so installing lvim-render is enough.
- **Window options are owned, never grabbed** — `'foldmethod'`, `'foldexpr'`, `'foldtext'`,
  `'conceallevel'` and `'concealcursor'` are window-local and user-owned: the previous values
  are recorded on attach, re-asserted at the buffer-reenter seam (where Neovim re-initialises
  window-local options and other machinery legitimately writes them), and restored on
  `:LvimRender off`. A fighting owner is named by `:checkhealth`, never silently tolerated.

## Requirements

- Neovim 0.11+
- [lvim-utils](https://github.com/lvim-tech/lvim-utils) (config merge + palette-bound highlights)
- The treesitter parser of each format you use — `markdown` (+ `markdown_inline`), `typst`,
  `org` (resolved and installed through
  [lvim-ts](https://github.com/lvim-tech/lvim-ts) / [lvim-pkg](https://github.com/lvim-tech/lvim-pkg)
  when present; any runtime-reachable parser works)

## Installation

With **lvim-installer** (the lvim-tech set's own installer), or with Neovim's native `vim.pack`:

```lua
vim.pack.add({
    "https://github.com/lvim-tech/lvim-utils",
    "https://github.com/lvim-tech/lvim-render",
})

require("lvim-render").setup({})
```

## Configuration

The full default config. What is COMMON to every format lives at the top level; everything a
FORMAT owns lives in its own block (`markdown`, `org`, `typst`, `asciidoc`, `latex`).

```lua
require("lvim-render").setup({
    enabled = true, -- master switch (the global side of :LvimRender)
    debounce = 50, -- ms of idle before a reparse + outline rebuild after an edit
    max_file_size = 2 * 1024 * 1024, -- bytes; a bigger buffer attaches inert
    max_lines = 20000, -- lines; same gate
    render = { modes = { "n", "v", "V", "\22", "s", "S", "i", "R", "c", "t" } }, -- modes that render at all
    reveal = {
        lines = 0, -- extra lines around the cursor rendered raw (0 = the element at the cursor)
        modes = { "i", "R" }, -- raw ONLY in insert/replace; everywhere else stays fully rendered
        quotes = "element", -- a quote/callout reveals WHOLE | "row" = only the edited row's border
    },
    conceal = { level = 2, cursor = "nvc" }, -- owned per window: recorded, re-asserted, restored
    tables_hide_cursor = true, -- hide the hardware cursor while it stands inside a boxed table
    tables_insert_opens_editor = true, -- `i` inside a boxed table opens the editor, not insert
    tables_box_reveal = false, -- a boxed table does NOT reveal on insert (it is edited in the editor)
    tables_nav_mode = "widget", -- j/k inside a boxed table: "widget" walks its rows | "stop" | "raw"
    tables_nav_keys = { down = "j", up = "k" }, -- predict their landing; never touch a hidden row
    tables_editor = { -- the full-screen table editor (`:LvimRender table`)
        title = "󰓫  Table",
        width = 0.9,
        height = 0.8,
        border = { " ", " ", " ", " ", " ", " ", " ", " " }, -- no ring; any Neovim border works
        keys = {
            commit = "<CR>", -- write the table back, reformatted, and close
            next_cell = "<Tab>",
            prev_cell = "<S-Tab>",
            row_add = "<C-r>",
            row_delete = "<C-d>",
            column_add = "<C-c>",
            column_delete = "<C-x>",
            realign = "<C-a>",
            cancel = "q", -- close without writing anything back
        },
    },
    split = { -- the side-by-side preview (:LvimRender split) — a mirror buffer, see below
        position = "right", -- which side the preview opens on | "left"
        width = 0, -- fraction of the columns (≤ 1) or a cell count; 0 keeps what :vsplit chose
        source = "raw", -- what the SOURCE window shows while the preview is open | "rendered"
        winbar = "%#LvimRenderCodeLabel# %t", -- the preview's own winbar, so both sides align; "" for none
        quiet_source = true, -- turn LSP codelens off in the raw source while the preview is open
        focus = "source", -- where the cursor lands after opening | "preview"
        sync_scroll = true, -- keep the preview's TOP line on the source's (only the top line)
        debounce = 120, -- ms of idle before the mirror is re-copied while typing
        win_options = { number = false, relativenumber = false, signcolumn = "no", cursorline = false },
    },
    completion = { -- callout types and checkbox states, offered through lvim-cmp when it is there
        enabled = true,
        priority = 40,
    },
    priorities = { band = 10, heading_text = 110 }, -- bands below treesitter; accent titles above
    fold = {
        enabled = true, -- own the window fold options while attached (restored on off)
        headings = true, -- a heading folds its subtree
        tables = false, -- opt-in: a table folds one level under its heading
        separate_sections = true, -- keep the blank row(s) before a heading OUT of the fold above
        level = 99, -- 'foldlevel' on attach; the default keeps the document open
        text = {
            enabled = true, -- render the collapsed line instead of the raw +-- foldtext
            title = "{icon} {title}", -- leading chunk, in the heading level's group
            info = " ➤ {count} lines ", -- the count BOX, in the level's accent blended harder
            position = "right", -- which end of the collapsed row the box sits at | "left"
            count_tint = 0.4, -- how hard; the whole row rises to it while the cursor is on it
        },
        keys = { cycle = "<Tab>", cycle_all = "<S-Tab>" }, -- buffer-local; false takes no key
    },
    markdown = {
        enabled = true,
        filetypes = { "markdown" },
        headings = {
            enabled = true,
            band = true, -- tinted full-width band on the heading line
            conceal_markers = true, -- hide the `#` run (its trailing space stays as the gap)
            text = "accent", -- the title text takes the level's colour | "theme" = colorscheme's
            setext_underline = "─", -- redraw a setext underline row with this glyph; "" keeps it
            levels = { -- one entry per level, H1 first; pad = virtual indent cells
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
            bullets = { "●", "○", "◆", "◇" }, -- glyph per nesting depth, cycled
        },
        rule = {
            enabled = true,
            glyph = "─", -- repeated across the window's text width
            icon = "◆", -- centred in the line; "" for an unbroken line
        },
        emphasis = { enabled = true }, -- conceal the markers; styling stays treesitter's
        inline_code = { enabled = true, pad = " " }, -- each backtick CONCEALS to this char
        links = {
            enabled = true,
            icons = { -- rendered verbatim before the label; "" for none
                link = "󰌷 ",
                image = "󰋩 ",
                auto = "󰖟 ", -- <https://…> autolinks
                wiki = "󰌹 ", -- [[wikilinks]]
                embed = "󰋩 ", -- ![[embeds]]
            },
            conceal = true, -- hide brackets + destination, keep the label
        },
        entities = { enabled = true, extra = {} }, -- extra: name → single character
        checkboxes = {
            enabled = true,
            states = { -- matched in order; accents in highlights.checkboxes by index
                { char = " ", icon = "󰄱" },
                { char = "x", icon = "󰄲" },
                { char = "X", icon = "󰄲" },
                { char = "-", icon = "󰡖" },
                { char = "~", icon = "󰅗" },
            },
        },
        code = {
            enabled = true,
            band = true, -- background-only band; injected colours stay (§2a)
            label = true, -- the language chip (devicon + name)
            icon = "󰅩", -- chip fallback when lvim-icons is absent for the language
            fences = "show", -- fence lines visible, backticks concealed | "hide" = native
            position = "right", -- chip on the header band: "left" | "center" | "right"
            icon_color = "devicon", -- "devicon" (lvim-icons colour) | "accent" (highlights.code_icon)
            header = true, -- the opening fence drawn as a full-width band carrying the chip
            air = 1, -- blank rows between the band and the first line of code
            pad = 2, -- spaces of inset left and right, on the code rows only
            width = "full", -- body to the window edge | "content" = a box as wide as the code
        },
        quotes = {
            enabled = true,
            border = "▍", -- what every `>` is redrawn as
            repeat_on_wrap = false, -- see the block-quote note above before enabling
        },
        escapes = { enabled = true }, -- \* → *: the backslash conceals
        mark = { enabled = true }, -- ==text== spans
        emoji = { enabled = true, extra = {} }, -- :name: → emoji; extra: name → ONE character
        tags = { enabled = false }, -- opt-in #tag accenting
        refdefs = { enabled = true, icon = "󰌷 " }, -- [id]: url lines get the icon
        frontmatter = { enabled = true }, -- ---/+++ blocks on a background band
        html = { enabled = true }, -- basic tags conceal; the span takes the attribute
        tables = {
            enabled = true,
            max_rows = 400, -- beyond: degrade to styled pipes (no full-table scan)
            max_width = 200, -- assembled box wider than this (or the window): same degrade
            box = true, -- top/bottom border lines (virtual lines)
            head = true, -- tinted band over the header row
            wrap_cells = true, -- under 'wrap', draw the table as a fitted box (see the note below)
            min_col = 3, -- narrowest column
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
            types = { -- extendable; accents in highlights.callouts by key
                { key = "note", icon = "󰋽", label = "Note" },
                { key = "tip", icon = "󰌶", label = "Tip" },
                { key = "important", icon = "󰅾", label = "Important" },
                { key = "warning", icon = "󰀪", label = "Warning" },
                { key = "caution", icon = "󰳦", label = "Caution" },
            },
        },
    },
    -- The org renderer lands with its phase; the config surface is fixed now. Until then org
    -- buffers do not attach and health says why.
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
    -- Typst: a real renderer (phase 8) — one grammar carries block and inline alike.
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
            position = "right",
            icon_color = "devicon",
            header = true,
            air = 1,
            pad = 2,
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
    -- AsciiDoc: inert until its grammar is reachable; health reports the blocked state.
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
    -- Standalone .tex buffers belong to lvim-tex: OFF by default, explicit opt-in only
    -- (double-decoration risk). LaTeX MATH inside markdown/org is `math` below.
    -- LaTeX: a real renderer — the sectioning ladder read from the NESTING (an article's
    -- `\section` and a book's `\chapter` are both the outermost thing in their document), and
    -- only the macros named below are drawn. Every other macro is left exactly as written.
    latex = {
        enabled = true,
        filetypes = { "tex", "latex", "plaintex" },
        -- The GRAMMAR's name, when it is not the filetype's: nothing in Neovim's runtime says a
        -- `tex` buffer is parsed by the `latex` grammar. setup() registers this.
        language = "latex",
        headings = {
            enabled = true,
            band = true,
            conceal_markers = true, -- the command AND its braces
            text = "accent",
            icon_gap = 1, -- spaces after the icon: `\section{…}` leaves no marker space of its own
            setext_underline = "", -- LaTeX has no underlined heading form
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
            enum = { enabled = true, format = "{n}." }, -- enumerate writes no number in the source
            conceal_environment = true, -- hide the \begin/\end rows of a list
            environments = { itemize = true, enumerate = true, description = true },
        },
        emphasis = {
            enabled = true,
            -- COMMAND → how its argument is drawn; anything not named here is left alone.
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
            enabled = true, -- \url{…} and \href{…}{label}
            icons = { link = "󰌷 ", image = "󰋩 ", auto = "󰖟 ", wiki = "󰌹 ", embed = "󰋩 " },
            conceal = true,
        },
        labels = { enabled = true, icon = "󰓹 ", conceal = true }, -- \label{…}
        refs = { enabled = true, icon = "󰌹 " }, -- \ref{…}
        citations = { enabled = true, icon = "󰂺 " }, -- \cite{…}
        escapes = { enabled = true }, -- `\%` → `%`
        -- LaTeX's rule is a command, not a block element; the block stays for shape parity.
        rule = { enabled = false, glyph = "─", icon = "◆" },
    },
    -- Math is common, not a format: `$…$` / `$$…$$` appear inside markdown and org alike. The
    -- unicode substitution lands at its phase; `image` is the experimental kitty tier — the only
    -- part of the plugin that spawns processes, and off until asked for.
    math = {
        -- Typst spells the same symbols differently (`infinity`, `arrow.r`); the shared table is
        -- keyed by LaTeX commands, so these map a typst name onto the command that carries the
        -- glyph. Merged over by setup() — a name typst adds tomorrow is one config line.
        typst_aliases = { oo = "infty", integral = "int", ["arrow.r"] = "rightarrow" }, -- …and more
        inline = { enabled = true, maps = {} },
        block = { enabled = true, label = "math", band = true, maps = {} },
        image = {
            enabled = false,
            engine = "pdflatex", -- pdflatex | xelatex | lualatex
            converter = "dvisvgm", -- dvisvgm | dvipng | magick
            dpi = 220,
            preamble = {}, -- extra \usepackage lines
            timeout = 5000, -- ms per compile
            cache = { entries = 500, days = 30 },
            conceal_source = true,
        },
    },
    highlights = { -- palette colour NAMES (lvim-utils.colors keys), never hex literals
        h1 = { accent = "blue", tint = 0.2, bold = true },
        h2 = { accent = "teal", tint = 0.2, bold = true },
        h3 = { accent = "green", tint = 0.2, bold = true },
        h4 = { accent = "yellow", tint = 0.2, bold = true },
        h5 = { accent = "orange", tint = 0.2, bold = true },
        h6 = { accent = "magenta", tint = 0.2, bold = true },
        bullets = { -- one spec per nesting depth, cycled like the glyphs; fg-only
            { accent = "blue", bg = false },
            { accent = "yellow", bg = false },
            { accent = "green", bg = false },
            { accent = "orange", bg = false },
        },
        rule = { accent = "blue", bg = false },
        rule_icon = { accent = "orange", bg = false },
        fold_info = { accent = "comment", bg = false },
        -- Code-block band: BACKGROUND only (fg = false) — injected colours are never touched.
        -- bg_dark at full tint = the palette's own darker surface.
        code = { accent = "bg_dark", tint = 1, fg = false },
        code_label = { accent = "blue", bg = false },
        code_header = { accent = "blue", tint = 0.15, fg = false }, -- the full-width header band
        code_chip = { tint = 0.15, bold = true }, -- the chip's tint; its colour is the icon's own
        code_icon = { accent = "orange", bg = false },
        code_inline = { accent = "yellow", tint = 0.15, fg = false },
        link = { accent = "blue", bg = false },
        -- A typst term (`/ Term: …`): foreground-only and bold, so the two halves of the row
        -- read apart without a band behind either.
        term = { accent = "teal", bg = false, bold = true },
        table_border = { accent = "blue", bg = false },
        table_head = { accent = "blue", tint = 0.2, bold = true },
        -- The header row while the cursor is on it: the same accent, blended harder (a header is
        -- already a coloured band, so CursorLine would swap its colour instead of marking it).
        table_head_cursor = { accent = "blue", tint = 0.4, bold = true },
        math = { accent = "bg_dark", tint = 1, fg = false }, -- block-math band, background-only
        math_label = { accent = "purple", bg = false },
        math_symbol = { accent = "teal", bg = false },
        mark = { accent = "yellow", tint = 0.35, fg = false },
        tag = { accent = "cyan", tint = 0.2 },
        metadata = { accent = "bg_dark", tint = 1, fg = false },
        html_bold = { fg = false, bg = false, bold = true },
        html_italic = { fg = false, bg = false, italic = true },
        html_underline = { fg = false, bg = false, underline = true },
        html_strike = { fg = false, bg = false, strikethrough = true },
        quotes = { -- one spec per quote nesting depth, cycled
            { accent = "blue", bg = false },
            { accent = "yellow", bg = false },
            { accent = "green", bg = false },
        },
        checkboxes = { -- by INDEX into markdown.checkboxes.states
            { accent = "blue", bg = false },
            { accent = "green", bg = false },
            { accent = "green", bg = false },
            { accent = "yellow", bg = false },
            { accent = "red", bg = false },
        },
        callouts = { -- by callout KEY; a missing key falls back to the quote depth accent
            note = { accent = "blue", bg = false, bold = true },
            tip = { accent = "teal", bg = false, bold = true },
            important = { accent = "purple", bg = false, bold = true },
            warning = { accent = "yellow", bg = false, bold = true },
            caution = { accent = "red", bg = false, bold = true },
        },
    },
})
```

## Commands

| Command | Effect |
| --- | --- |
| `:LvimRender` / `:LvimRender toggle` | toggle rendering for the current buffer |
| `:LvimRender on` / `:LvimRender off` | switch the current buffer explicitly |
| `:LvimRender toggle all` (or `on all` / `off all`) | flip every attached buffer and the master switch |
| `:LvimRender split` (or `split toggle`) | open the side-by-side preview, or close it if it is open |
| `:LvimRender split open` / `split close` | open or close it explicitly |
| `:LvimRender split redraw` | copy the source into the preview now, bypassing the debounce |
| `:LvimRender table` | open the full-screen editor for the table under the cursor |

`:LvimRender off` restores the window's previous `'foldmethod'`, `'foldexpr'`, `'foldtext'`,
`'conceallevel'` and `'concealcursor'`, and removes every mark the plugin made.

## The table editor

`:LvimRender table` (or `require("lvim-render").table()`) opens the table under the cursor in a
full-screen editor. It exists because a table cannot be edited comfortably in the buffer under
`'wrap'` — see the tables entry above: concealed text still takes its width when a line wraps, so
the in-buffer answer is the box, and the box hides the very rows you would edit.

The editor is a window of its own, so it has its own width and its own `'nowrap'`: nothing there
fights your settings and the grid is shown exactly as wide as it needs to be. Entering insert
inside a boxed table opens it too (`tables_insert_opens_editor`), because `'concealcursor'` would
otherwise un-conceal that single row underneath the box.

| Key | |
| --- | --- |
| `<CR>` | write the table back, reformatted, and close |
| `q` / `<Esc>` | cancel |
| `<Tab>` / `<S-Tab>` | next / previous cell |
| `<C-r>` / `<C-d>` | add / delete a row |
| `<C-c>` / `<C-x>` | add / delete a column |
| `<C-a>` | re-align after an edit widened a cell |

All of them are `tables_editor.keys`. The key that OPENS the editor is deliberately not taken —
that one belongs in your own keymap; the command is the seam.

**Write-back reformats.** The grid you edit is aligned, so writing back something ragged would make
the file disagree with what you just saw: the columns are padded to their widest cell, markdown's
delimiter row keeps the alignment the source declared (`:---`, `---:`, `:---:`), org gets its own
`+` separator, and nothing outside the table's own rows is touched. The formatting is idempotent —
a formatter that reformats its own output differently corrupts a file a little more on every visit,
which is asserted by fixture rather than assumed.

Formats: markdown and org. Typst has no table NODE at all — a typst table is a `#table(…)`
function call, which is code.

## The side-by-side preview

`:LvimRender split` opens a second window showing the same document fully rendered, while the
one you are editing in keeps revealing the raw markers under your cursor.

While the preview is open the SOURCE goes **raw** (`split.source`, the default): every marker,
fence and pipe exactly as written on one side, what it becomes on the other. That is what a split
preview is for — rendering both sides makes the preview a clone that shows nothing the source
does not. Raw means `'conceallevel'` 0 for as long as the preview lives, not the value you
happen to have set: Neovim's own markdown queries hide `**` and `[]` at level 2, so restoring
your setting would leave the "raw" side still hiding markers. The plugin keeps owning the option
(re-asserting it at the buffer-reenter seam) and gives it back when the preview closes.
`split.source = "rendered"` keeps both sides decorated.

While the preview is open the source is also **quieted** (`split.quiet_source`): LSP codelens is
turned off for that buffer and restored on close. Its virtual lines ("1 reference" above a
heading) are not the file's own text, and each one pushes the source down a row — the same
misalignment the winbar below exists to avoid. Only ever turned off when it was on.

The preview draws its own `winbar` whenever the source window has one (`split.winbar`). Chrome
above the text decides where the text starts, so a winbar on the source only — the usual case,
since a statusline plugin draws one for files and not for scratch buffers — would leave the two
documents one row apart. It is deliberately NOT a copy of the source's value: the plugin that
owns that winbar excludes scratch buffers on purpose and clears its own string back off, so a
copy would be undone; a different string is a foreign winbar, which such a plugin leaves alone.

The preview is a **mirror buffer** — a copy, not the same buffer in a second window — and that
is a consequence of how Neovim draws, not a preference. Inline virtual text and virtual lines
render nothing when they are ephemeral, so every icon, code chip and table border this plugin
draws has to be a real buffer extmark; a buffer extmark is visible in **every** window showing
that buffer, and there is no window-scoped extmark namespace to put it in. One buffer cannot be
raw on one side and rendered on the other. Two buffers can.

The mirror is unlisted, unmodifiable, and never written anywhere: it is overwritten wholesale
from the source and never read back, so no edit can be lost in it. It follows the source's edits
(coalesced by `split.debounce`) and the source's top line (`split.sync_scroll`); only the top
line, because a rendered table is taller than its source rows and matching cursor lines would
fight that difference. Closing either window — or the source buffer — takes the whole thing
down, leaving no window, no buffer and no autocommands behind.

## Completion

When **lvim-cmp** is installed, this plugin registers a source for the two vocabularies it OWNS
and nothing else can know:

- `> [!` offers every configured callout type, and accepting one closes the bracket.
- `- [` (or `1. [`) offers every configured checkbox state.

Both lists are generated from the live config on every request, so a type you add to
`callouts.types` is offered without anything else being told about it. Where lvim-cmp is absent
the source is simply never registered — nothing is required, and nothing is reported.

## Keys

Buffer-local, on attached buffers only, both configurable (`fold.keys`, `false` for none):

- `<Tab>` — cycle the heading under the cursor: collapsed → children shown → whole subtree.
- `<S-Tab>` — cycle the whole document: overview → children → everything.

Note: in terminals without the extended keyboard protocol `<Tab>` is the same key as `<C-i>`, so
the jump-forward motion is shadowed in attached buffers there.

## API

```lua
require("lvim-render").status(buf) -- { attached, enabled, inert, format, mirror, split } for a statusline
require("lvim-render").refresh(buf) -- rebuild the fold outline now, bypassing the debounce
require("lvim-render").split("toggle", buf) -- "toggle" | "open" | "close" | "redraw"
```

## Highlight groups

All derived from the shared lvim-utils palette and re-derived on every colorscheme change:
`LvimRenderH1`–`LvimRenderH6`, `LvimRenderBullet1`–`LvimRenderBullet4` (one per configured
depth), `LvimRenderRule`, `LvimRenderFoldStrong1`–`LvimRenderFoldStrong6` (the count box on a
collapsed line, and that whole line under the cursor), `LvimRenderTerm` (a typst term),
`LvimRenderTableCursor` and `LvimRenderTableHeadCursor` (the row the cursor is on inside a boxed
table — the body row takes the editor's own `CursorLine`, the header raises its own tint; both
mark the CELLS only, so the box keeps its frame on every row).

## Health

`:checkhealth lvim-render` reports the per-format status (active / later phase / grammar
missing), attached buffers with their outline sizes, window option ownership — including a
previous `'foldexpr'` owner by value and a LIVE conceal-option conflict (another autocmd
overwriting `'conceallevel'` after the plugin asserts it is named as exactly that) — any error a
fold expression raised (drawn as the builtin fold line instead of an empty one), the
`'concealcursor'` ↔ `reveal.modes` agreement per mode, every open preview with whether its
mirror is in step with its source, whether the completion source registered with lvim-cmp,
glyph cell widths, template placeholders and palette accents.
