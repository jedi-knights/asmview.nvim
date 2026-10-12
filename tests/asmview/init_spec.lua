-- tests/asmview/init_spec.lua
-- Characterization tests for the public asmview facade. Each path through
-- `show()` is driven by injecting stub detect / range / window / compile
-- modules through the deps table — the pattern the production code is
-- designed for.

describe("asmview", function()
  local asmview

  before_each(function()
    package.loaded["asmview"] = nil
    package.loaded["asmview.config"] = nil
    asmview = require("asmview")
    asmview.setup({})
  end)

  local function base_deps()
    local notified = {}
    return {
      notified = notified,
      notify = function(msg, lvl, opts)
        table.insert(notified, { msg = msg, lvl = lvl, opts = opts })
      end,
      detect = {
        language_for_buffer = function()
          return "c"
        end,
        has_executable = function()
          return true
        end,
        find_compile_commands = function()
          return nil
        end,
        flags_for_source = function()
          return {}
        end,
      },
      range = {
        resolve = function()
          return { start_line = 1, end_line = 3, source = "void foo(){}", label = "function @ line 1-3" }
        end,
      },
      window = {
        open_calls = {},
        open = function(bufnr, range, ft, cflags, go_header, cfg, compile)
          -- Captured so tests can inspect what the facade handed off.
          -- (Using a module-level table on the stub because window stub is
          -- rebuilt per-test by the caller when assertions on specific
          -- arguments are needed.)
          return { captured = { bufnr, range, ft, cflags, go_header } }
        end,
      },
      compile = { run = function() end },
    }
  end

  describe("setup()", function()
    it("returns true on empty options", function()
      package.loaded["asmview.config"] = nil
      package.loaded["asmview"] = nil
      asmview = require("asmview")
      assert.is_true(asmview.setup({}))
    end)
  end)

  describe("get_config()", function()
    it("returns the active configuration", function()
      asmview.setup({ syntax = "att" })
      assert.equals("att", asmview.get_config().syntax)
    end)
  end)

  describe("show()", function()
    it("bails and notifies when the filetype is unsupported", function()
      local d = base_deps()
      d.detect.language_for_buffer = function()
        return nil
      end
      local ok = asmview.show(nil, d)
      assert.is_false(ok)
      assert.equals(1, #d.notified)
      assert.truthy(d.notified[1].msg:find("filetype not supported"))
    end)

    it("bails and notifies when the compiler is not on PATH", function()
      local d = base_deps()
      d.detect.has_executable = function()
        return false
      end
      local ok = asmview.show(nil, d)
      assert.is_false(ok)
      assert.truthy(d.notified[1].msg:find("compiler not found on PATH"))
    end)

    it("bails and notifies when range.resolve returns an error", function()
      local d = base_deps()
      d.range.resolve = function()
        return nil, "no enclosing function"
      end
      local ok = asmview.show(nil, d)
      assert.is_false(ok)
      assert.truthy(d.notified[1].msg:find("no enclosing function"))
    end)

    it("opens the window with cflags when compile_commands.json is found for C/C++", function()
      -- compile_commands lookup is only attempted when the buffer has a file
      -- name — the production code reads `nvim_buf_get_name(bufnr)` and bails
      -- early on "". Set a name so the lookup path actually runs.
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(buf, "/proj/src/a.cpp")
      vim.api.nvim_set_current_buf(buf)

      local d = base_deps()
      d.detect.find_compile_commands = function()
        return "/proj/compile_commands.json"
      end
      d.detect.flags_for_source = function()
        return { "-std=c++20", "-I./inc" }
      end
      local opened
      d.window.open = function(_, _, _, cflags)
        opened = cflags
      end
      local ok = asmview.show(nil, d)
      assert.is_true(ok)
      assert.same({ "-std=c++20", "-I./inc" }, opened)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("skips compile_commands harvesting for Rust", function()
      local d = base_deps()
      d.detect.language_for_buffer = function()
        return "rust"
      end
      local find_called = false
      d.detect.find_compile_commands = function()
        find_called = true
        return nil
      end
      asmview.show(nil, d)
      assert.is_false(find_called)
    end)

    it("passes a go_header to window.open for Go buffers", function()
      local d = base_deps()
      d.detect.language_for_buffer = function()
        return "go"
      end
      d.detect.go_header = function()
        return 'package main\nimport "fmt"\n'
      end
      local header_opened
      d.window.open = function(_, _, _, _, go_header)
        header_opened = go_header
      end
      asmview.show(nil, d)
      assert.truthy(header_opened:find("package main"))
      assert.truthy(header_opened:find('"fmt"'))
    end)

    it("marks a user-command range of 2+ lines as visual", function()
      local d = base_deps()
      local resolve_opts
      d.range.resolve = function(_, opts)
        resolve_opts = opts
        return { start_line = 2, end_line = 5, source = "x", label = "lines 2-5" }
      end
      asmview.show({ range = 2, line1 = 2, line2 = 5 }, d)
      assert.is_true(resolve_opts.visual)
    end)

    it("does not mark as visual when the command carried no range", function()
      local d = base_deps()
      local resolve_opts
      d.range.resolve = function(_, opts)
        resolve_opts = opts
        return { start_line = 1, end_line = 1, source = "x", label = "x" }
      end
      asmview.show({ range = 0 }, d)
      assert.is_nil(resolve_opts.visual)
    end)
  end)
end)
