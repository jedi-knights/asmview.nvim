-- lua/asmview/config.lua
-- Configuration management for asmview.nvim

local M = {}

---@type asmview.Config
local default_config = {
  compilers = {
    c = { cmd = "cc", extra_args = {} },
    cpp = { cmd = "c++", extra_args = {} },
    rust = { cmd = "rustc", extra_args = {} },
    go = { cmd = "go", extra_args = {} },
  },
  opt_levels = { "0", "1", "2", "3", "s", "z" },
  default_opt = "2",
  syntax = "intel",
  demangle = true,
  use_compile_commands = true,
  compile_commands_search_depth = 6,
  float = {
    width_ratio = 0.8,
    height_ratio = 0.8,
    border = "rounded",
  },
  keymaps = {
    increase_opt = "+",
    decrease_opt = "-",
    rerun = "R",
    close = "q",
  },
  notify_title = "asmview.nvim",
  log_level = vim.log.levels.INFO,
}

---@type asmview.Config
local config = vim.deepcopy(default_config)

---Validate configuration. Throws on failure so callers can wrap with pcall.
---@param cfg asmview.Config
local function validate(cfg)
  vim.validate({
    compilers = { cfg.compilers, "table" },
    opt_levels = { cfg.opt_levels, "table" },
    default_opt = { cfg.default_opt, "string" },
    syntax = { cfg.syntax, "string" },
    demangle = { cfg.demangle, "boolean" },
    use_compile_commands = { cfg.use_compile_commands, "boolean" },
    compile_commands_search_depth = { cfg.compile_commands_search_depth, "number" },
    float = { cfg.float, "table" },
    keymaps = { cfg.keymaps, "table" },
    notify_title = { cfg.notify_title, "string" },
    log_level = { cfg.log_level, "number" },
  })

  if cfg.syntax ~= "intel" and cfg.syntax ~= "att" then
    error('syntax must be "intel" or "att", got ' .. tostring(cfg.syntax))
  end

  if #cfg.opt_levels == 0 then
    error("opt_levels must contain at least one entry")
  end

  local found = false
  for _, lvl in ipairs(cfg.opt_levels) do
    if lvl == cfg.default_opt then
      found = true
      break
    end
  end
  if not found then
    error("default_opt " .. cfg.default_opt .. " not present in opt_levels")
  end

  if cfg.compile_commands_search_depth < 0 then
    error("compile_commands_search_depth must be >= 0")
  end

  for _, lang in ipairs({ "c", "cpp", "rust", "go" }) do
    local spec = cfg.compilers[lang]
    if type(spec) ~= "table" or type(spec.cmd) ~= "string" or spec.cmd == "" then
      error("compilers." .. lang .. ".cmd must be a non-empty string")
    end
    if type(spec.extra_args) ~= "table" then
      error("compilers." .. lang .. ".extra_args must be a table")
    end
  end

  if cfg.float.width_ratio <= 0 or cfg.float.width_ratio > 1 then
    error("float.width_ratio must be in (0, 1]")
  end
  if cfg.float.height_ratio <= 0 or cfg.float.height_ratio > 1 then
    error("float.height_ratio must be in (0, 1]")
  end
end

---Apply user overrides on top of the defaults.
---@param opts? asmview.Config
---@param deps? table
---@return boolean success, string? error
function M.setup(opts, deps)
  deps = deps or {}
  local notify = deps.notify or vim.notify
  local merge = deps.tbl_deep_extend or vim.tbl_deep_extend

  local candidate = merge("force", vim.deepcopy(default_config), opts or {})
  local ok, err = pcall(validate, candidate)
  if not ok then
    notify("asmview: invalid configuration — " .. tostring(err), vim.log.levels.ERROR, { title = "asmview.nvim" })
    return false, tostring(err)
  end

  config = candidate
  return true
end

---Return the live configuration.
---@return asmview.Config
function M.get()
  return config
end

---Return the defaults (useful in tests to detect drift).
---@return asmview.Config
function M.defaults()
  return vim.deepcopy(default_config)
end

return M
