-- tests/asmview/compile_spec.lua
-- Characterization tests for the pure argv-builder surface of asmview.compile.
-- End-to-end compilation (vim.system spawn + stderr capture) is not covered
-- here; those are integration concerns that need a real compiler.

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
end)
