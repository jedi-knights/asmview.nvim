-- lua/asmview/mapping.lua
-- Build a source-line → asm-line map from the emitted assembly text.
-- Two parsers:
--   * parse_loc   — gas `.file N "path"` + `.loc N L C` directives
--                   (C/C++/Rust via -g / -C debuginfo=1)
--   * parse_go    — go tool compile -S's `(file.go:LINE)` instruction prefixes

local M = {}

-- Cap on asm-line iteration. gas output for a single function should never
-- exceed this. Past the cap we bail with an empty map so a pathological
-- compiler run (whole-TU dump, enormous inlining) can't stall the UI.
local MAX_ASM_LINES = 200000

---Return true when `path` ends with `basename`. Covers absolute paths
---(rustc's `/tmp/asmview-X/snippet.rs`) and relative paths (go's
---`./snippet.go`) alike.
---@param path string
---@param basename string
---@return boolean
local function path_ends_with(path, basename)
  if path == basename then
    return true
  end
  -- "/.../snippet.rs" or "./snippet.go" — require a path separator before
  -- the basename so "my_snippet.c" doesn't match "snippet.c".
  local suffix = "/" .. basename
  return path:sub(-#suffix) == suffix
end

---Parse gas-style `.file N "path"` + `.loc N L C` into a LineMap.
---@param asm string
---@param range asmview.Range
---@param src_basename string
---@return asmview.LineMap
local function parse_loc(asm, range, src_basename)
  local by_source = {}
  local by_asm = {}
  local unmapped = 0
  local files = {} -- [N] = path
  local current_src_line = nil -- latest .loc that pointed at the snippet
  local in_unmatched_region = false -- true after a .loc pointing at another file
  local idx = 0

  -- Append the trailing newline so the final line (if the asm doesn't end
  -- with one) is still visited by the gmatch iterator.
  for line in (asm .. "\n"):gmatch("([^\n]*)\n") do
    idx = idx + 1
    if idx > MAX_ASM_LINES then
      -- Cap tripped: pathological asm. Bail with what we have so far rather
      -- than looping unboundedly over user-controlled input.
      return { by_source = {}, by_asm = {}, unmapped_asm_count = unmapped }
    end

    local file_n, file_path = line:match('^%s*%.file%s+(%d+)%s+"([^"]+)"')
    if file_n then
      files[tonumber(file_n)] = file_path
    else
      local loc_n, loc_line = line:match("^%s*%.loc%s+(%d+)%s+(%d+)")
      if loc_n then
        local path = files[tonumber(loc_n)]
        if path and path_ends_with(path, src_basename) then
          current_src_line = tonumber(loc_line) + range.start_line - 1
          in_unmatched_region = false
        else
          current_src_line = nil
          in_unmatched_region = true
        end
      else
        -- Non-directive line (instruction, label, other directive). Attribute
        -- only if we're inside a snippet-matched .loc region.
        if current_src_line then
          by_source[current_src_line] = by_source[current_src_line] or {}
          table.insert(by_source[current_src_line], idx)
          if by_asm[idx] == nil then
            by_asm[idx] = current_src_line
          end
        elseif in_unmatched_region then
          unmapped = unmapped + 1
        end
      end
    end
  end

  return { by_source = by_source, by_asm = by_asm, unmapped_asm_count = unmapped }
end

---Parse `go tool compile -S` stderr. Each instruction line carries an inline
---`(path:LINE)` reference; header lines (`"".foo STEXT ...`) have none and
---are not attributed.
---@param asm string
---@param range asmview.Range
---@param src_basename string
---@return asmview.LineMap
local function parse_go(asm, range, src_basename)
  local by_source = {}
  local by_asm = {}
  local unmapped = 0
  local idx = 0

  for line in (asm .. "\n"):gmatch("([^\n]*)\n") do
    idx = idx + 1
    if idx > MAX_ASM_LINES then
      return { by_source = {}, by_asm = {}, unmapped_asm_count = unmapped }
    end
    -- Match any `(path:LINE)` reference. Any file whose basename does not
    -- match `src_basename` (go runtime assembly, inlined stdlib sources)
    -- counts as unmapped — important so the UX can later surface how much
    -- of the output came from inlining.
    local path, line_s = line:match("%(([^%s():]+):(%d+)%)")
    if path and line_s then
      if path_ends_with(path, src_basename) then
        local src_line = tonumber(line_s) + range.start_line - 1
        by_source[src_line] = by_source[src_line] or {}
        table.insert(by_source[src_line], idx)
        if by_asm[idx] == nil then
          by_asm[idx] = src_line
        end
      else
        unmapped = unmapped + 1
      end
    end
  end

  return { by_source = by_source, by_asm = by_asm, unmapped_asm_count = unmapped }
end

---Build the source→asm mapping for a compile result.
---@param asm string Full asm text from asmview.Result.
---@param range asmview.Range Compiled range (for the start_line offset).
---@param filetype "c"|"cpp"|"rust"|"go"
---@param src_basename string Snippet filename (basename only — "snippet.c").
---@param deps? table Reserved for test injection.
---@return asmview.LineMap
function M.build(asm, range, filetype, src_basename, deps)
  assert(type(asm) == "string", "asm must be a string")
  assert(type(range) == "table" and type(range.start_line) == "number", "range.start_line required")
  assert(type(filetype) == "string", "filetype required")
  assert(type(src_basename) == "string" and src_basename ~= "", "src_basename required")
  _ = deps -- reserved; present for parity with other asmview modules

  if filetype == "go" then
    return parse_go(asm, range, src_basename)
  end
  return parse_loc(asm, range, src_basename)
end

return M
