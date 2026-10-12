-- lua/asmview/health.lua
-- :checkhealth asmview

local M = {}

local function check_exe(name)
  if vim.fn.executable(name) == 1 then
    vim.health.ok(name .. " found on PATH")
  else
    vim.health.warn(name .. " not found on PATH")
  end
end

function M.check()
  vim.health.start("asmview.nvim")

  local ok, config = pcall(require, "asmview.config")
  if not ok then
    vim.health.error("asmview.config failed to load: " .. tostring(config))
    return
  end
  vim.health.ok("configuration loaded")

  local cfg = config.get()
  if not cfg.compilers then
    vim.health.error("configuration missing compilers table")
    return
  end

  vim.health.start("asmview — compilers")
  check_exe(cfg.compilers.c.cmd)
  check_exe(cfg.compilers.cpp.cmd)
  check_exe(cfg.compilers.rust.cmd)

  vim.health.start("asmview — demanglers (optional)")
  if cfg.demangle then
    check_exe("c++filt")
    check_exe("rustfilt")
  else
    vim.health.info("demangle disabled")
  end

  vim.health.start("asmview — treesitter")
  local ok_ts = pcall(require, "vim.treesitter")
  if ok_ts then
    vim.health.ok("vim.treesitter available (used for function detection)")
  else
    vim.health.warn("vim.treesitter unavailable — falling back to brace-balanced scan")
  end
end

return M
