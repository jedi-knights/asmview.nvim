-- tests/asmview/types_spec.lua
-- Smoke test for the LuaCATS type module. It is intentionally content-free
-- at runtime (just `return {}`), but a require path through it still has
-- to parse — this spec catches the moment someone accidentally puts
-- executable code in there without a seam.

describe("asmview.types", function()
  it("loads without error and exposes no runtime surface", function()
    package.loaded["asmview.types"] = nil
    local types = require("asmview.types")
    assert.same({}, types)
  end)
end)
