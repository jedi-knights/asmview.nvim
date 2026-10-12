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
end)
