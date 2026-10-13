-- tests/asmview/window_spec.lua
-- Characterization tests for the pure helpers in asmview.window.
-- The floating-window + keymap wiring itself is exercised only via `show()`
-- integration (not covered here).

describe("asmview.window", function()
  local window

  before_each(function()
    package.loaded["asmview.window"] = nil
    window = require("asmview.window")
  end)

  describe("cycle_opt()", function()
    local levels = { "0", "1", "2", "3", "s", "z" }

    it("steps forward by one position", function()
      assert.equals("3", window.cycle_opt(levels, "2", 1))
    end)

    it("steps backward by one position", function()
      assert.equals("1", window.cycle_opt(levels, "2", -1))
    end)

    it("clamps at the top of the array", function()
      assert.equals("z", window.cycle_opt(levels, "z", 1))
    end)

    it("clamps at the bottom of the array", function()
      assert.equals("0", window.cycle_opt(levels, "0", -1))
    end)

    it("falls back to position 1 when `current` is not in the list", function()
      assert.equals("0", window.cycle_opt(levels, "nonexistent", -1))
      assert.equals("1", window.cycle_opt(levels, "nonexistent", 1))
    end)
  end)

  describe("open()", function()
    local config
    local open_states

    before_each(function()
      package.loaded["asmview.config"] = nil
      config = require("asmview.config")
      config.setup({})
      open_states = {}
    end)

    after_each(function()
      -- Close any windows the specs leave behind so subsequent runs start clean.
      for _, state in ipairs(open_states) do
        if state and state.win and vim.api.nvim_win_is_valid(state.win) then
          vim.api.nvim_win_close(state.win, true)
        end
      end
    end)

    ---Build a compile stub that records every run() invocation and
    ---synchronously fires `on_result` with the configured result.
    local function stub_compile(result)
      local calls = {}
      return {
        calls = calls,
        run = function(request, _, callback)
          table.insert(calls, request)
          callback(result)
        end,
      }
    end

    local function new_source_buffer()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "int foo() { return 1; }" })
      return buf
    end

    it("opens a vsplit asm buffer, renders the header, and fires the first compile", function()
      local source = new_source_buffer()
      local compile_stub = stub_compile({ ok = true, asm = "mov eax, 1\nret", exit_code = 0, duration_ms = 7 })
      local range = { start_line = 1, end_line = 1, source = "int foo(){return 1;}", label = "function @ line 1-1" }

      local state = window.open(source, range, "c", {}, nil, config.get(), compile_stub)
      table.insert(open_states, state)

      assert.is_true(vim.api.nvim_buf_is_valid(state.bufnr))
      assert.is_true(vim.api.nvim_win_is_valid(state.win))
      assert.equals("asm", vim.api.nvim_get_option_value("filetype", { buf = state.bufnr }))

      local lines = vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false)
      -- First line is the header; the body contains the stub's asm.
      assert.truthy(lines[1]:find("asmview", 1, true))
      assert.truthy(lines[1]:find("opt=-O2", 1, true))
      assert.is_true(vim.tbl_contains(lines, "mov eax, 1"))
      assert.is_true(vim.tbl_contains(lines, "ret"))
      assert.equals(1, #compile_stub.calls)
      assert.equals("c", compile_stub.calls[1].filetype)
    end)

    it("prefixes the header with [FAILED] when the compile result is not ok", function()
      local source = new_source_buffer()
      local compile_stub = stub_compile({ ok = false, asm = "error: expected ';'", exit_code = 1, duration_ms = 3 })
      local range = { start_line = 1, end_line = 1, source = "x", label = "x" }

      local state = window.open(source, range, "c", {}, nil, config.get(), compile_stub)
      table.insert(open_states, state)

      local header = vim.api.nvim_buf_get_lines(state.bufnr, 0, 1, false)[1]
      assert.truthy(header:find("%[FAILED%]"))
    end)

    it("binds buffer-local +/-/R/q keymaps on the asm buffer", function()
      local source = new_source_buffer()
      local compile_stub = stub_compile({ ok = true, asm = "", exit_code = 0, duration_ms = 0 })
      local range = { start_line = 1, end_line = 1, source = "x", label = "x" }

      local state = window.open(source, range, "c", {}, nil, config.get(), compile_stub)
      table.insert(open_states, state)

      local keys = {}
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(state.bufnr, "n")) do
        keys[m.lhs] = true
      end
      assert.is_true(keys["+"])
      assert.is_true(keys["-"])
      assert.is_true(keys["R"])
      assert.is_true(keys["q"])
    end)

    it("fires a recompile with the next opt level when + is pressed", function()
      local source = new_source_buffer()
      local compile_stub = stub_compile({ ok = true, asm = "", exit_code = 0, duration_ms = 0 })
      local range = { start_line = 1, end_line = 1, source = "x", label = "x" }

      -- default_opt is "2"; pressing + should step to "3" and fire a second compile.
      local state = window.open(source, range, "c", {}, nil, config.get(), compile_stub)
      table.insert(open_states, state)
      assert.equals(1, #compile_stub.calls)

      for _, m in ipairs(vim.api.nvim_buf_get_keymap(state.bufnr, "n")) do
        if m.lhs == "+" then
          m.callback()
        end
      end

      assert.equals("3", state.opt_level)
      assert.equals(2, #compile_stub.calls)
      assert.equals("3", compile_stub.calls[2].opt_level)
    end)

    it("closes the asm window when q is pressed", function()
      local source = new_source_buffer()
      local compile_stub = stub_compile({ ok = true, asm = "", exit_code = 0, duration_ms = 0 })
      local range = { start_line = 1, end_line = 1, source = "x", label = "x" }

      local state = window.open(source, range, "c", {}, nil, config.get(), compile_stub)
      table.insert(open_states, state)
      assert.is_true(vim.api.nvim_win_is_valid(state.win))

      for _, m in ipairs(vim.api.nvim_buf_get_keymap(state.bufnr, "n")) do
        if m.lhs == "q" then
          m.callback()
        end
      end

      assert.is_false(vim.api.nvim_win_is_valid(state.win))
    end)

    it("re-fetches the current source content on rerun (R picks up edits)", function()
      local source = new_source_buffer()
      local compile_stub = stub_compile({ ok = true, asm = "", exit_code = 0, duration_ms = 0 })
      local range = { start_line = 1, end_line = 1, source = "int foo(){return 1;}", label = "x" }

      local state = window.open(source, range, "c", {}, nil, config.get(), compile_stub)
      table.insert(open_states, state)
      -- The first compile saw the original line.
      assert.equals("int foo() { return 1; }", compile_stub.calls[1].source)

      -- User edits the source buffer, then presses R.
      vim.api.nvim_buf_set_lines(source, 0, -1, false, { "int foo() { return 42; }" })
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(state.bufnr, "n")) do
        if m.lhs == "R" then
          m.callback()
        end
      end
      assert.equals(2, #compile_stub.calls)
      assert.equals("int foo() { return 42; }", compile_stub.calls[2].source)
    end)

    it("replaces the asm buffer with a notice when the source buffer has been wiped before rerun", function()
      local source = new_source_buffer()
      local compile_stub = stub_compile({ ok = true, asm = "mov eax, 1\nret", exit_code = 0, duration_ms = 0 })
      local range = { start_line = 1, end_line = 1, source = "int foo(){return 1;}", label = "x" }

      local state = window.open(source, range, "c", {}, nil, config.get(), compile_stub)
      table.insert(open_states, state)
      assert.equals(1, #compile_stub.calls)

      -- Simulate the user :bdelete'ing the source buffer, then pressing R.
      vim.api.nvim_buf_delete(source, { force = true })

      for _, m in ipairs(vim.api.nvim_buf_get_keymap(state.bufnr, "n")) do
        if m.lhs == "R" then
          m.callback()
        end
      end

      -- recompile() bailed with the invalid-source notice; no new compile fired.
      assert.equals(1, #compile_stub.calls)
      local lines = vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false)
      assert.truthy(lines[1]:find("source buffer no longer valid", 1, true))
    end)

    it("records state in the module-level table keyed by buffer", function()
      local source = new_source_buffer()
      local compile_stub = stub_compile({ ok = true, asm = "", exit_code = 0, duration_ms = 0 })
      local range = { start_line = 1, end_line = 1, source = "x", label = "x" }

      local state = window.open(source, range, "c", {}, nil, config.get(), compile_stub)
      table.insert(open_states, state)

      assert.is_table(window._state(state.bufnr))
      assert.equals(state.bufnr, window._state(state.bufnr).bufnr)
    end)

    it("opens a right-side vertical split (not a floating window)", function()
      -- Arrange
      local source = new_source_buffer()
      local compile_stub = stub_compile({ ok = true, asm = "", exit_code = 0, duration_ms = 0 })
      local range = { start_line = 1, end_line = 1, source = "x", label = "x" }

      -- Act
      local state = window.open(source, range, "c", {}, nil, config.get(), compile_stub)
      table.insert(open_states, state)

      -- Assert — split windows report relative="" from nvim_win_get_config
      -- and floats report relative in {"editor","win","cursor"}. Confirm the
      -- window is a plain split anchored on the right.
      local wincfg = vim.api.nvim_win_get_config(state.win)
      assert.equals("", wincfg.relative or "")
    end)

    it("passes the mapping + highlight deps through to render", function()
      -- Arrange
      local source = new_source_buffer()
      local compile_stub = stub_compile({
        ok = true,
        asm = ".loc 1 1 1\nmov eax, 1\nret",
        exit_code = 0,
        duration_ms = 0,
      })
      local range = { start_line = 10, end_line = 11, source = "x", label = "x" }

      local build_calls, attach_calls, detach_calls = {}, {}, {}
      local stub_mapping = {
        build = function(asm, r, ft, basename)
          table.insert(build_calls, { asm = asm, range = r, filetype = ft, basename = basename })
          return { by_source = {}, by_asm = {}, unmapped_asm_count = 0 }
        end,
      }
      local stub_highlight = {
        attach = function(src, asm_bufnr, offset, line_map, cfg)
          table.insert(attach_calls, {
            source_bufnr = src,
            asm_bufnr = asm_bufnr,
            offset = offset,
            line_map = line_map,
            cfg = cfg,
          })
        end,
        detach = function(src)
          table.insert(detach_calls, src)
        end,
      }

      -- Act
      local state = window.open(source, range, "c", {}, nil, config.get(), compile_stub, {
        mapping = stub_mapping,
        highlight = stub_highlight,
      })
      table.insert(open_states, state)

      -- Assert
      assert.equals(1, #build_calls)
      assert.equals("c", build_calls[1].filetype)
      assert.equals("snippet.c", build_calls[1].basename)
      assert.equals(10, build_calls[1].range.start_line)
      assert.equals(1, #attach_calls)
      assert.equals(source, attach_calls[1].source_bufnr)
      assert.equals(state.bufnr, attach_calls[1].asm_bufnr)
      -- Offset is the header-line count the renderer prepends (header + blank).
      assert.equals(2, attach_calls[1].offset)
    end)

    it("picks the right snippet basename per filetype", function()
      -- Arrange — one window per filetype, injected mapping records basename.
      local filetypes = { c = "snippet.c", cpp = "snippet.cpp", rust = "snippet.rs", go = "snippet.go" }

      for ft, want in pairs(filetypes) do
        local source = new_source_buffer()
        local compile_stub = stub_compile({ ok = true, asm = "", exit_code = 0, duration_ms = 0 })
        local range = { start_line = 1, end_line = 1, source = "x", label = "x" }
        local seen
        local stub_mapping = {
          build = function(_, _, _, basename)
            seen = basename
            return { by_source = {}, by_asm = {}, unmapped_asm_count = 0 }
          end,
        }
        local stub_highlight = { attach = function() end, detach = function() end }

        -- Act
        local state = window.open(source, range, ft, {}, "package main\n", config.get(), compile_stub, {
          mapping = stub_mapping,
          highlight = stub_highlight,
        })
        table.insert(open_states, state)

        -- Assert
        assert.equals(want, seen, "basename mismatch for filetype " .. ft)
      end
    end)

    it("tracks the function range across edits so a saved buffer recompiles the full current function", function()
      -- Arrange — a 3-line function and a trailing blank; range = lines 1-3.
      local source = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(source, 0, -1, false, {
        "int main() {",
        "  return 0;",
        "}",
        "",
      })
      local compile_stub = stub_compile({ ok = true, asm = "", exit_code = 0, duration_ms = 0 })
      local range = {
        start_line = 1,
        end_line = 3,
        source = "int main() {\n  return 0;\n}",
        label = "function @ line 1-3",
      }
      local state = window.open(source, range, "c", {}, nil, config.get(), compile_stub)
      table.insert(open_states, state)

      -- Act — insert a new statement inside the function; closing brace shifts
      -- from line 3 to line 4.
      vim.api.nvim_buf_set_lines(source, 1, 1, false, { "  int x = 42;" })
      vim.api.nvim_exec_autocmds("BufWritePost", { buffer = source })

      -- Assert — the second compile sees the full function including the
      -- new line and the (now-shifted) closing brace.
      assert.equals(2, #compile_stub.calls)
      local src = compile_stub.calls[2].source
      assert.truthy(src:find("int x = 42;", 1, true), "second compile missing the inserted statement")
      assert.truthy(src:find("return 0;", 1, true), "second compile missing the pre-existing body")
      assert.truthy(src:match("}%s*$"), "second compile missing the closing brace")
    end)

    it("recompiles the asm when the source buffer is saved", function()
      -- Arrange
      local source = new_source_buffer()
      local compile_stub = stub_compile({ ok = true, asm = "mov eax, 1\nret", exit_code = 0, duration_ms = 0 })
      local range = { start_line = 1, end_line = 1, source = "x", label = "x" }

      local state = window.open(source, range, "c", {}, nil, config.get(), compile_stub)
      table.insert(open_states, state)
      assert.equals(1, #compile_stub.calls)

      -- Act — simulate a :w on the source buffer.
      vim.api.nvim_exec_autocmds("BufWritePost", { buffer = source })

      -- Assert
      assert.equals(2, #compile_stub.calls)
    end)

    it("stops recompiling on source save after the asm buffer is wiped", function()
      -- Arrange
      local source = new_source_buffer()
      local compile_stub = stub_compile({ ok = true, asm = "", exit_code = 0, duration_ms = 0 })
      local range = { start_line = 1, end_line = 1, source = "x", label = "x" }

      local state = window.open(source, range, "c", {}, nil, config.get(), compile_stub)
      table.insert(open_states, state)
      vim.api.nvim_buf_delete(state.bufnr, { force = true })

      -- Act
      local before = #compile_stub.calls
      vim.api.nvim_exec_autocmds("BufWritePost", { buffer = source })

      -- Assert
      assert.equals(before, #compile_stub.calls)
    end)

    it("detaches highlight when the asm buffer is wiped", function()
      -- Arrange
      local source = new_source_buffer()
      local compile_stub = stub_compile({ ok = true, asm = "", exit_code = 0, duration_ms = 0 })
      local range = { start_line = 1, end_line = 1, source = "x", label = "x" }
      local detach_calls = {}
      local stub_mapping = {
        build = function()
          return { by_source = {}, by_asm = {}, unmapped_asm_count = 0 }
        end,
      }
      local stub_highlight = {
        attach = function() end,
        detach = function(src)
          table.insert(detach_calls, src)
        end,
      }
      local state = window.open(source, range, "c", {}, nil, config.get(), compile_stub, {
        mapping = stub_mapping,
        highlight = stub_highlight,
      })
      table.insert(open_states, state)

      -- Act
      vim.api.nvim_buf_delete(state.bufnr, { force = true })

      -- Assert
      assert.equals(1, #detach_calls)
      assert.equals(source, detach_calls[1])
    end)
  end)
end)
