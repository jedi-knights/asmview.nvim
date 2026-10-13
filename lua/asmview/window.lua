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

local State = {}

-- Number of leader rows render() writes before the asm body (header + blank
-- separator). mapping.build returns 1-based indices into the raw asm text;
-- highlight.attach uses this constant to shift those indices into
-- 0-based buffer rows.
local ASM_BODY_OFFSET = 2

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
