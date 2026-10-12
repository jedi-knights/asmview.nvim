-- tests/asmview/range_spec.lua
-- Characterization tests for asmview.range. These avoid treesitter (it may
-- not be initialized under neospec's minimal init) and exercise the
-- brace-balanced fallback path.

describe("asmview.range", function()
  local range

  local function with_buffer(lines)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    return buf
  end

  before_each(function()
    package.loaded["asmview.range"] = nil
    range = require("asmview.range")
  end)

  describe("enclosing_function() — brace fallback", function()
    it("finds a C-style function around the cursor line", function()
      local buf = with_buffer({
        "int foo(int x) {",
        "  return x * x;",
        "}",
        "",
        "int bar() { return 0; }",
      })
      local s, e = range.enclosing_function(buf, 2, 100)
      assert.equals(1, s)
      assert.equals(3, e)
    end)

    it("finds a Rust fn signature", function()
      local buf = with_buffer({
        "pub fn add(a: i32, b: i32) -> i32 {",
        "    a + b",
        "}",
      })
      local s, e = range.enclosing_function(buf, 2, 100)
      assert.equals(1, s)
      assert.equals(3, e)
    end)

    it("finds a Go func signature", function()
      local buf = with_buffer({
        "func Square(x int) int {",
        "    return x * x",
        "}",
      })
      local s, e = range.enclosing_function(buf, 2, 100)
      assert.equals(1, s)
      assert.equals(3, e)
    end)

    it("returns nil when no function surrounds the cursor", function()
      local buf = with_buffer({ "// just a comment", "// and another" })
      local s = range.enclosing_function(buf, 1, 100)
      assert.is_nil(s)
    end)
  end)

  describe("resolve()", function()
    it("returns an explicit range when line1 ~= line2", function()
      local buf = with_buffer({ "a", "b", "c", "d" })
      local r, err = range.resolve(buf, { line1 = 1, line2 = 3 })
      assert.is_nil(err)
      assert.equals(1, r.start_line)
      assert.equals(3, r.end_line)
      assert.equals("a\nb\nc", r.source)
    end)

    it("falls back to cursor-mode when line1 == line2", function()
      local buf = with_buffer({
        "void foo() {",
        "  do_thing();",
        "}",
      })
      local r, err = range.resolve(buf, { line1 = 2, line2 = 2 })
      assert.is_nil(err)
      assert.equals(1, r.start_line)
      assert.equals(3, r.end_line)
    end)

    it("returns an error when cursor-mode has nothing to enclose", function()
      local buf = with_buffer({ "// nope" })
      local r, err = range.resolve(buf, { line1 = 1, line2 = 1 })
      assert.is_nil(r)
      assert.truthy(err:find("no enclosing function"))
    end)
  end)
end)
