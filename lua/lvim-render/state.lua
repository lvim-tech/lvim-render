-- lvim-render.state: per-buffer and per-window RUNTIME state — never configuration. One table per
-- attached buffer (its generation counter, outline cache, debounce timer) and one per touched
-- window (the fold/conceal option values that were there before us, so `:LvimRender off` can put
-- back exactly what it found).
--
---@module "lvim-render.state"

local M = {}

---@type boolean  setup() has run. Health reads it: a check that asks "is this registration in
--- place" must not accuse a session that never set the plugin up (a bare `nvim -c checkhealth`).
M.ready = false

---@class LvimRenderHeading
---@field row integer     0-based buffer row of the heading line
---@field level integer   1..6
---@field title string    the heading text without its markers, for the foldtext
---@field end_row integer 0-based EXCLUSIVE end of the heading's subtree (the next heading of the
---   same or higher level, or the end of the buffer)
---@field setext boolean  a two-line setext heading (the underline row is row + 1)

---@class LvimRenderBufState
---@field enabled boolean         decorations are painted (the per-buffer toggle)
---@field raw boolean|nil         RAW PREVIEW mode: nothing is painted AND the window shows the
---   file's own characters — 'conceallevel' 0, whatever the reader's setting says. Set while a
---   side-by-side preview owns the rendering (see lvim-render.split); distinct from
---   `enabled = false`, which hands the window options back entirely
---@field inert string|nil        why the buffer attached but renders nothing (size gate, missing
---   grammar) — reported by health, never an error
---@field format string           the FORMAT block of the config this buffer renders under
---   (`config[format]` — "markdown", later "org", "typst", …)
---@field lang string             the parser language driving the walk
---@field generation integer      bumped on every change; scheduled work carries the value it was
---   created for and aborts when the buffer has moved on
---@field timer uv.uv_timer_t|nil the debounce timer for the outline rebuild
---@field dirty { first: integer, last: integer }|nil  0-based row span touched since the last
---   rebuild, so the fold refresh re-evaluates only what may have changed
---@field outline LvimRenderHeading[]        every heading, sorted by row
---@field heading_by_row table<integer, LvimRenderHeading>  0-based row → heading, the O(1) seam
---   the foldexpr reads through
---@field max_level integer       the deepest heading level present, for the global cycle
---@field cycle_all integer       last global cycle state: 0 overview, 1 children, 2 everything
---@field baseline LvimRenderWinSaved|nil  the window options the buffer's FIRST window had before
---   attach — what a window born from a split of an owned window (and therefore carrying our
---   values from birth) is restored to
---@field tables table<string, table>  per-table analysis cache (rendered cell widths, column
---   maxima, alignment), keyed by the table's start row; entries regenerate when `generation`
---   moves on
---@field boxed table<integer, integer>|nil  first row → last row of every table currently drawn as
---   a BOX. Its rows are hidden, so the hardware cursor has nothing to stand on in them — the
---   engine reads this to hide the cursor while it is inside one. Dropped (with `box_rows` and
---   `box_lines`) on every debounced rebuild: the row numbers describe the text as it WAS, and
---   navigation reading them across an edit walked phantom tables
---@field box_active { first: integer, last: integer, anchor: integer, index: integer, rows: integer, avail: integer|nil, walk: boolean|nil, page: integer|nil }|nil
---   the WIDGET cursor: which row of a boxed table is active while the real cursor is parked on the
---   displayed row above it. Neovim has no mapping between a hidden buffer row, a screen row inside
---   someone else's `virt_lines`, and a topline — so walking a box is a plugin-owned index, not a
---   cursor position (see `tables_nav_mode`). `avail` is the screen room under the parked row the
---   pagination may use; the walk grows it one line per step, never by a jump. `walk` true is the
---   widget; nav mode "stop" parks the same record without it, so no row lights up
---@field box_rows table<integer, integer>|nil  first row of a boxed table → how many DATA rows it
---   drew, so the widget index knows where the table ends
---@field box_lines table<integer, integer>|nil  first row of a boxed table → the block's FULL
---   height in screen lines (before any pagination), so entering a walk can tell whether the box
---   needs the view scrolled at all
---@field fold_drops table<integer, string>|nil  row → the fold level that ENCLOSES it, stated
---   where a subtree ends and nothing else would state a lower one (`=` carries the previous
---   level, so without this the last fold swallows every row to the end of the buffer)
---@field sep_levels table<integer, string>|nil  0-based row → foldexpr answer for a BLANK row that
---   separates two sections. Such a row belongs to the ENCLOSING subtree, not to the section above
---   it: inside the fold it vanishes when the section collapses and the two headings stick
---   together with nothing between them
---@field table_folds table<integer, string>|nil  0-based row → foldexpr answer for opt-in table
---   folding

---@type table<integer, LvimRenderBufState>  buffer → state
M.buffers = {}

---@class LvimRenderWinSaved
---@field buf integer        the attached buffer these values were saved FOR — a window that moved
---   to another buffer must not have markdown's fold options "restored" onto it
---@field foldmethod string
---@field foldexpr string
---@field foldtext string
---@field foldenable boolean
---@field foldlevel integer
---@field conceallevel integer
---@field concealcursor string
---@field options table<string, any>  the reader's values for the options `config.win_options`
---   asked us to own for this filetype, so they can be handed back exactly as found

---@type table<integer, LvimRenderWinSaved>  window → what was there before us
M.wins = {}

---@type table<integer, { first: integer, last: integer }>  window → the 0-based row span that
--- rendered RAW on the last pass, so a cursor move redraws only the lines whose membership changed
M.reveal = {}

--- The state for a buffer, if it is attached.
---@param buf integer
---@return LvimRenderBufState|nil
function M.get(buf)
    return M.buffers[buf]
end

--- Forget a buffer entirely (timer already closed by the engine).
---@param buf integer
---@return nil
function M.drop(buf)
    M.buffers[buf] = nil
end

return M
