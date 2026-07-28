-- lvim-render.state: per-buffer and per-window RUNTIME state — never configuration. One table per
-- attached buffer (its generation counter, outline cache, debounce timer) and one per touched
-- window (the fold/conceal option values that were there before us, so `:LvimRender off` can put
-- back exactly what it found).
--
---@module "lvim-render.state"

local M = {}

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
---   engine reads this to hide the cursor while it is inside one
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
