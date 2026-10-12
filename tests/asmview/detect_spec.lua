-- tests/asmview/detect_spec.lua
-- Characterization tests for asmview.detect.

describe("asmview.detect", function()
  local detect

  before_each(function()
    package.loaded["asmview.detect"] = nil
    detect = require("asmview.detect")
  end)

  describe("map_filetype()", function()
    it("maps c, cpp, cxx, objcpp, rust, go to their canonical language", function()
      assert.equals("c", detect.map_filetype("c"))
      assert.equals("cpp", detect.map_filetype("cpp"))
      assert.equals("cpp", detect.map_filetype("cxx"))
      assert.equals("cpp", detect.map_filetype("objcpp"))
      assert.equals("rust", detect.map_filetype("rust"))
      assert.equals("go", detect.map_filetype("go"))
    end)

    it("returns nil for unsupported filetypes", function()
      assert.is_nil(detect.map_filetype("python"))
      assert.is_nil(detect.map_filetype("lua"))
      assert.is_nil(detect.map_filetype(""))
    end)
  end)

  describe("has_executable()", function()
    it("delegates to the injected executable probe", function()
      assert.is_true(detect.has_executable("foo", {
        executable = function()
          return 1
        end,
      }))
      assert.is_false(detect.has_executable("foo", {
        executable = function()
          return 0
        end,
      }))
    end)
  end)

  describe("find_compile_commands()", function()
    it("returns the file when it exists at the start directory", function()
      local calls = {}
      local path = detect.find_compile_commands("/proj/src", 6, {
        filereadable = function(p)
          table.insert(calls, p)
          if p == "/proj/src/compile_commands.json" then
            return 1
          end
          return 0
        end,
        fnamemodify = function(p)
          return p:match("(.*)/") or p
        end,
      })
      assert.equals("/proj/src/compile_commands.json", path)
      assert.equals(1, #calls)
    end)

    it("walks up to a parent directory, bounded by max_depth", function()
      local hops = {}
      local path = detect.find_compile_commands("/proj/src/deep", 6, {
        filereadable = function(p)
          table.insert(hops, p)
          if p == "/proj/compile_commands.json" then
            return 1
          end
          return 0
        end,
        fnamemodify = function(p)
          return p:match("(.*)/") or p
        end,
      })
      assert.equals("/proj/compile_commands.json", path)
      assert.equals(3, #hops) -- /proj/src/deep, /proj/src, /proj
    end)

    it("stops at max_depth and returns nil if the file is further up", function()
      local path = detect.find_compile_commands("/a/b/c/d/e", 1, {
        filereadable = function()
          return 0
        end,
        fnamemodify = function(p)
          return p:match("(.*)/") or p
        end,
      })
      assert.is_nil(path)
    end)

    it("errors on negative max_depth", function()
      assert.has_error(function()
        detect.find_compile_commands("/x", -1)
      end)
    end)
  end)

  describe("_filter_flags()", function()
    it("drops argv[0], -c, -S, any -O*, -o <path>, and the input file", function()
      local out = detect._filter_flags(
        { "c++", "-std=c++20", "-O3", "-I./inc", "-c", "-o", "/tmp/x.o", "/src/a.cpp" },
        "/src/a.cpp"
      )
      assert.same({ "-std=c++20", "-I./inc" }, out)
    end)

    it("keeps -D, -W, and arbitrary flags", function()
      local out = detect._filter_flags({ "cc", "-DFOO=1", "-Wno-unused", "/src/a.c" }, "/src/a.c")
      assert.same({ "-DFOO=1", "-Wno-unused" }, out)
    end)
  end)

  describe("flags_for_source()", function()
    local function fake_read(json)
      return function()
        return json
      end
    end

    it("returns flags from the arguments form", function()
      local json = vim.json.encode({
        { file = "/src/a.cpp", arguments = { "c++", "-std=c++20", "-O2", "/src/a.cpp" } },
      })
      local out = detect.flags_for_source("db.json", "/src/a.cpp", { read_file = fake_read(json) })
      assert.same({ "-std=c++20" }, out)
    end)

    it("returns flags from the command form", function()
      local json = vim.json.encode({
        { file = "/src/a.cpp", command = "c++ -I./inc -c -o /tmp/x.o /src/a.cpp" },
      })
      local out = detect.flags_for_source("db.json", "/src/a.cpp", { read_file = fake_read(json) })
      assert.same({ "-I./inc" }, out)
    end)

    it("returns empty table when the file is not in the DB", function()
      local json = vim.json.encode({ { file = "/other.cpp", arguments = { "c++", "/other.cpp" } } })
      local out = detect.flags_for_source("db.json", "/src/a.cpp", { read_file = fake_read(json) })
      assert.same({}, out)
    end)

    it("returns empty table on malformed JSON", function()
      local out = detect.flags_for_source("db.json", "/src/a.cpp", { read_file = fake_read("not json") })
      assert.same({}, out)
    end)
  end)

  describe("go_header()", function()
    local function with_buffer(lines)
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      return buf
    end

    it("forces package main even if the source declared another package", function()
      local buf = with_buffer({ "package widgets", "", "func Foo() {}" })
      local h = detect.go_header(buf)
      assert.truthy(h:find("package main"))
      assert.is_nil(h:find("package widgets"))
    end)

    it("captures a parenthesized import block", function()
      local buf = with_buffer({
        "package foo",
        "",
        "import (",
        '  "fmt"',
        '  "strings"',
        ")",
      })
      local h = detect.go_header(buf)
      assert.truthy(h:find('"fmt"'))
      assert.truthy(h:find('"strings"'))
    end)

    it("captures a single-line import", function()
      local buf = with_buffer({ "package foo", "", 'import "fmt"' })
      local h = detect.go_header(buf)
      assert.truthy(h:find('"fmt"'))
    end)

    it("returns a bare package main when no imports are present", function()
      local buf = with_buffer({ "package foo", "", "func Foo() {}" })
      local h = detect.go_header(buf)
      assert.equals("package main\n", h)
    end)
  end)
end)
