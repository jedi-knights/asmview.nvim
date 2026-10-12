-- lua/asmview/range.lua
-- Resolve the source range we want to compile: visual selection,
-- explicit :Asm range, or function-under-cursor.

local M = {}

---Return the lines (1-based, inclusive) of the current visual selection in `bufnr`.
---Uses marks '< and '>, which are set when leaving visual mode. The caller is
---expected to have already left visual mode (user commands run after :<Esc>).
---@param bufnr integer
---@return integer start_line, integer end_line
local function visual_marks(bufnr)
  local s = vim.api.nvim_buf_get_mark(bufnr, "<")
  local e = vim.api.nvim_buf_get_mark(bufnr, ">")
  if s[1] == 0 or e[1] == 0 then
    return 0, 0
  end
  return math.min(s[1], e[1]), math.max(s[1], e[1])
end

---Climb up from `start_line` looking for an opening function-like line. Caps
---at `max_scan` lines to keep the loop bounded on large buffers.
---Returns the 1-based line of the opening brace, or nil.
---@param bufnr integer
---@param start_line integer 1-based
---@param max_scan integer
---@return integer? opening_line
local function find_opening(bufnr, start_line, max_scan)
  local stop = math.max(1, start_line - max_scan)
  for lnum = start_line, stop, -1 do
    local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
    if line then
      -- A top-level definition line usually ends with `{` or starts with a
      -- language-specific function keyword. Accepted shapes:
      --   C/C++  : trailing `{`
      --   Rust   : `fn ` / `pub fn `
      --   Go     : `func ` (freestanding) or `func (recv) ` (method)
      if line:match("^%s*fn%s") or line:match("^%s*pub%s+fn%s") or line:match("^%s*func%s") then
        return lnum
      end
      if line:match("{%s*$") then
        return lnum
      end
    end
  end
  return nil
end

---Walk forward balancing braces to find the function's closing line.
---Capped at `max_scan` lines.
---@param bufnr integer
---@param open_line integer 1-based opening line
---@param max_scan integer
---@return integer? closing_line
local function find_closing(bufnr, open_line, max_scan)
  local total = vim.api.nvim_buf_line_count(bufnr)
  local last = math.min(total, open_line + max_scan)
  local depth = 0
  local seen_open = false
  for lnum = open_line, last do
    local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
    for ch in line:gmatch("[{}]") do
      if ch == "{" then
        depth = depth + 1
        seen_open = true
      else
        depth = depth - 1
        if seen_open and depth <= 0 then
          return lnum
        end
      end
    end
  end
  return nil
end

---Try to resolve the enclosing function via treesitter, falling back to a
---brace-balanced scan. Returns nil if neither strategy succeeds.
---@param bufnr integer
---@param cursor_line integer 1-based
---@param max_scan integer Cap on the fallback brace-balancing scan
---@return integer? start_line, integer? end_line
function M.enclosing_function(bufnr, cursor_line, max_scan)
  assert(type(bufnr) == "number", "bufnr required")
  assert(type(cursor_line) == "number" and cursor_line >= 1, "cursor_line >= 1 required")

  -- Treesitter path
  local ok_ts, ts = pcall(require, "vim.treesitter")
  if ok_ts and ts then
    local parser_ok, parser = pcall(ts.get_parser, bufnr)
    if parser_ok and parser then
      local trees = parser:parse()
      local root = trees and trees[1] and trees[1]:root() or nil
      if root then
        local node = root:named_descendant_for_range(cursor_line - 1, 0, cursor_line - 1, 0)
        while node do
          local kind = node:type()
          if
            kind == "function_definition"
            or kind == "function_item"
            or kind == "method_definition"
            or kind == "function_declarator"
            or kind == "function_declaration"
            or kind == "method_declaration"
          then
            local sr, _, er, _ = node:range()
            return sr + 1, er + 1
          end
          node = node:parent()
        end
      end
    end
  end

  -- Fallback: brace-balanced walk
  local open_line = find_opening(bufnr, cursor_line, max_scan)
  if not open_line then
    return nil
  end
  local close_line = find_closing(bufnr, open_line, max_scan)
  if not close_line then
    return nil
  end
  return open_line, close_line
end

---Collect lines [s, e] (1-based inclusive) and return them joined.
---@param bufnr integer
---@param s integer
---@param e integer
---@return string
local function join_range(bufnr, s, e)
  local lines = vim.api.nvim_buf_get_lines(bufnr, s - 1, e, false)
  return table.concat(lines, "\n")
end

---Resolve the request range from caller context.
---`opts.line1`/`opts.line2` from the user-command range take precedence over cursor.
---Pass `opts.visual = true` when the command fired from visual mode.
---@param bufnr integer
---@param opts { line1?: integer, line2?: integer, visual?: boolean, scan_cap?: integer }
---@return asmview.Range? range, string? error
function M.resolve(bufnr, opts)
  opts = opts or {}
  local scan_cap = opts.scan_cap or 2000

  if opts.visual then
    local s, e = visual_marks(bufnr)
    if s == 0 then
      return nil, "no visual selection"
    end
    return {
      start_line = s,
      end_line = e,
      source = join_range(bufnr, s, e),
      label = string.format("lines %d-%d", s, e),
    }
  end

  if opts.line1 and opts.line2 and opts.line1 ~= opts.line2 then
    return {
      start_line = opts.line1,
      end_line = opts.line2,
      source = join_range(bufnr, opts.line1, opts.line2),
      label = string.format("lines %d-%d", opts.line1, opts.line2),
    }
  end

  local cursor_line = opts.line1 or vim.api.nvim_win_get_cursor(0)[1]
  local s, e = M.enclosing_function(bufnr, cursor_line, scan_cap)
  if not s then
    return nil, "no enclosing function found around line " .. cursor_line
  end
  return {
    start_line = s,
    end_line = e,
    source = join_range(bufnr, s, e),
    label = string.format("function @ line %d-%d", s, e),
  }
end

return M
