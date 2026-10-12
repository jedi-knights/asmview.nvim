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
  vim.validate({
    filetype = { request.filetype, "string" },
    opt_level = { request.opt_level, "string" },
    cflags = { request.cflags, "table" },
    src_path = { src_path, "string" },
    out_path = { out_path, "string" },
  })
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
  vim.validate({
    opt_level = { request.opt_level, "string" },
    out_bin = { out_bin, "string" },
  })
  local spec = cfg.compilers.go
  assert(spec, "no compiler configured for go")

  -- `go build` accepts multiple gc flags only as a single space-separated
  -- `-gcflags=<value>` argument — splitting into repeated `-gcflags` entries
  -- would make Go treat each as a separate pattern-less override and only
  -- the last wins. Keep the space-joined string as one argv token.
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
---
---`uv.fs_mkdtemp` and the follow-up `io.open` + `fh:write` run synchronously
---on the main thread. This is a deliberate pragmatic trade-off: `/tmp` on
---local disk completes in microseconds, the snippet files are typically a
---few hundred bytes, and routing the whole run_file_based path through an
---async-callback chain just to defer two microsecond operations is net
---complexity loss. Users on exotic FS mounts (NFS /tmp) accept a sub-ms
---stall per compile. Compare: `detect.lua`'s compile_commands read documents
---the same trade-off with the same reasoning.
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

---Delete a directory tree. Best-effort; errors are swallowed because this is
---cleanup. Capped at `max_depth` recursive descents to defend against
---symlink loops inside the temp dir.
---@param dir string
---@param max_depth? integer Default 20 — real cleanup trees are 1 or 2 levels.
local function rmtree(dir, max_depth)
  max_depth = max_depth or 20
  if not dir or dir == "" or dir == "/" or max_depth <= 0 then
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
        rmtree(sub, max_depth - 1)
      else
        uv.fs_unlink(sub)
      end
    end
  end
  uv.fs_rmdir(dir)
end

---Pipe `text` through `cmd` asynchronously and deliver the demangled result
---(or the original `text` on any failure) via `callback`. Accepts
---`deps.system` so tests can inject a fake demangler. Async by design so the
---main thread never blocks on a demangler process — a prior synchronous
---`:wait()` form could stall the UI for the duration of the demangle on
---large asm outputs.
---@param cmd string
---@param text string
---@param deps? table
---@param callback fun(result: string)
local function demangle(cmd, text, deps, callback)
  deps = deps or {}
  local system = deps.system or vim.system
  local ok, _handle = pcall(system, { cmd }, { stdin = text, text = true }, function(obj)
    if obj.code == 0 and obj.stdout and obj.stdout ~= "" then
      callback(obj.stdout)
    else
      callback(text)
    end
  end)
  -- _handle is intentionally discarded: the demangle call is fire-and-forget
  -- and the user has no cancel UI; retaining the SystemObj would just hold a
  -- reference across the schedule hop for no gain.
  if not ok then
    callback(text)
  end
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

  -- On failure, `src_path_or_err` holds the error string from `write_temp_source`
  -- and `src_dir` is nil; on success they are the real path and dir. Named this
  -- way so the error branch below doesn't look like it dereferences a path.
  local ok_src, src_path_or_err, src_dir = pcall(write_temp_source, request.source, src_ext(request.filetype))
  if not ok_src then
    callback({ ok = false, asm = tostring(src_path_or_err), exit_code = -1, duration_ms = 0 })
    return
  end
  local src_path = src_path_or_err

  -- write_temp_source always writes `snippet.<ext>` so the gsub always
  -- matches; the previous `== src_path` fallback was unreachable.
  local out_path = src_path:gsub("%.[^.]+$", ".s")

  local argv = M.build_argv(request, cfg, src_path, out_path)
  local started = now()

  -- vim.system raises on invalid argv in production (contract: it never
  -- returns nil). Wrap in pcall so a production spawn failure routes to the
  -- same error path as a test stub returning nil, instead of propagating an
  -- uncaught error up through recompile().
  local ok_spawn, handle = pcall(system, argv, { cwd = request.cwd, text = true }, function(obj)
    local elapsed_ms = math.floor((now() - started) / 1e6)
    -- The vim.system callback runs in a libuv context where sync I/O and
    -- nested vim.system `:wait()` are unsafe (fast-event rules, E5560).
    -- Hop to the main thread before reading the output file, piping it
    -- through the demangler, and invoking the user callback.
    vim.schedule(function()
      local function finish(result)
        rmtree(src_dir)
        callback(result)
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

      local function deliver(final_asm)
        finish({ ok = true, asm = final_asm, exit_code = 0, duration_ms = elapsed_ms })
      end

      if cfg.demangle then
        local tool = pick_demangler(request.filetype, deps)
        if tool then
          demangle(tool, asm, deps, function(demangled)
            vim.schedule(function()
              deliver(demangled)
            end)
          end)
          return
        end
      end
      deliver(asm)
    end)
  end)

  if not ok_spawn or not handle then
    rmtree(src_dir)
    callback({
      ok = false,
      asm = "asmview: failed to spawn " .. argv[1] .. (ok_spawn and "" or ": " .. tostring(handle)),
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

  -- Same sync-on-main trade-off as write_temp_source above: fs_mkdtemp and
  -- the two write_file calls below block for microseconds on local /tmp.
  -- Documented at the top of write_temp_source.
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

  -- Same pcall-around-vim.system discipline as run_file_based: shepherd the
  -- "raised on invalid argv" case into the same callback error path.
  local ok_spawn, handle = pcall(system, argv, { cwd = dir, text = true }, function(obj)
    local elapsed_ms = math.floor((now() - started) / 1e6)
    local asm = (obj.stderr and obj.stderr ~= "") and obj.stderr or (obj.stdout or "")
    -- Hop to the main thread before touching libuv file ops or invoking the
    -- user callback — same discipline as run_file_based.
    vim.schedule(function()
      rmtree(dir)
      callback({
        ok = obj.code == 0,
        asm = asm,
        exit_code = obj.code,
        duration_ms = elapsed_ms,
      })
    end)
  end)

  if not ok_spawn or not handle then
    rmtree(dir)
    callback({
      ok = false,
      asm = "asmview: failed to spawn " .. argv[1] .. (ok_spawn and "" or ": " .. tostring(handle)),
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
