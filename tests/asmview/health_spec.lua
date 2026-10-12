-- tests/asmview/health_spec.lua
-- Characterization tests for asmview.health. The `check()` function emits
-- diagnostic rows via a `health` surface it accepts through deps — tests
-- inject a fake surface that records every call rather than monkey-patching
-- vim.health globally.

describe("asmview.health", function()
  local health
  local events, fake_health, fake_executable

  before_each(function()
    package.loaded["asmview.health"] = nil
    package.loaded["asmview.config"] = nil
    health = require("asmview.health")

    events = {}
    fake_health = {
      start = function(name)
        table.insert(events, { kind = "start", name = name })
      end,
      ok = function(msg)
        table.insert(events, { kind = "ok", msg = msg })
      end,
      warn = function(msg)
        table.insert(events, { kind = "warn", msg = msg })
      end,
      info = function(msg)
        table.insert(events, { kind = "info", msg = msg })
      end,
      error = function(msg)
        table.insert(events, { kind = "error", msg = msg })
      end,
    }
    fake_executable = function()
      return 1
    end
  end)

  local function events_of_kind(kind)
    local out = {}
    for _, e in ipairs(events) do
      if e.kind == kind then
        table.insert(out, e.msg or e.name)
      end
    end
    return out
  end

  it("emits start sections for the four groups", function()
    require("asmview.config").setup({})
    health.check({ health = fake_health, executable = fake_executable })
    local sections = events_of_kind("start")
    assert.is_true(vim.tbl_contains(sections, "asmview.nvim"))
    assert.is_true(vim.tbl_contains(sections, "asmview — compilers"))
    assert.is_true(vim.tbl_contains(sections, "asmview — demanglers (optional)"))
    assert.is_true(vim.tbl_contains(sections, "asmview — treesitter"))
  end)

  it("reports every configured compiler via check_exe when all are present", function()
    require("asmview.config").setup({})
    health.check({ health = fake_health, executable = fake_executable })
    local oks = events_of_kind("ok")
    assert.is_true(vim.tbl_contains(oks, "cc found on PATH"))
    assert.is_true(vim.tbl_contains(oks, "c++ found on PATH"))
    assert.is_true(vim.tbl_contains(oks, "rustc found on PATH"))
    assert.is_true(vim.tbl_contains(oks, "go found on PATH"))
  end)

  it("warns per missing compiler when PATH probe returns 0", function()
    require("asmview.config").setup({})
    health.check({
      health = fake_health,
      executable = function()
        return 0
      end,
    })
    local warns = events_of_kind("warn")
    assert.is_true(vim.tbl_contains(warns, "cc not found on PATH"))
    assert.is_true(vim.tbl_contains(warns, "rustc not found on PATH"))
  end)

  it("probes c++filt and rustfilt when demangle is enabled", function()
    require("asmview.config").setup({ demangle = true })
    health.check({ health = fake_health, executable = fake_executable })
    local oks = events_of_kind("ok")
    assert.is_true(vim.tbl_contains(oks, "c++filt found on PATH"))
    assert.is_true(vim.tbl_contains(oks, "rustfilt found on PATH"))
  end)

  it("skips demangler probes and emits info when demangle is disabled", function()
    require("asmview.config").setup({ demangle = false })
    health.check({ health = fake_health, executable = fake_executable })
    local oks = events_of_kind("ok")
    local infos = events_of_kind("info")
    assert.is_false(vim.tbl_contains(oks, "c++filt found on PATH"))
    assert.is_true(vim.tbl_contains(infos, "demangle disabled"))
  end)

  it("errors when the config module reports a missing compilers table", function()
    require("asmview.config").setup({})
    -- Inject a config whose get() lacks `compilers`.
    local fake_config = {
      get = function()
        return { demangle = false, compilers = nil }
      end,
    }
    health.check({ health = fake_health, executable = fake_executable, config = fake_config })
    local errors = events_of_kind("error")
    assert.is_true(vim.tbl_contains(errors, "configuration missing compilers table"))
  end)
end)
