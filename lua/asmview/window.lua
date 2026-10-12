-- lua/asmview/window.lua
-- Floating window that renders the compiler output and holds
-- buffer-local keymaps for +/-/R/q.

local M = {}

---@class asmview.Window
---@field bufnr integer Scratch buffer displaying asm
---@field win integer Window handle
---@field source_bufnr integer Buffer we compiled from
---@field range asmview.Range Range we compiled
---@field opt_level string Current optimization level
---@field cflags string[] Flags harvested from compile_commands.json (frozen on open)
---@field go_header? string Go package + import block (Go only, frozen on open)
---@field filetype "c"|"cpp"|"rust"|"go"
---@field busy boolean True while a compile is in flight

local State = {}

---Return the state object attached to buffer `bufnr`, or nil.
---@param bufnr integer
---@return asmview.Window?
local function get_state(bufnr)
  return State[bufnr]
end

---Compute floating-window geometry from config ratios.
---Prefers the ratio-derived size (clamped at a readable minimum), but
---never exceeds the terminal's available cells minus a small margin —
---nvim_open_win errors if width/height exceed `vim.o.columns`/`lines`.
---@param cfg asmview.Config
---@return table opts for nvim_open_win
local function float_opts(cfg)
  local max_width = math.max(1, vim.o.columns - 2)
  local max_height = math.max(1, vim.o.lines - 2)
  local pref_width = math.max(40, math.floor(vim.o.columns * cfg.float.width_ratio))
  local pref_height = math.max(10, math.floor(vim.o.lines * cfg.float.height_ratio))
  local width = math.min(pref_width, max_width)
  local height = math.min(pref_height, max_height)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)
  return {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = cfg.float.border,
  }
end

---Replace the asm buffer contents and header.
---@param state asmview.Window
---@param cfg asmview.Config
---@param result asmview.Result
local function render(state, cfg, result)
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
  vim.api.nvim_set_option_value("modifiable", true, { buf = state.bufnr })
  vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = state.bufnr })
end

---Cycle `current` within `levels` by `delta` positions, clamped to the array
---(no wraparound — the upstream behavior is similarly bounded).
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
local function recompile(state, cfg, compile)
  if state.busy then
    return
  end
  state.busy = true
  vim.api.nvim_set_option_value("modifiable", true, { buf = state.bufnr })
  vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, { "; asmview — compiling (-O" .. state.opt_level .. ")..." })
  vim.api.nvim_set_option_value("modifiable", false, { buf = state.bufnr })

  ---@type asmview.Request
  local request = {
    bufnr = state.source_bufnr,
    filetype = state.filetype,
    source = state.range.source,
    opt_level = state.opt_level,
    cwd = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(state.source_bufnr), ":h"),
    cflags = state.cflags,
    go_header = state.go_header,
  }
  compile.run(request, cfg, function(result)
    state.busy = false
    if not vim.api.nvim_buf_is_valid(state.bufnr) then
      return
    end
    render(state, cfg, result)
  end)
end

---Bind buffer-local maps for the asm window.
---@param state asmview.Window
---@param cfg asmview.Config
---@param compile table
local function bind_keys(state, cfg, compile)
  local km = cfg.keymaps
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = state.bufnr, silent = true, nowait = true, desc = desc })
  end

  map(km.increase_opt, function()
    local next_lvl = M.cycle_opt(cfg.opt_levels, state.opt_level, 1)
    if next_lvl ~= state.opt_level then
      state.opt_level = next_lvl
      recompile(state, cfg, compile)
    end
  end, "asmview: increase optimization")

  map(km.decrease_opt, function()
    local next_lvl = M.cycle_opt(cfg.opt_levels, state.opt_level, -1)
    if next_lvl ~= state.opt_level then
      state.opt_level = next_lvl
      recompile(state, cfg, compile)
    end
  end, "asmview: decrease optimization")

  map(km.rerun, function()
    recompile(state, cfg, compile)
  end, "asmview: rerun")

  map(km.close, function()
    if vim.api.nvim_win_is_valid(state.win) then
      vim.api.nvim_win_close(state.win, true)
    end
  end, "asmview: close")
end

---Open a floating window for `request` and kick off the first compile.
---@param source_bufnr integer
---@param range asmview.Range
---@param filetype "c"|"cpp"|"rust"|"go"
---@param cflags string[] Flags harvested from compile_commands.json (C/C++ only)
---@param go_header? string Go package + import block (Go only)
---@param cfg asmview.Config
---@param compile table asmview.compile module
---@return asmview.Window
function M.open(source_bufnr, range, filetype, cflags, go_header, cfg, compile)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("filetype", "asm", { buf = bufnr })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = bufnr })
  vim.api.nvim_set_option_value("swapfile", false, { buf = bufnr })

  local win = vim.api.nvim_open_win(bufnr, true, float_opts(cfg))
  vim.api.nvim_set_option_value("wrap", false, { win = win })
  vim.api.nvim_set_option_value("number", false, { win = win })
  vim.api.nvim_set_option_value("relativenumber", false, { win = win })

  ---@type asmview.Window
  local state = {
    bufnr = bufnr,
    win = win,
    source_bufnr = source_bufnr,
    range = range,
    opt_level = cfg.default_opt,
    cflags = cflags,
    go_header = go_header,
    filetype = filetype,
    busy = false,
  }
  State[bufnr] = state

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    once = true,
    callback = function()
      State[bufnr] = nil
    end,
  })

  bind_keys(state, cfg, compile)
  recompile(state, cfg, compile)
  return state
end

---Expose state lookup for tests.
---@param bufnr integer
---@return asmview.Window?
function M._state(bufnr)
  return get_state(bufnr)
end

return M
