-- tests/asmview/config_spec.lua
-- Characterization tests for asmview.config.

describe("asmview.config", function()
  local config

  before_each(function()
    package.loaded["asmview.config"] = nil
    config = require("asmview.config")
  end)

  describe("defaults()", function()
    it("declares cc / c++ / rustc / go as the default compilers", function()
      local d = config.defaults()
      assert.equals("cc", d.compilers.c.cmd)
      assert.equals("c++", d.compilers.cpp.cmd)
      assert.equals("rustc", d.compilers.rust.cmd)
      assert.equals("go", d.compilers.go.cmd)
    end)

    it("includes 0, 1, 2, 3, s, z as valid opt levels with 2 as default", function()
      local d = config.defaults()
      assert.same({ "0", "1", "2", "3", "s", "z" }, d.opt_levels)
      assert.equals("2", d.default_opt)
    end)

    it("defaults to intel syntax with demangle on", function()
      local d = config.defaults()
      assert.equals("intel", d.syntax)
      assert.is_true(d.demangle)
    end)
  end)

  describe("setup()", function()
    it("returns true on empty options", function()
      assert.is_true(config.setup({}))
    end)

    it("deep-merges user overrides over the defaults", function()
      assert.is_true(config.setup({ syntax = "att", compilers = { c = { cmd = "clang" } } }))
      local cfg = config.get()
      assert.equals("att", cfg.syntax)
      assert.equals("clang", cfg.compilers.c.cmd)
      -- untouched defaults persist
      assert.equals("c++", cfg.compilers.cpp.cmd)
      assert.equals("go", cfg.compilers.go.cmd)
    end)

    it("rejects a syntax that is not intel or att", function()
      assert.is_false(config.setup({ syntax = "sparc" }))
    end)

    it("rejects a default_opt not present in opt_levels", function()
      assert.is_false(config.setup({ default_opt = "9", opt_levels = { "0", "1" } }))
    end)

    it("rejects a float width_ratio outside (0, 1]", function()
      assert.is_false(config.setup({ float = { width_ratio = 1.5, height_ratio = 0.5, border = "rounded" } }))
    end)

    it("rejects a negative compile_commands_search_depth", function()
      assert.is_false(config.setup({ compile_commands_search_depth = -1 }))
    end)

    it("rejects a compiler spec with an empty cmd", function()
      assert.is_false(config.setup({ compilers = { c = { cmd = "", extra_args = {} } } }))
    end)
  end)

  describe("get()", function()
    it("reflects the last successful setup call", function()
      config.setup({ syntax = "att" })
      assert.equals("att", config.get().syntax)
      config.setup({ syntax = "intel" })
      assert.equals("intel", config.get().syntax)
    end)
  end)
end)
