-- lua/asmview/window.lua
-- Vertical-split asm window that renders the compiler output next to the
-- source buffer. Owns per-asm-buffer state, the +/-/R/q buffer-local
-- keymaps, and the source→asm cursor-mirror highlighting.

local M = {}

---@class asmview.Window
---@field bufnr integer Scratch buffer displaying asm
---@field win integer Window handle (right-side vsplit)
---@field source_bufnr integer Buffer we compiled from
---@field source_win integer Window the vsplit was anchored to
---@field range asmview.Range Range we compiled
---@field opt_level string Current optimization level
---@field cflags string[] Flags harvested from compile_commands.json (frozen on open)
---@field go_header? string Go package + import block (Go only, frozen on open)
---@field filetype "c"|"cpp"|"rust"|"go"
---@field busy boolean True while a compile is in flight
---@field src_basename string Temp snippet basename ("snippet.c" / "snippet.go" / ...)
---@field line_map? asmview.LineMap Last built source→asm map (nil before first render)
---@field start_mark? integer Extmark on source_bufnr tracking range.start_line across edits
---@field end_mark? integer Extmark on source_bufnr tracking range.end_line across edits

local State = {}

-- Number of leader rows render() writes before the asm body (header + blank
-- separator). mapping.build returns 1-based indices into the raw asm text;
-- highlight.attach uses this constant to shift those indices into
-- 0-based buffer rows.
local ASM_BODY_OFFSET = 2

-- Namespace for the two extmarks that track the compiled range across edits
-- in the source buffer. Keeping them in a dedicated namespace lets BufWipeout
-- clear the pair without touching highlights or other plugins' marks.
local RANGE_NS = vim.api.nvim_create_namespace("asmview_range")

---Read the extmark-tracked range from the source buffer and update
---`state.range.start_line` / `end_line` to the current positions. On any
---failure (marks deleted, source buffer gone, obviously-broken range), the
---cached range is left as-is so the recompile still runs with the last
---known-good values.
---@param state asmview.Window
local function refresh_range(state)
  if not state.start_mark or not state.end_mark then
    return
  end
  if not vim.api.nvim_buf_is_valid(state.source_bufnr) then
    return
  end
  local start = vim.api.nvim_buf_get_extmark_by_id(state.source_bufnr, RANGE_NS, state.start_mark, {})
  local stop = vim.api.nvim_buf_get_extmark_by_id(state.source_bufnr, RANGE_NS, state.end_mark, {})
  if not start[1] or not stop[1] then
    return
  end
  -- `nvim_buf_set_lines(0, -1, ...)` on a buffer wholly containing the marks
  -- drifts them one row past the last line even though the buffer never
  -- grew — fetch would then return an empty slice. Clamp to [0, last_row]
  -- so a full-buffer replace reads as "range still at the top", and so a
  -- delete past the end degrades to a sliver instead of an empty compile.
  local last_row = vim.api.nvim_buf_line_count(state.source_bufnr) - 1
  local start_row = math.max(0, math.min(start[1], last_row))
  local end_row = math.max(start_row, math.min(stop[1], last_row))
  state.range.start_line = start_row + 1
  state.range.end_line = end_row + 1
end

---Return the state object attached to buffer `bufnr`, or nil.
---@param bufnr integer
---@return asmview.Window?
local function get_state(bufnr)
  return State[bufnr]
end

---Snippet basename the compile module writes for `filetype`. Mapping needs
---the exact basename to filter .loc directives.
---@param filetype "c"|"cpp"|"rust"|"go"
---@return string
local function basename_for(filetype)
  if filetype == "rust" then
    return "snippet.rs"
  end
  return "snippet." .. filetype
end

