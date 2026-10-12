-- lua/asmview/compile.lua
-- Compile a source snippet to assembly text. Dispatches by language:
-- C/C++/Rust take a `-S` / `--emit=asm` path that writes an output file;
-- Go takes a temp-module path and captures stderr from `go build -gcflags=-S`.

local M = {}

local uv = vim.uv or vim.loop

---Build the compiler argv for a non-Go request.
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

---Build the `go build` argv for a Go request. Only two optimization states
---are meaningful on Go's gc toolchain: optimized default, and `-N -l`
---(disable optimization and inlining). Any opt_level that parses as "0"
---maps to the latter; everything else keeps the default optimizer on.
---@param request asmview.Request
---@param cfg asmview.Config
---@param out_bin string Binary output path (we only care about the asm on stderr)
---@return string[] argv
function M.build_go_argv(request, cfg, out_bin)
  local spec = cfg.compilers.go
  assert(spec, "no compiler configured for go")

  local gcflags = "-S"
  if request.opt_level == "0" then
    gcflags = gcflags .. " -N -l"
  end

  local argv = { spec.cmd, "build" }
  for _, flag in ipairs(spec.extra_args) do
    table.insert(argv, flag)
  end
  table.insert(argv, "-gcflags=" .. gcflags)
  table.insert(argv, "-o")
  table.insert(argv, out_bin)
  table.insert(argv, ".")
  return argv
end

---Return a filename extension (without dot) for a file-based (non-Go) filetype.
---Go takes its own path via run_go — it never reaches write_temp_source.
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
---Go symbols are already readable; no demangler is needed.
---@param ft "c"|"cpp"|"rust"|"go"
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

---Write source to a temp file. Returns absolute path and the containing dir.
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

---Write `content` to `path`. Raises on error.
---@param path string
---@param content string
local function write_file(path, content)
  local fh, err = io.open(path, "w")
  if not fh then
    error("asmview: failed to write " .. path .. ": " .. tostring(err))
  end
  fh:write(content)
  fh:close()
end

---Delete a directory tree. Best-effort; errors are swallowed because this is cleanup.
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
---Accepts `deps.system` so tests can inject a fake demangler without
---spawning the real binary.
---@param cmd string
---@param text string
---@param deps? table
---@return string
local function demangle(cmd, text, deps)
  deps = deps or {}
  local system = deps.system or vim.system
  local ok, result = pcall(system, { cmd }, { stdin = text, text = true }, nil)
  if not ok then
    return text
  end
  local completed = result:wait()
  if completed.code == 0 and completed.stdout and completed.stdout ~= "" then
    return completed.stdout
  end
  return text
end

---Compile a C/C++/Rust snippet by writing it to a temp file, invoking the
---compiler with `-S` / `--emit=asm`, and reading the resulting `.s` output.
---@param request asmview.Request
---@param cfg asmview.Config
---@param callback fun(result: asmview.Result)
---@param deps? table
local function run_file_based(request, cfg, callback, deps)
  deps = deps or {}
  local system = deps.system or vim.system
  local now = deps.now or uv.hrtime

  local ok_src, src_path, src_dir = pcall(write_temp_source, request.source, src_ext(request.filetype))
  if not ok_src then
    callback({ ok = false, asm = tostring(src_path), exit_code = -1, duration_ms = 0 })
    return
  end

  local out_path = src_path:gsub("%.[^.]+$", ".s")
  if out_path == src_path then
    out_path = src_path .. ".s"
  end

  local argv = M.build_argv(request, cfg, src_path, out_path)
  local started = now()

  local handle = system(argv, { cwd = request.cwd, text = true }, function(obj)
    local elapsed_ms = math.floor((now() - started) / 1e6)
    local function finish(result)
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
        asm = demangle(tool, asm, deps)
      end
    end

    finish({ ok = true, asm = asm, exit_code = 0, duration_ms = elapsed_ms })
  end)

  if not handle then
    rmtree(src_dir)
    callback({
      ok = false,
      asm = "asmview: failed to spawn " .. argv[1],
      exit_code = -1,
      duration_ms = 0,
    })
  end
end

---Assemble the Go snippet into a buildable file. We force `package main` and
---add a `func main()` stub when the snippet doesn't declare one, so
---`go build .` succeeds. The caller is responsible for supplying `go_header`
---with the buffer's package + import block via `detect.go_header`.
---@param request asmview.Request
---@return string content
function M.build_go_source(request)
  local header = request.go_header or "package main\n"
  local parts = { header, "", request.source, "" }
  if not request.source:find("func%s+main%s*%(") then
    table.insert(parts, "func main() {}")
  end
  return table.concat(parts, "\n")
end

---Compile a Go snippet. Writes a self-contained module to a temp dir
---(`go.mod` + `snippet.go`) and runs `go build -gcflags="-S [-N -l]" .`.
---Assembly is emitted to stderr by the gc compiler; we capture it there.
---@param request asmview.Request
---@param cfg asmview.Config
---@param callback fun(result: asmview.Result)
---@param deps? table
local function run_go(request, cfg, callback, deps)
  deps = deps or {}
  local system = deps.system or vim.system
  local now = deps.now or uv.hrtime

  local dir = uv.fs_mkdtemp((uv.os_tmpdir() or "/tmp") .. "/asmview-XXXXXX")
  if not dir then
    callback({ ok = false, asm = "asmview: failed to create temp dir", exit_code = -1, duration_ms = 0 })
    return
  end

  local ok_write, err = pcall(function()
    write_file(dir .. "/go.mod", "module asmview_snippet\n\ngo 1.21\n")
    write_file(dir .. "/snippet.go", M.build_go_source(request))
  end)
  if not ok_write then
    rmtree(dir)
    callback({ ok = false, asm = tostring(err), exit_code = -1, duration_ms = 0 })
    return
  end

  local out_bin = dir .. "/snippet.bin"
  local argv = M.build_go_argv(request, cfg, out_bin)
  local started = now()

  local handle = system(argv, { cwd = dir, text = true }, function(obj)
    local elapsed_ms = math.floor((now() - started) / 1e6)
    local function finish(result)
      rmtree(dir)
      vim.schedule(function()
        callback(result)
      end)
    end

    local asm = (obj.stderr and obj.stderr ~= "") and obj.stderr or (obj.stdout or "")
    finish({
      ok = obj.code == 0,
      asm = asm,
      exit_code = obj.code,
      duration_ms = elapsed_ms,
    })
  end)

  if not handle then
    rmtree(dir)
    callback({
      ok = false,
      asm = "asmview: failed to spawn " .. argv[1],
      exit_code = -1,
      duration_ms = 0,
    })
  end
end

---Run a compile request asynchronously. The callback receives an asmview.Result
---on the main thread (vim.schedule-wrapped).
---@param request asmview.Request
---@param cfg asmview.Config
---@param callback fun(result: asmview.Result)
---@param deps? table
function M.run(request, cfg, callback, deps)
  assert(type(request) == "table", "request required")
  assert(type(cfg) == "table", "cfg required")
  assert(type(callback) == "function", "callback required")

  if request.filetype == "go" then
    return run_go(request, cfg, callback, deps)
  end
  return run_file_based(request, cfg, callback, deps)
end

return M
