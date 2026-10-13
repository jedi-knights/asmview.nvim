-- tests/asmview/mapping_spec.lua
-- Black-box tests for asmview.mapping. Feeds canned asm fixtures through
-- M.build() and asserts the returned source->asm map. No real compilers.

describe("asmview.mapping", function()
  local mapping

  before_each(function()
    package.loaded["asmview.mapping"] = nil
    mapping = require("asmview.mapping")
  end)

  describe("build() — gas .loc path (C / C++ / Rust)", function()
    it("maps a .loc directive to the asm line immediately following it, shifted by range.start_line", function()
      -- Arrange
      local asm = table.concat({
        '  .file 1 "snippet.c"', -- line 1
        "foo:", -- line 2
        "  .loc 1 2 10", -- line 3  → snippet line 2
        "  mov eax, edi", -- line 4  (first instruction attributed to snippet line 2)
        "  .loc 1 3 1", -- line 5  → snippet line 3
        "  ret", -- line 6  (attributed to snippet line 3)
      }, "\n")
      local range = { start_line = 10, end_line = 15, source = "", label = "" }

      -- Act
      local line_map = mapping.build(asm, range, "c", "snippet.c")

      -- Assert
      -- snippet line 2 + range.start_line(10) - 1 = source line 11
      -- snippet line 3 + range.start_line(10) - 1 = source line 12
      assert.same({ 4 }, line_map.by_source[11])
      assert.same({ 6 }, line_map.by_source[12])
      assert.equals(11, line_map.by_asm[4])
      assert.equals(12, line_map.by_asm[6])
      assert.equals(0, line_map.unmapped_asm_count)
    end)

    it("groups multiple asm instructions under the same source line until the next .loc", function()
      -- Arrange
      local asm = table.concat({
        '  .file 1 "snippet.c"',
        "foo:",
        "  .loc 1 1 1",
        "  mov eax, edi",
        "  add eax, 1",
        "  shl eax, 2",
        "  .loc 1 2 1",
        "  ret",
      }, "\n")
      local range = { start_line = 1, end_line = 5, source = "", label = "" }

      -- Act
      local line_map = mapping.build(asm, range, "c", "snippet.c")

      -- Assert
      assert.same({ 4, 5, 6 }, line_map.by_source[1])
      assert.same({ 8 }, line_map.by_source[2])
    end)

    it("skips .loc entries whose file index does not point at the snippet basename", function()
      -- Arrange: file 1 is a header the snippet #included; file 2 is the snippet.
      local asm = table.concat({
        '  .file 1 "/usr/include/stdio.h"',
        '  .file 2 "snippet.c"',
        "  .loc 1 42 1", -- header origin → should be unmapped
        "  call printf",
        "  .loc 2 1 1", -- snippet origin → mapped
        "  mov eax, 0",
      }, "\n")
      local range = { start_line = 1, end_line = 3, source = "", label = "" }

      -- Act
      local line_map = mapping.build(asm, range, "c", "snippet.c")

      -- Assert
      assert.is_nil(line_map.by_source[42])
      assert.same({ 6 }, line_map.by_source[1])
      assert.is_true(line_map.unmapped_asm_count > 0)
    end)

    it("handles the two-quoted-string .file form that LLVM/Apple clang emits", function()
      -- Arrange: Apple clang / modern LLVM emit `.file N "dir" "basename"`
      -- with an optional trailing md5 digest. The parser must match the
      -- second quoted string (the filename), not the first (the dir).
      local asm = table.concat({
        '  .file 0 "/private/tmp/asmview-livetest" "/var/folders/x/asmview-ABC/snippet.c" md5 0xdead',
        "  .loc 0 2 15 prologue_end",
        "  add w8, w1, w0",
      }, "\n")
      local range = { start_line = 10, end_line = 15, source = "", label = "" }

      -- Act
      local line_map = mapping.build(asm, range, "c", "snippet.c")

      -- Assert
      assert.same({ 3 }, line_map.by_source[11])
    end)

    it("handles .file N with absolute paths by matching on basename", function()
      -- Arrange: rustc emits absolute paths in .file directives.
      local asm = table.concat({
        '  .file 1 "/tmp/asmview-ABCDEF/snippet.rs"',
        "  .loc 1 3 5",
        "  mov eax, 1",
      }, "\n")
      local range = { start_line = 100, end_line = 110, source = "", label = "" }

      -- Act
      local line_map = mapping.build(asm, range, "rust", "snippet.rs")

      -- Assert
      -- snippet line 3 + 100 - 1 = source line 102
      assert.same({ 3 }, line_map.by_source[102])
    end)

    it("returns empty by_source when the asm has no .loc directives", function()
      -- Arrange
      local asm = "foo:\n  mov eax, 1\n  ret\n"
      local range = { start_line = 1, end_line = 3, source = "", label = "" }

      -- Act
      local line_map = mapping.build(asm, range, "c", "snippet.c")

      -- Assert
      assert.same({}, line_map.by_source)
    end)
  end)

  describe("build() — Go stderr path", function()
    it("maps a snippet.go:LINE prefix to the following asm line, shifted by range.start_line", function()
      -- Arrange: go tool compile -S emits lines shaped like
      --   "\t0x0000 00000 (./snippet.go:3)\tMOVQ ..."
      -- plus header lines without the file:line marker.
      local asm = table.concat({
        '"".foo STEXT size=16 args=0x0 locals=0x0',
        '\t0x0000 00000 (./snippet.go:2)\tTEXT\t"".foo(SB), ABIInternal',
        "\t0x0000 00000 (./snippet.go:3)\tMOVQ\tAX, BX",
        "\t0x0003 00003 (./snippet.go:3)\tADDQ\t$1, BX",
        "\t0x0007 00007 (./snippet.go:4)\tRET",
      }, "\n")
      local range = { start_line = 20, end_line = 25, source = "", label = "" }

      -- Act
      local line_map = mapping.build(asm, range, "go", "snippet.go")

      -- Assert
      -- Source line 2 → range.start_line(20) + 2 - 1 = 21
      assert.same({ 2 }, line_map.by_source[21])
      -- Source line 3 → 20 + 3 - 1 = 22  (two asm lines)
      assert.same({ 3, 4 }, line_map.by_source[22])
      -- Source line 4 → 20 + 4 - 1 = 23
      assert.same({ 5 }, line_map.by_source[23])
    end)

    it("ignores Go file:line references that do not match the snippet basename", function()
      -- Arrange
      local asm = table.concat({
        "\t0x0000 00000 (/usr/local/go/src/runtime/asm_amd64.s:10)\tCALL\truntime.foo",
        "\t0x0000 00000 (./snippet.go:1)\tMOVQ\tAX, BX",
      }, "\n")
      local range = { start_line = 1, end_line = 2, source = "", label = "" }

      -- Act
      local line_map = mapping.build(asm, range, "go", "snippet.go")

      -- Assert
      assert.same({ 2 }, line_map.by_source[1])
      assert.is_true(line_map.unmapped_asm_count > 0)
    end)
  end)

  describe("build() — contract", function()
    it("always returns a LineMap with by_source, by_asm, and unmapped_asm_count", function()
      -- Arrange
      local range = { start_line = 1, end_line = 1, source = "", label = "" }

      -- Act
      local line_map = mapping.build("", range, "c", "snippet.c")

      -- Assert
      assert.is_table(line_map.by_source)
      assert.is_table(line_map.by_asm)
      assert.equals(0, line_map.unmapped_asm_count)
    end)

    it("by_asm records the first-hit source line when multiple .loc entries land on the same asm line", function()
      -- Arrange: two consecutive .loc directives with no asm between them —
      -- the following asm line should be attributed to the first .loc.
      local asm = table.concat({
        '  .file 1 "snippet.c"',
        "  .loc 1 5 1",
        "  .loc 1 6 1",
        "  mov eax, 1",
      }, "\n")
      local range = { start_line = 1, end_line = 10, source = "", label = "" }

      -- Act
      local line_map = mapping.build(asm, range, "c", "snippet.c")

      -- Assert — the asm line gets attributed to the most recent .loc (line 6)
      -- because the second .loc superseded the first before any instruction
      -- was emitted. by_source[5] therefore stays empty.
      assert.is_nil(line_map.by_source[5])
      assert.same({ 4 }, line_map.by_source[6])
      assert.equals(6, line_map.by_asm[4])
    end)
  end)
end)
