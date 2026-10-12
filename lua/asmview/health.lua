-- lua/asmview/health.lua
-- :checkhealth asmview

local M = {}

---Run the health check. Takes an optional deps table so tests can inject
---a fake `health` surface instead of monkey-patching `vim.health` globally.
---@param deps? { health?: table, executable?: fun(name:string):integer, config?: table }
function M.check(deps)
  deps = deps or {}
  local health = deps.health or vim.health
  local executable = deps.executable or vim.fn.executable

  local function check_exe(name)
    if executable(name) == 1 then
      health.ok(name .. " found on PATH")
    else
      health.warn(name .. " not found on PATH")
    end
  end

  health.start("asmview.nvim")

  local config = deps.config
  if not config then
    local ok, loaded = pcall(require, "asmview.config")
    if not ok then
      health.error("asmview.config failed to load: " .. tostring(loaded))
      return
    end
    config = loaded
  end
  health.ok("configuration loaded")

  local cfg = config.get()
  if not cfg.compilers then
    health.error("configuration missing compilers table")
    return
  end

  health.start("asmview — compilers")
  check_exe(cfg.compilers.c.cmd)
  check_exe(cfg.compilers.cpp.cmd)
  check_exe(cfg.compilers.rust.cmd)
  check_exe(cfg.compilers.go.cmd)

  health.start("asmview — demanglers (optional)")
  if cfg.demangle then
    check_exe("c++filt")
    check_exe("rustfilt")
  else
    health.info("demangle disabled")
  end

  health.start("asmview — treesitter")
  local ok_ts = pcall(require, "vim.treesitter")
  if ok_ts then
    health.ok("vim.treesitter available (used for function detection)")
  else
    health.warn("vim.treesitter unavailable — falling back to brace-balanced scan")
  end
end

return M
