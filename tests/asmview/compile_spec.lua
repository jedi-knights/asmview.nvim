-- tests/asmview/compile_spec.lua
-- Characterization tests for asmview.compile. Covers the pure argv-builder
-- surface and the run() dispatcher via an injected vim.system fake — no
-- actual compilers are invoked. End-to-end integration (real cc/c++/rustc/go
-- spawning) belongs in a separate tier.

describe("asmview.compile", function()
  local compile, config

  before_each(function()
    package.loaded["asmview.compile"] = nil
    package.loaded["asmview.config"] = nil
    compile = require("asmview.compile")
    config = require("asmview.config")
    config.setup({})
  end)

  describe("build_argv() — Rust", function()
    it("emits --emit=asm and the opt-level from the request", function()
      local argv = compile.build_argv(
        { filetype = "rust", opt_level = "3", cflags = {} },
        config.get(),
        "/tmp/snippet.rs",
        "/tmp/snippet.s"
      )
      assert.equals("rustc", argv[1])
      assert.is_true(vim.tbl_contains(argv, "--emit=asm"))
      assert.is_true(vim.tbl_contains(argv, "opt-level=3"))
    end)
  end)

  describe("build_argv() — C / C++", function()
    it("emits -S and -O<level> for C", function()
      local argv =
        compile.build_argv({ filetype = "c", opt_level = "2", cflags = {} }, config.get(), "/tmp/x.c", "/tmp/x.s")
      assert.equals("cc", argv[1])
      assert.is_true(vim.tbl_contains(argv, "-S"))
      assert.is_true(vim.tbl_contains(argv, "-O2"))
    end)

    it("includes -masm=intel when syntax=intel", function()
      config.setup({ syntax = "intel" })
      local argv =
        compile.build_argv({ filetype = "cpp", opt_level = "2", cflags = {} }, config.get(), "/tmp/x.cpp", "/tmp/x.s")
      assert.is_true(vim.tbl_contains(argv, "-masm=intel"))
    end)

    it("omits -masm=intel when syntax=att", function()
      config.setup({ syntax = "att" })
      local argv =
        compile.build_argv({ filetype = "cpp", opt_level = "2", cflags = {} }, config.get(), "/tmp/x.cpp", "/tmp/x.s")
      assert.is_false(vim.tbl_contains(argv, "-masm=intel"))
    end)

    it("prepends harvested cflags before the plugin's own flags", function()
      local argv = compile.build_argv(
        { filetype = "cpp", opt_level = "0", cflags = { "-std=c++20", "-I./inc" } },
        config.get(),
        "/tmp/x.cpp",
        "/tmp/x.s"
      )
      -- cflags appear before -S
      local std_idx, s_idx
      for i, v in ipairs(argv) do
        if v == "-std=c++20" then
          std_idx = i
        end
        if v == "-S" then
          s_idx = i
        end
      end
      assert.is_true(std_idx < s_idx)
    end)
  end)

  describe("build_go_argv()", function()
    it("defaults to -gcflags=-S for any non-zero opt_level", function()
      local argv = compile.build_go_argv({ opt_level = "2" }, config.get(), "/tmp/x.bin")
      assert.equals("go", argv[1])
      assert.equals("build", argv[2])
      assert.is_true(vim.tbl_contains(argv, "-gcflags=-S"))
    end)

    it("switches to -gcflags=-S -N -l for opt_level=0", function()
      local argv = compile.build_go_argv({ opt_level = "0" }, config.get(), "/tmp/x.bin")
      assert.is_true(vim.tbl_contains(argv, "-gcflags=-S -N -l"))
    end)
  end)

  describe("build_go_source()", function()
    it("appends a func main stub when the snippet lacks one", function()
      local src = compile.build_go_source({ source = "func foo() {}", go_header = "package main\n" })
      assert.truthy(src:find("func main%(%) {}"))
    end)

    it("leaves the source alone when a func main already exists", function()
      local src = compile.build_go_source({
        source = "func main() { println(1) }",
        go_header = "package main\n",
      })
      -- the appended stub pattern must not have been added again
      local _, count = src:gsub("func main%(%)", "")
      assert.equals(1, count)
    end)

    it("defaults to a bare `package main` when go_header is nil", function()
      local src = compile.build_go_source({ source = "func foo() {}" })
      assert.truthy(src:find("package main"))
    end)
  end)

  describe("run() — dispatcher + run_file_based (C/C++/Rust)", function()
    local function wait_for(flag_ref, timeout_ms)
      vim.wait(timeout_ms or 500, function()
        return flag_ref.done
      end)
    end

    it("spawns the configured compiler for a C request", function()
      local captured
      local flag = {}
      local system_stub = function(argv, _, callback)
        captured = argv
        -- Fail path: exit code non-zero so run_file_based doesn't try to
        -- read a non-existent output file.
        callback({ code = 1, stdout = "", stderr = "simulated compile failure" })
        return {}
      end

      compile.run(
        { filetype = "c", source = "int foo(){return 0;}", opt_level = "2", cwd = "/tmp", cflags = {} },
        config.get(),
        function(result)
          flag.result = result
          flag.done = true
        end,
        { system = system_stub }
      )
      wait_for(flag)
      assert.is_true(flag.done)
      assert.equals("cc", captured[1])
      assert.is_false(flag.result.ok)
      assert.equals(1, flag.result.exit_code)
      assert.truthy(flag.result.asm:find("simulated compile failure"))
    end)

    it("reports an exit-0-with-no-output as a failure", function()
      local flag = {}
      compile.run(
        { filetype = "cpp", source = "int main(){}", opt_level = "2", cwd = "/tmp", cflags = {} },
        config.get(),
        function(result)
          flag.result = result
          flag.done = true
        end,
        {
          system = function(_, _, callback)
            callback({ code = 0, stdout = "", stderr = "" })
            return {}
          end,
        }
      )
      vim.wait(500, function()
        return flag.done
      end)
      assert.is_false(flag.result.ok)
      assert.truthy(flag.result.asm:find("compiler exited 0 but no output"))
    end)

    it("reports a spawn failure when vim.system returns no handle", function()
      local flag = {}
      compile.run(
        { filetype = "c", source = "x", opt_level = "2", cwd = "/tmp", cflags = {} },
        config.get(),
        function(result)
          flag.result = result
          flag.done = true
        end,
        {
          system = function()
            return nil
          end,
        }
      )
      -- No vim.schedule involved on the spawn-failure path — callback is
      -- invoked synchronously.
      assert.is_true(flag.done)
      assert.is_false(flag.result.ok)
      assert.truthy(flag.result.asm:find("failed to spawn"))
    end)
  end)

  describe("run() — Go path", function()
    it("captures stderr as asm when go build exits 0", function()
      local captured_argv, captured_cwd
      local flag = {}
      compile.run(
        {
          filetype = "go",
          source = "func foo() {}",
          opt_level = "2",
          cwd = "/does/not/matter",
          cflags = {},
          go_header = "package main\n",
        },
        config.get(),
        function(result)
          flag.result = result
          flag.done = true
        end,
        {
          system = function(argv, opts, callback)
            captured_argv = argv
            captured_cwd = opts.cwd
            callback({ code = 0, stdout = "", stderr = "main.foo STEXT size=16\nMOVQ ..." })
            return {}
          end,
        }
      )
      vim.wait(500, function()
        return flag.done
      end)
      assert.equals("go", captured_argv[1])
      assert.equals("build", captured_argv[2])
      -- cwd should be the temp module directory the run_go helper created,
      -- not the request.cwd we passed in.
      assert.not_equals("/does/not/matter", captured_cwd)
      assert.is_true(flag.result.ok)
      assert.truthy(flag.result.asm:find("STEXT"))
    end)

    it("reports failure when go build exits non-zero", function()
      local flag = {}
      compile.run(
        {
          filetype = "go",
          source = "func foo() {}",
          opt_level = "0",
          cwd = "/",
          cflags = {},
          go_header = "package main\n",
        },
        config.get(),
        function(result)
          flag.result = result
          flag.done = true
        end,
        {
          system = function(_, _, callback)
            callback({ code = 2, stdout = "", stderr = "./snippet.go:1: undefined: X" })
            return {}
          end,
        }
      )
      vim.wait(500, function()
        return flag.done
      end)
      assert.is_false(flag.result.ok)
      assert.equals(2, flag.result.exit_code)
      assert.truthy(flag.result.asm:find("undefined: X"))
    end)

    it("reports a spawn failure on the Go path", function()
      local flag = {}
      compile.run(
        {
          filetype = "go",
          source = "func foo() {}",
          opt_level = "2",
          cwd = "/",
          cflags = {},
          go_header = "package main\n",
        },
        config.get(),
        function(result)
          flag.result = result
          flag.done = true
        end,
        {
          system = function()
            return nil
          end,
        }
      )
      assert.is_true(flag.done)
      assert.is_false(flag.result.ok)
      assert.truthy(flag.result.asm:find("failed to spawn"))
    end)
  end)
end)
