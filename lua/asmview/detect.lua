-- lua/asmview/detect.lua
-- Language detection and compile_commands.json lookup

local M = {}

local FT_MAP = {
  c = "c",
  cpp = "cpp",
  cxx = "cpp",
  objcpp = "cpp",
  rust = "rust",
  go = "go",
}

-- Scan at most this many lines when harvesting a Go buffer's package + imports.
-- Imports always sit near the top of the file, so a small cap is safe and keeps
-- the loop bounded on multi-megabyte generated sources. If a buffer somehow has
-- its import block past line 500 (very large auto-generated preamble), the
-- block is dropped and the snippet will fail to compile — not silent incorrect
-- behavior; the user sees the compile error in the asm window.
local GO_HEADER_SCAN_LIMIT = 500

-- Parsed compile_commands.json keyed by `db_path`. Each cached value is a
-- `{ by_file = { [source_path] = string[] (flags) } }` index built on the
-- first read, so subsequent `flags_for_source` calls are O(1) and never
-- re-read the file from disk during a session.
--
-- The first read is still a synchronous `io.open` + `read("*a")`, which is a
-- documented pragmatic trade-off: `compile_commands.json` is a project-level
-- file read once per Neovim session, typical size is < 1 MB, and the show()
-- pipeline this feeds is itself synchronous up to the compile step. Moving
-- it to `uv.fs_open` + callback would ripple through the whole show() path
-- for a cost that materializes only on hostile input (hundred-MB DBs).
local _compile_commands_cache = {}

-- Cap on the number of argv tokens accepted from a single compile_commands.json
-- entry. Real compile invocations rarely exceed ~100 flags; this guards
-- against a malformed or adversarial database with a pathologically-long
-- `arguments` array per rules/algorithmic-complexity.md on bounded loops
-- over external input.
local MAX_ARGV_LEN = 512

-- Cap on the size of compile_commands.json read into memory. 10 MB is well
-- above the typical project size (< 1 MB) and above every real-world example
-- the author has seen; refusing larger databases up-front is safer than
-- synchronously parsing a hundred-MB file on the main thread.
local MAX_COMPILE_COMMANDS_SIZE = 10 * 1024 * 1024

-- Cap on the number of entries in a compile_commands.json after parsing.
-- Even a 10 MB file (MAX_COMPILE_COMMANDS_SIZE) can hold millions of tiny
-- entries; this guards the index-building loop separately per the
-- bounded-loops-on-external-input rule.
local MAX_COMPILE_COMMANDS_ENTRIES = 100000

---Map a Neovim filetype to one asmview understands, or nil.
---@param ft string
---@return "c"|"cpp"|"rust"|"go"|nil
function M.map_filetype(ft)
  return FT_MAP[ft]
end

---Resolve the asmview language for a buffer. Returns nil if unsupported.
---@param bufnr integer
---@param deps? table
---@return "c"|"cpp"|"rust"|"go"|nil
function M.language_for_buffer(bufnr, deps)
  deps = deps or {}
  local get_option = deps.nvim_get_option_value or vim.api.nvim_get_option_value
  local ft = get_option("filetype", { buf = bufnr })
  return M.map_filetype(ft)
end

---Extract a `package main` declaration + the buffer's `import` block, ready
---to prepend to a Go snippet so the snippet compiles as a standalone module.
---The user's original `package foo` is deliberately replaced with `package main`
---because the asm view compiles the function in isolation — reaching cross-file
---unexported identifiers from the real package is out of scope.
---
---Scans at most GO_HEADER_SCAN_LIMIT lines; imports in Go always sit near the
---top of the file so the cap is safe. Returns `"package main\n"` when no
---import block is found.
---@param bufnr integer
---@param deps? table
---@return string
function M.go_header(bufnr, deps)
  deps = deps or {}
  local get_lines = deps.get_lines or vim.api.nvim_buf_get_lines
  local lines = get_lines(bufnr, 0, GO_HEADER_SCAN_LIMIT, false)

  local out = { "package main" }
  local in_import_block = false
  for _, line in ipairs(lines) do
    if in_import_block then
      table.insert(out, line)
      if line:match("^%s*%)") then
        in_import_block = false
      end
    elseif line:match('^%s*import%s+"') or line:match("^%s*import%s+`") then
      table.insert(out, line)
    elseif line:match("^%s*import%s*%(") then
      in_import_block = true
      table.insert(out, line)
    end
  end
  return table.concat(out, "\n") .. "\n"
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