---Replace the asm buffer contents and header, then rebuild the source→asm
---line map and attach the highlight autocmd.
---@param state asmview.Window
---@param cfg asmview.Config
---@param result asmview.Result
---@param mapping table asmview.mapping module
---@param highlight table asmview.highlight module
local function render(state, cfg, result, mapping, highlight)
  local header = string.format(
    "; asmview — %s  opt=-O%s  syntax=%s  exit=%d  %dms%s",
    state.range.label,
    state.opt_level,
    cfg.syntax,
    result.exit_code,
    result.duration_ms,
    result.ok and "" or "  [FAILED]"
  )
  local lines = { header, "" }
  for line in (result.asm .. "\n"):gmatch("([^\n]*)\n") do
    table.insert(lines, line)
  end
  vim.bo[state.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
  vim.bo[state.bufnr].modifiable = false

  state.line_map = mapping.build(result.asm, state.range, state.filetype, state.src_basename)
  highlight.attach(state.source_bufnr, state.bufnr, ASM_BODY_OFFSET, state.line_map, cfg)
end

---Cycle `current` within `levels` by `delta` positions, clamped to the array
---(no wraparound — the upstream behavior is similarly bounded). Public only
---so specs can exercise it; not part of the plugin's external contract.
---@package
---@param levels string[]
---@param current string
---@param delta integer
---@return string
function M.cycle_opt(levels, current, delta)
  local idx = 1
  for i, lvl in ipairs(levels) do
    if lvl == current then
      idx = i
      break
    end
  end
  local new_idx = math.min(#levels, math.max(1, idx + delta))
  return levels[new_idx]
end

---Fire a compile for `state` and re-render on completion.
---@param state asmview.Window
---@param cfg asmview.Config
---@param compile table asmview.compile module (injectable)
---@param mapping table asmview.mapping module
---@param highlight table asmview.highlight module
local function recompile(state, cfg, compile, mapping, highlight)
  if state.busy then
    return
  end
  -- Guard against the source buffer having been wiped between keymap press
  -- and now. `nvim_buf_get_name` on an invalid bufnr raises; the user would
  -- see a traceback on the next `R` after `:bdelete`-ing the source file.
  if not vim.api.nvim_buf_is_valid(state.source_bufnr) then
    vim.bo[state.bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, {
      "; asmview — source buffer no longer valid",
    })
    vim.bo[state.bufnr].modifiable = false
    return
  end
  state.busy = true
  vim.bo[state.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, { "; asmview — compiling (-O" .. state.opt_level .. ")..." })
  vim.bo[state.bufnr].modifiable = false

  -- Re-fetch the current content of the source range so that `R` after an
  -- edit compiles what the user sees, not the snapshot frozen at open-time.
  -- Also update start_line/end_line from the tracking extmarks first — the
  -- cached values go stale as soon as the user inserts or deletes a line
  -- inside the function, which truncates the fetched source and typically
  -- surfaces as a "expected '}'" compile error.
  refresh_range(state)
  local lines = vim.api.nvim_buf_get_lines(state.source_bufnr, state.range.start_line - 1, state.range.end_line, false)
  local current_source = table.concat(lines, "\n")

  -- An unsaved buffer returns "" from nvim_buf_get_name, and
  -- fnamemodify("", ":h") yields "." — which resolves against nvim's own
  -- cwd, usually not where the user expected the compile to run. Fall back
  -- to vim.fn.getcwd() in that case so the compiler sees the project root.
  local source_name = vim.api.nvim_buf_get_name(state.source_bufnr)
  local cwd = source_name ~= "" and vim.fn.fnamemodify(source_name, ":h") or vim.fn.getcwd()

  ---@type asmview.Request
  local request = {
    bufnr = state.source_bufnr,
    filetype = state.filetype,
    source = current_source,
    opt_level = state.opt_level,
    cwd = cwd,
    cflags = state.cflags,
    go_header = state.go_header,
  }
  compile.run(request, cfg, function(result)
    state.busy = false
    if not vim.api.nvim_buf_is_valid(state.bufnr) then
      return
    end
    render(state, cfg, result, mapping, highlight)
  end)
end

---Bind buffer-local maps for the asm window.
---@param state asmview.Window
---@param cfg asmview.Config
---@param compile table
---@param mapping table
---@param highlight table
local function bind_keys(state, cfg, compile, mapping, highlight)
  local km = cfg.keymaps
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = state.bufnr, silent = true, nowait = true, desc = desc })
  end

  map(km.increase_opt, function()
    local next_lvl = M.cycle_opt(cfg.opt_levels, state.opt_level, 1)
    if next_lvl ~= state.opt_level then
      state.opt_level = next_lvl
      recompile(state, cfg, compile, mapping, highlight)
    end
  end, "asmview: increase optimization")

  map(km.decrease_opt, function()
    local next_lvl = M.cycle_opt(cfg.opt_levels, state.opt_level, -1)
    if next_lvl ~= state.opt_level then
      state.opt_level = next_lvl
      recompile(state, cfg, compile, mapping, highlight)
    end
  end, "asmview: decrease optimization")

  map(km.rerun, function()
    recompile(state, cfg, compile, mapping, highlight)
  end, "asmview: rerun")

  map(km.close, function()
    if vim.api.nvim_win_is_valid(state.win) then
      vim.api.nvim_win_close(state.win, true)
    end
  end, "asmview: close")
