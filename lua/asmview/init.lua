-- lua/asmview/init.lua
-- Public API for asmview.nvim.

local M = {}

---Setup the plugin. Safe to call multiple times; last-write-wins.
---@param opts? asmview.Config
---@param deps? table
---@return boolean success
function M.setup(opts, deps)
  deps = deps or {}
  local config = deps.config or require("asmview.config")
  return config.setup(opts, deps)
end

---Return the current configuration.
---@param deps? table
---@return asmview.Config
function M.get_config(deps)
  deps = deps or {}
  local config = deps.config or require("asmview.config")
  return config.get()
end

---Collapse user-command context into a range request understood by `range.resolve`.
---@param cmd_args table nvim user-command opts (contains line1, line2, range, ...)
---@return { line1?: integer, line2?: integer, visual?: boolean }
local function cmd_opts(cmd_args)
  if not cmd_args then
    return {}
  end
  local out = { line1 = cmd_args.line1, line2 = cmd_args.line2 }
  -- `range == 2` means an explicit range was passed; '<,'> comes from visual.
  if cmd_args.range == 2 then
    out.visual = true
  end
  return out
end

---Fire asmview for the current buffer. Returns false if we bailed early
---(unsupported filetype, missing compiler, no function around cursor, ...).
---Diagnostics are surfaced via vim.notify.
---@param cmd_args? table nvim user-command opts
---@param deps? table
---@return boolean started
function M.show(cmd_args, deps)
  deps = deps or {}
  local config = deps.config or require("asmview.config")
  local detect = deps.detect or require("asmview.detect")
  local range_mod = deps.range or require("asmview.range")
  local window = deps.window or require("asmview.window")
  local compile = deps.compile or require("asmview.compile")
  local notify = deps.notify or vim.notify

  local cfg = config.get()
  local bufnr = vim.api.nvim_get_current_buf()
  local ft = detect.language_for_buffer(bufnr, deps)
  if not ft then
    notify("asmview: filetype not supported (want c, cpp, or rust)", vim.log.levels.WARN, { title = cfg.notify_title })
    return false
  end

  local spec = cfg.compilers[ft]
  if not detect.has_executable(spec.cmd, deps) then
    notify("asmview: compiler not found on PATH: " .. spec.cmd, vim.log.levels.ERROR, { title = cfg.notify_title })
    return false
  end

  local resolved, err = range_mod.resolve(bufnr, cmd_opts(cmd_args))
  if not resolved then
    notify("asmview: " .. (err or "could not resolve range"), vim.log.levels.WARN, { title = cfg.notify_title })
    return false
  end

  local cflags = {}
  if cfg.use_compile_commands and (ft == "c" or ft == "cpp") then
    local src_path = vim.api.nvim_buf_get_name(bufnr)
    if src_path ~= "" then
      local start_dir = vim.fn.fnamemodify(src_path, ":h")
      local db = detect.find_compile_commands(start_dir, cfg.compile_commands_search_depth, deps)
      if db then
        cflags = detect.flags_for_source(db, src_path, deps)
      end
    end
  end

  window.open(bufnr, resolved, ft, cflags, cfg, compile)
  return true
end

return M