---Build a `{ source_path -> filtered_flags }` index from a decoded
---compile_commands.json array. One O(N) pass, then every subsequent
---lookup for any source file is O(1).
---@param decoded table
---@return table<string, string[]>
local function build_compile_commands_index(decoded)
  local by_file = {}
  if #decoded > MAX_COMPILE_COMMANDS_ENTRIES then
    -- Refuse to index pathologically-large databases rather than loop over
    -- the whole array; caller gets an empty index and the user hits the
    -- no-flags fallback (which still produces useful asm).
    return by_file
  end
  for _, entry in ipairs(decoded) do
    if type(entry.file) == "string" then
      local argv
      if type(entry.arguments) == "table" then
        argv = entry.arguments
      elseif type(entry.command) == "string" then
        -- Naive whitespace split: compile_commands entries that use the
        -- `command` string form (vs the preferred `arguments` array) with
        -- quoted or escaped-space args (e.g. `-DFOO="bar baz"`) will
        -- tokenize incorrectly. CMake/Bear emit the `arguments` form, so
        -- real-world exposure is low; worst case the user sees a compile
        -- error they can diagnose.
        argv = vim.split(entry.command, "%s+", { trimempty = true })
      end
      if argv then
        by_file[entry.file] = M._filter_flags(argv, entry.file)
      end
    end
  end
  return by_file
end

---Extract compile flags for `source_path` from a compile_commands.json file.
---Returns an empty table if the file cannot be read or the path is absent.
---Only flags are returned (compiler and output are dropped). Parses the
---database at most once per `db_path` per session — see the cache note at
---the top of this module for the trade-off. On a malformed database, emits
---a one-time `vim.notify` warning so the user doesn't silently get wrong
---assembly from empty flags.
---@param db_path string
---@param source_path string Absolute path to the source file
---@param deps? table
---@return string[]
function M.flags_for_source(db_path, source_path, deps)
  deps = deps or {}
  local notify = deps.notify or vim.notify
  local index = _compile_commands_cache[db_path]
  if not index then
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
    if #content > MAX_COMPILE_COMMANDS_SIZE then
      notify(
        "asmview: " .. db_path .. " exceeds " .. MAX_COMPILE_COMMANDS_SIZE .. " bytes; skipping",
        vim.log.levels.WARN,
        { title = "asmview.nvim" }
      )
      return {}
    end

    local ok, decoded_or_err = pcall(vim.json.decode, content)
    if not ok or type(decoded_or_err) ~= "table" then
      notify(
        "asmview: failed to parse " .. db_path .. ": " .. tostring(decoded_or_err),
        vim.log.levels.WARN,
        { title = "asmview.nvim" }
      )
      return {}
    end

    index = build_compile_commands_index(decoded_or_err)
    _compile_commands_cache[db_path] = index
  end
  return index[source_path] or {}
end

---Clear the compile_commands index cache. Exposed for tests only; production
---callers never need to invalidate (the cache lives for the Neovim session
---and is dropped when the module is unloaded via `package.loaded[...] = nil`).
---@private
function M._clear_cache()
  _compile_commands_cache = {}
end

---Drop the compiler argv[0], the `-o <path>` pair, the input file, and any `-O*`
---flag (asmview owns -O). Also drop `-c` and `-S` — asmview sets those.
---@param argv string[]
---@param source_path string
---@return string[]
function M._filter_flags(argv, source_path)
  local out = {}
  local skip_next = false
  if #argv > MAX_ARGV_LEN then
    -- Malformed or adversarial compile_commands.json; refuse to process
    -- rather than iterate an unbounded sequence per the bounded-loops rule.
    return out
  end
  for i, arg in ipairs(argv) do
    if type(arg) ~= "string" then
      -- malformed compile_commands.json entry; drop non-string tokens so
      -- they never reach vim.system's argv (which raises on non-strings)
    elseif i == 1 then
      -- argv[0] is the compiler; asmview chooses its own, so skip
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
