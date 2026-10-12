-- lua/asmview/compile.lua
-- Compile a source snippet to assembly text (async via vim.system).

local M = {}

local uv = vim.uv or vim.loop

---Build the compiler argv for a request.
---@param request asmview.Request
---@param cfg asmview.Config
---@param src_path string
---@param out_path string
---@return string[] argv
function M.build_argv(request, cfg, src_path, out_path)
  local spec = cfg.compilers[request.filetype]
  assert(spec, "no compiler configured for " .. request.filetype)

  local argv = { spec.cmd }

  if request.filetype == "rust" then
    for _, flag in ipairs(spec.extra_args) do
      table.insert(argv, flag)
    end
    table.insert(argv, "--emit=asm")
    table.insert(argv, "-C")
    table.insert(argv, "opt-level=" .. request.opt_level)
    table.insert(argv, "-o")
    table.insert(argv, out_path)
    table.insert(argv, src_path)
    return argv
  end

  -- C / C++
  for _, flag in ipairs(request.cflags) do
    table.insert(argv, flag)
  end
  for _, flag in ipairs(spec.extra_args) do
    table.insert(argv, flag)
  end
  table.insert(argv, "-S")
  table.insert(argv, "-O" .. request.opt_level)
  if cfg.syntax == "intel" then
    table.insert(argv, "-masm=intel")
    table.insert(argv, "-fno-asynchronous-unwind-tables")
  end
  table.insert(argv, "-o")
  table.insert(argv, out_path)
  table.insert(argv, src_path)
  return argv
end

---Return a filename extension (without dot) for a filetype.
---@param ft "c"|"cpp"|"rust"
---@return string
local function src_ext(ft)
  if ft == "c" then
    return "c"
  elseif ft == "cpp" then
    return "cpp"
  else
    return "rs"
  end
end

---Pick a demangler for the filetype, or nil if not applicable / not installed.
---@param ft "c"|"cpp"|"rust"
---@param deps? table
---@return string? cmd
local function pick_demangler(ft, deps)
  deps = deps or {}
  local exe = deps.executable or vim.fn.executable
  if ft == "cpp" and exe("c++filt") == 1 then
    return "c++filt"
  end
  if ft == "rust" and exe("rustfilt") == 1 then
    return "rustfilt"
  end
  return nil
end

---Write source to a temp file. Returns absolute path or raises.
---@param source string
---@param ext string
---@return string path, string dir
local function write_temp_source(source, ext)
  local dir = uv.fs_mkdtemp((uv.os_tmpdir() or "/tmp") .. "/asmview-XXXXXX")
  if not dir then
    error("asmview: failed to create temp dir")
  end
  local path = dir .. "/snippet." .. ext
  local fh, err = io.open(path, "w")
  if not fh then
    error("asmview: failed to open temp file: " .. tostring(err))
  end
  fh:write(source)
  fh:close()
  return path, dir
end

---Delete a directory tree. Best-effort; swallows errors because this is cleanup.
---@param dir string
local function rmtree(dir)
  if not dir or dir == "" or dir == "/" then
    return
  end
  local handle = uv.fs_scandir(dir)
  if handle then
    while true do
      local name, kind = uv.fs_scandir_next(handle)
      if not name then
        break
      end
      local sub = dir .. "/" .. name
      if kind == "directory" then
        rmtree(sub)
      else
        uv.fs_unlink(sub)
      end
    end
  end
  uv.fs_rmdir(dir)
end

---Pipe `text` through `cmd` and return its stdout, or `text` on any failure.
---@param cmd string
---@param text string
---@return string
local function demangle(cmd, text)
  local ok, result = pcall(vim.system, { cmd }, { stdin = text, text = true }, nil)
  if not ok then
    return text
  end
  local completed = result:wait()
  if completed.code == 0 and completed.stdout and completed.stdout ~= "" then
    return completed.stdout
  end
  return text
end

---Run a compile request asynchronously. The callback receives an asmview.Result.
---@param request asmview.Request
---@param cfg asmview.Config
---@param callback fun(result: asmview.Result)
---@param deps? table
function M.run(request, cfg, callback, deps)
  assert(type(request) == "table", "request required")
  assert(type(cfg) == "table", "cfg required")
  assert(type(callback) == "function", "callback required")
  deps = deps or {}

  local system = deps.system or vim.system
  local now = deps.now or uv.hrtime

  local ok_src, src_path, src_dir = pcall(write_temp_source, request.source, src_ext(request.filetype))
  if not ok_src then
    callback({ ok = false, asm = tostring(src_path), exit_code = -1, duration_ms = 0 })
    return
  end
  src_dir = src_dir -- unused name clarified via assignment, retained for cleanup

  local out_path = src_path:gsub("%.[^.]+$", ".s")
  if out_path == src_path then
    out_path = src_path .. ".s"
  end

  local argv = M.build_argv(request, cfg, src_path, out_path)
  local started = now()

  local handle = system(argv, { cwd = request.cwd, text = true }, function(obj)
    local elapsed_ms = math.floor((now() - started) / 1e6)
    local function finish(result)
      pcall(uv.fs_unlink, src_path)
      pcall(uv.fs_unlink, out_path)
      rmtree(src_dir)
      vim.schedule(function()
        callback(result)
      end)
    end

    if obj.code ~= 0 then
      finish({
        ok = false,
        asm = (obj.stderr and obj.stderr ~= "") and obj.stderr or (obj.stdout or ""),
        exit_code = obj.code,
        duration_ms = elapsed_ms,
      })
      return
    end

    local fh = io.open(out_path, "r")
    if not fh then
      finish({
        ok = false,
        asm = "asmview: compiler exited 0 but no output at " .. out_path,
        exit_code = obj.code,
        duration_ms = elapsed_ms,
      })
      return
    end
    local asm = fh:read("*a") or ""
    fh:close()

    if cfg.demangle then
      local tool = pick_demangler(request.filetype, deps)
      if tool then
        asm = demangle(tool, asm)
      end
    end

    finish({ ok = true, asm = asm, exit_code = 0, duration_ms = elapsed_ms })
  end)

  if not handle then
    pcall(uv.fs_unlink, src_path)
    rmtree(src_dir)
    callback({
      ok = false,
      asm = "asmview: failed to spawn " .. argv[1],
      exit_code = -1,
      duration_ms = 0,
    })
  end
end

return M