end

---Open the asm vsplit for `source_bufnr` and kick off the first compile.
---Focus stays in the source window; the user does not have to :wincmd back
---after `:Asm`.
---@param source_bufnr integer
---@param range asmview.Range
---@param filetype "c"|"cpp"|"rust"|"go"
---@param cflags string[] Flags harvested from compile_commands.json (C/C++ only)
---@param go_header? string Go package + import block (Go only)
---@param cfg asmview.Config
---@param compile table asmview.compile module
---@param deps? table Override hooks: { mapping, highlight, source_win }.
---@return asmview.Window
function M.open(source_bufnr, range, filetype, cflags, go_header, cfg, compile, deps)
  deps = deps or {}
  local mapping = deps.mapping or require("asmview.mapping")
  local highlight = deps.highlight or require("asmview.highlight")
  local source_win = deps.source_win or vim.api.nvim_get_current_win()

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].filetype = "asm"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false

  local win = vim.api.nvim_open_win(bufnr, false, { split = "right", win = source_win })
  assert(vim.api.nvim_win_is_valid(win), "asmview: nvim_open_win returned an invalid handle")
  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false

  -- Track the range with two extmarks on the source buffer so edits inside
  -- or above the function don't produce a truncated snippet on the next
  -- recompile. Only set when the range actually falls within the buffer —
  -- `nvim_buf_set_extmark` raises on an out-of-range row, and clamping to a
  -- valid row would silently rewrite state.range to the clamped values the
  -- next time refresh_range reads the marks back. Out-of-range ranges leave
  -- the marks nil and refresh_range becomes a no-op (recompile uses the
  -- cached range as before this feature landed).
  local start_mark, end_mark
  if vim.api.nvim_buf_is_valid(source_bufnr) then
    local line_count = vim.api.nvim_buf_line_count(source_bufnr)
    if range.start_line >= 1 and range.end_line >= range.start_line and range.end_line <= line_count then
      start_mark = vim.api.nvim_buf_set_extmark(source_bufnr, RANGE_NS, range.start_line - 1, 0, {})
      end_mark = vim.api.nvim_buf_set_extmark(source_bufnr, RANGE_NS, range.end_line - 1, 0, { right_gravity = true })
    end
  end

  ---@type asmview.Window
  local state = {
    bufnr = bufnr,
    win = win,
    source_bufnr = source_bufnr,
    source_win = source_win,
    range = range,
    opt_level = cfg.default_opt,
    cflags = cflags,
    go_header = go_header,
    filetype = filetype,
    busy = false,
    src_basename = basename_for(filetype),
    line_map = nil,
    start_mark = start_mark,
    end_mark = end_mark,
  }
  State[bufnr] = state

  local autosave_group = vim.api.nvim_create_augroup("asmview_autosave_" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = autosave_group,
    buffer = source_bufnr,
    desc = "asmview: recompile when the source buffer is saved",
    callback = function()
      -- Guard against stray fires after the asm buffer has been wiped —
      -- the BufWipeout cleanup below deletes the group, but a BufWritePost
      -- queued inside the same event cycle could race.
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      recompile(state, cfg, compile, mapping, highlight)
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = vim.api.nvim_create_augroup("asmview_window_" .. bufnr, { clear = true }),
    buffer = bufnr,
    once = true,
    desc = "asmview: drop per-window state on buffer wipe",
    callback = function()
      highlight.detach(source_bufnr)
      pcall(vim.api.nvim_del_augroup_by_id, autosave_group)
      if start_mark and vim.api.nvim_buf_is_valid(source_bufnr) then
        pcall(vim.api.nvim_buf_del_extmark, source_bufnr, RANGE_NS, start_mark)
      end
      if end_mark and vim.api.nvim_buf_is_valid(source_bufnr) then
        pcall(vim.api.nvim_buf_del_extmark, source_bufnr, RANGE_NS, end_mark)
      end
      State[bufnr] = nil
    end,
  })

  bind_keys(state, cfg, compile, mapping, highlight)
  recompile(state, cfg, compile, mapping, highlight)
  return state
end

---Expose state lookup for tests.
---@param bufnr integer
---@return asmview.Window?
function M._state(bufnr)
  return get_state(bufnr)
end

return M
