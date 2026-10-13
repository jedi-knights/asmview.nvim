-- tests/asmview/highlight_spec.lua
-- Black-box tests for asmview.highlight. Uses real scratch buffers; triggers
-- CursorMoved via nvim_exec_autocmds. Asserts extmarks on the asm buffer.

describe("asmview.highlight", function()
  local highlight
  local created_bufs

  before_each(function()
    package.loaded["asmview.highlight"] = nil
    package.loaded["asmview.config"] = nil
    highlight = require("asmview.highlight")
    created_bufs = {}
  end)

  after_each(function()
    for _, buf in ipairs(created_bufs) do
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
  end)

  local function new_buf(lines)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    table.insert(created_bufs, buf)
    return buf
  end

  local function cfg()
    return require("asmview.config").defaults()
  end

  local function count_extmarks(bufnr, ns)
    return #vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
  end

  local function get_ns()
    return vim.api.nvim_create_namespace("asmview_mapping")
  end

  describe("attach() — initial state", function()
    it("creates the AsmviewSourceLine highlight group with a default link", function()
      -- Arrange
      local source = new_buf({ "a", "b" })
      local asm = new_buf({ "x", "y" })
      local line_map = { by_source = {}, by_asm = {}, unmapped_asm_count = 0 }

      -- Act
      highlight.attach(source, asm, 0, line_map, cfg())

      -- Assert
      local hl = vim.api.nvim_get_hl(0, { name = "AsmviewSourceLine" })
      assert.is_truthy(hl)
    end)

    it("sets no extmarks before the cursor moves", function()
      -- Arrange
      local source = new_buf({ "src 1", "src 2" })
      local asm = new_buf({ "asm 1", "asm 2", "asm 3" })
      local line_map = { by_source = { [1] = { 1 } }, by_asm = { [1] = 1 }, unmapped_asm_count = 0 }

      -- Act
      highlight.attach(source, asm, 0, line_map, cfg())

      -- Assert
      assert.equals(0, count_extmarks(asm, get_ns()))
    end)
  end)

  describe("attach() — CursorMoved behavior", function()
    local function trigger_cursor_moved(bufnr)
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = bufnr })
    end

    it("places extmarks on every mapped asm line when the source cursor is on a mapped line", function()
      -- Arrange
      local source = new_buf({ "src 1", "src 2", "src 3" })
      vim.api.nvim_set_current_buf(source)
      local asm = new_buf({ "asm 1", "asm 2", "asm 3", "asm 4" })
      local line_map = {
        by_source = { [2] = { 2, 3 } },
        by_asm = { [2] = 2, [3] = 2 },
        unmapped_asm_count = 0,
      }
      highlight.attach(source, asm, 0, line_map, cfg())

      -- Act
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      trigger_cursor_moved(source)

      -- Assert
      local marks = vim.api.nvim_buf_get_extmarks(asm, get_ns(), 0, -1, {})
      assert.equals(2, #marks)
      -- Extmark rows are 0-indexed → asm line 2 → row 1, asm line 3 → row 2.
      local rows = { marks[1][2], marks[2][2] }
      table.sort(rows)
      assert.same({ 1, 2 }, rows)
    end)

    it("clears extmarks when the cursor moves to an unmapped source line", function()
      -- Arrange
      local source = new_buf({ "src 1", "src 2" })
      vim.api.nvim_set_current_buf(source)
      local asm = new_buf({ "asm 1", "asm 2" })
      local line_map = {
        by_source = { [1] = { 1 } },
        by_asm = { [1] = 1 },
        unmapped_asm_count = 0,
      }
      highlight.attach(source, asm, 0, line_map, cfg())

      -- Act — first move to a mapped line, then to an unmapped one.
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      trigger_cursor_moved(source)
      local before = count_extmarks(asm, get_ns())

      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      trigger_cursor_moved(source)
      local after = count_extmarks(asm, get_ns())

      -- Assert
      assert.equals(1, before)
      assert.equals(0, after)
    end)

    it("respects the asm_line_offset by shifting extmark rows", function()
      -- Arrange: window.lua renders a 2-line header before the asm — the
      -- caller passes asm_line_offset=2 so the mapping's row-1 lands on
      -- extmark row 2 (0-indexed row 2 == buffer line 3).
      local source = new_buf({ "src 1" })
      vim.api.nvim_set_current_buf(source)
      local asm = new_buf({ "header 1", "header 2", "asm 1", "asm 2" })
      local line_map = {
        by_source = { [1] = { 1, 2 } },
        by_asm = { [1] = 1, [2] = 1 },
        unmapped_asm_count = 0,
      }
      highlight.attach(source, asm, 2, line_map, cfg())

      -- Act
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      trigger_cursor_moved(source)

      -- Assert
      local marks = vim.api.nvim_buf_get_extmarks(asm, get_ns(), 0, -1, {})
      local rows = {}
      for _, m in ipairs(marks) do
        table.insert(rows, m[2])
      end
      table.sort(rows)
      -- asm line 1 at offset 2 → extmark row 2; asm line 2 → row 3
      assert.same({ 2, 3 }, rows)
    end)

    it("is a no-op after the asm buffer is wiped", function()
      -- Arrange
      local source = new_buf({ "src 1" })
      vim.api.nvim_set_current_buf(source)
      local asm = new_buf({ "asm 1" })
      local line_map = {
        by_source = { [1] = { 1 } },
        by_asm = { [1] = 1 },
        unmapped_asm_count = 0,
      }
      highlight.attach(source, asm, 0, line_map, cfg())
      vim.api.nvim_buf_delete(asm, { force = true })

      -- Act — triggering after the buffer is gone must not raise.
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      local ok = pcall(trigger_cursor_moved, source)

      -- Assert
      assert.is_true(ok)
    end)
  end)

  describe("attach() — cap on highlighted asm lines", function()
    it("caps extmarks per source line at MAX_HIGHLIGHT_EXTMARKS", function()
      -- Arrange: source line 1 maps to 100 asm lines; expect <= 64 extmarks.
      local source = new_buf({ "src 1" })
      vim.api.nvim_set_current_buf(source)
      local asm_lines = {}
      local asm_indices = {}
      for i = 1, 100 do
        asm_lines[i] = "asm " .. i
        asm_indices[i] = i
      end
      local asm = new_buf(asm_lines)
      local by_asm = {}
      for _, i in ipairs(asm_indices) do
        by_asm[i] = 1
      end
      local line_map = { by_source = { [1] = asm_indices }, by_asm = by_asm, unmapped_asm_count = 0 }
      highlight.attach(source, asm, 0, line_map, cfg())

      -- Act
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = source })

      -- Assert
      local count = count_extmarks(asm, get_ns())
      assert.is_true(count > 0)
      assert.is_true(count <= 64, "expected cap at 64, got " .. count)
    end)
  end)

  describe("detach()", function()
    it("prevents further highlighting after being called", function()
      -- Arrange
      local source = new_buf({ "src 1" })
      vim.api.nvim_set_current_buf(source)
      local asm = new_buf({ "asm 1" })
      local line_map = {
        by_source = { [1] = { 1 } },
        by_asm = { [1] = 1 },
        unmapped_asm_count = 0,
      }
      highlight.attach(source, asm, 0, line_map, cfg())

      -- Act
      highlight.detach(source)
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = source })

      -- Assert
      assert.equals(0, count_extmarks(asm, get_ns()))
    end)
  end)
end)
