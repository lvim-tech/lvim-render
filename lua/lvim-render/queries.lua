-- lvim-render.queries: ownership of the HIGHLIGHT query where its metadata fights the renderer.
--
-- Neovim's markdown highlight queries hide the code-fence LINES outright (`#set! conceal_lines`
-- on the delimiters — runtime queries/markdown/highlights.scm, and the user's site override
-- carries the same stanzas). The owner wants those lines VISIBLE with only the backticks
-- concealed and the language kept at the line start — so the directive must go. The official
-- seam for that is `vim.treesitter.query.set()`: this module resolves the EFFECTIVE query source
-- the same way the loader does (runtime-path order; a non-`;; extends` file replaces what came
-- before, an extending one appends), strips ONLY the `conceal_lines` directives — the patterns
-- and every other capture stay exactly as shipped — and installs the result as the override.
-- No file is copied, no fork is maintained: upstream edits flow through untouched except the
-- one directive, and health reports when there was nothing to strip (a sign upstream changed).
--
---@module "lvim-render.queries"

local M = {}

---@class LvimRenderQueryState
---@field mode "show"|"hide"  the applied fences mode
---@field stripped integer    how many conceal_lines directives were removed
---@field original string     the untouched resolved source, for restoring "hide"

---@type table<string, LvimRenderQueryState>  language → override state
M.state = {}

--- Resolve the effective query source for (lang, name) the way Neovim's loader does.
---@param lang string
---@param name string
---@return string|nil
local function resolved_source(lang, name)
    local files = vim.treesitter.query.get_files(lang, name)
    if files == nil or #files == 0 then
        return nil
    end
    ---@type string[]
    local parts = {}
    for _, path in ipairs(files) do
        local f = io.open(path, "r")
        if f ~= nil then
            local text = f:read("*a") or ""
            f:close()
            -- The loader's semantics: a file whose modeline does not say `;; extends` REPLACES
            -- everything gathered so far; an extending file appends.
            local header = text:match("^[^\n]*") or ""
            if header:find("extends", 1, true) == nil then
                parts = { text }
            else
                parts[#parts + 1] = text
            end
        end
    end
    if #parts == 0 then
        return nil
    end
    return table.concat(parts, "\n")
end

--- Apply the fences mode for a language's highlight query.
---@param lang string
---@param mode "show"|"hide"
---@return nil
function M.apply(lang, mode)
    local current = M.state[lang]
    if current ~= nil and current.mode == mode then
        return
    end
    if mode == "hide" then
        -- Back to what the runtime path resolves on its own.
        if current ~= nil then
            pcall(vim.treesitter.query.set, lang, "highlights", current.original)
            M.state[lang] = { mode = "hide", stripped = 0, original = current.original }
        end
        return
    end
    local source = current ~= nil and current.original or resolved_source(lang, "highlights")
    if source == nil then
        return
    end
    local overridden, stripped = M.strip_fence_conceals(source)
    local ok = pcall(vim.treesitter.query.set, lang, "highlights", overridden)
    if ok then
        M.state[lang] = { mode = "show", stripped = stripped, original = source }
    end
end

--- Remove the conceal directives from the CODE-FENCE stanzas only: the effective query hides
--- both the fence lines (`conceal_lines`) and the language text (`conceal` — present in the
--- user's site copy), and "show" needs both visible; every other stanza's conceals are none of
--- this module's business. Stanzas are split as top-level S-expressions with `; …` comments
--- skipped (a comment CAN contain parentheses — the site file's does).
---@param source string
---@return string overridden
---@return integer stripped  how many directives were removed
function M.strip_fence_conceals(source)
    ---@type string[]
    local out = {}
    local stripped = 0
    local depth, expr_start, i, n = 0, nil, 1, #source
    local last_flush = 1
    while i <= n do
        local c = source:sub(i, i)
        if c == ";" then
            i = (source:find("\n", i, true) or n + 1)
        else
            if c == "(" then
                if depth == 0 then
                    expr_start = i
                end
                depth = depth + 1
            elseif c == ")" and depth > 0 then
                depth = depth - 1
                if depth == 0 and expr_start ~= nil then
                    local expr = source:sub(expr_start, i)
                    if expr:find("fenced_code_block", 1, true) ~= nil then
                        local cleaned, a = expr:gsub('%(#set!%s+conceal_lines%s+""%)', "")
                        local cleaned2, b = cleaned:gsub('%(#set!%s+conceal%s+""%)', "")
                        stripped = stripped + a + b
                        out[#out + 1] = source:sub(last_flush, expr_start - 1)
                        out[#out + 1] = cleaned2
                        last_flush = i + 1
                    end
                    expr_start = nil
                end
            end
            i = i + 1
        end
    end
    out[#out + 1] = source:sub(last_flush)
    return table.concat(out), stripped
end

--- Restart treesitter highlighting on a buffer whose highlighter predates the override, so the
--- amended query takes effect there too. One call per attach; a no-op without a highlighter.
---@param buf integer
---@param lang string
---@return nil
function M.refresh_highlighter(buf, lang)
    if M.state[lang] == nil or M.state[lang].mode ~= "show" then
        return
    end
    if vim.treesitter.highlighter.active[buf] ~= nil then
        pcall(vim.treesitter.stop, buf)
        pcall(vim.treesitter.start, buf, lang)
    end
end

return M
