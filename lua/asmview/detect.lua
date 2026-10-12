-- lua/asmview/detect.lua
-- Language detection and compile_commands.json lookup

local M = {}

local FT_MAP = {
  c = "c",
  cpp = "cpp",
  cxx = "cpp",
  objcpp = "cpp",
  rust = "rust",
}

---Map a Neovim filetype to one asmview understands, or nil.
---@param ft string
---@return "c"|"cpp"|"rust"|nil
function M.map_filetype(ft)
  return FT_MAP[ft]
end

---Resolve the asmview language for a buffer. Returns nil if unsupported.
---@param bufnr integer
---@param deps? table
---@return "c"|"cpp"|"rust"|nil
function M.language_for_buffer(bufnr, deps)
  deps = deps or {}
  local get_option = deps.nvim_get_option_value or vim.api.nvim_get_option_value
  local ft = get_option("filetype", { buf = bufnr })
  return M.map_filetype(ft)
end

---Return true if `cmd` resolves on PATH.
---@param cmd string
---@param deps? table
---@return boolean
function M.has_executable(cmd, deps)
  deps = deps or {}
  local exe = deps.executable or vim.fn.executable
  return exe(cmd) == 1
end

---Walk up from `start_dir` looking for `compile_commands.json`.
---Capped at `max_depth` ascents to keep the loop bounded on
---pathological filesystems (e.g. a corrupted cwd pointing at `/`).
---@param start_dir string Absolute directory
---@param max_depth integer Maximum parent hops (>= 0)
---@param deps? table
---@return string? absolute_path
function M.find_compile_commands(start_dir, max_depth, deps)
  assert(type(start_dir) == "string" and start_dir ~= "", "start_dir required")
  assert(type(max_depth) == "number" and max_depth >= 0, "max_depth must be >= 0")

  deps = deps or {}
  local readable = deps.filereadable or vim.fn.filereadable
  local fnamemodify = deps.fnamemodify or vim.fn.fnamemodify

  local dir = start_dir
  for _ = 0, max_depth do
    local candidate = dir .. "/compile_commands.json"
    if readable(candidate) == 1 then
      return candidate
    end
    local parent = fnamemodify(dir, ":h")
    if parent == dir then
      return nil
    end
    dir = parent
  end
  return nil
end

---Extract compile flags for `source_path` from a compile_commands.json file.
---Returns an empty table if the file cannot be read or the path is absent.
---Only flags are returned (compiler and output are dropped).
---@param db_path string
---@param source_path string Absolute path to the source file
---@param deps? table
---@return string[]
function M.flags_for_source(db_path, source_path, deps)
  deps = deps or {}
  local read_file = deps.read_file
    or function(path)
      local fh = io.open(path, "r")
      if not fh then
        return nil
      end
      local content = fh:read("*a")
      fh:close()
      return content
    end

  local content = read_file(db_path)
  if not content or content == "" then
    return {}
  end

  local ok, decoded = pcall(vim.json.decode, content)
  if not ok or type(decoded) ~= "table" then
    return {}
  end

  for _, entry in ipairs(decoded) do
    if entry.file == source_path then
      if type(entry.arguments) == "table" then
        return M._filter_flags(entry.arguments, source_path)
      end
      if type(entry.command) == "string" then
        local parts = vim.split(entry.command, "%s+", { trimempty = true })
        return M._filter_flags(parts, source_path)
      end
    end
  end
  return {}
end

---Drop the compiler argv[0], the `-o <path>` pair, the input file, and any `-O*`
---flag (asmview owns -O). Also drop `-c` and `-S` — asmview sets those.
---@param argv string[]
---@param source_path string
---@return string[]
function M._filter_flags(argv, source_path)
  local out = {}
  local skip_next = false
  for i, arg in ipairs(argv) do
    if i == 1 then
    -- argv[0] is the compiler, discard
    elseif skip_next then
      skip_next = false
    elseif arg == "-o" then
      skip_next = true
    elseif arg == "-c" or arg == "-S" then
    -- asmview adds -S itself; -c is incompatible
    elseif arg:match("^%-O") then
    -- optimization level is owned by asmview
    elseif arg == source_path then
    -- input file is appended by asmview
    else
      table.insert(out, arg)
    end
  end
  return out
end

return M
