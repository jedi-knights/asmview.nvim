-- lua/asmview/highlight.lua
-- Namespace + CursorMoved-driven extmark highlights on the asm buffer. The
-- autocmd lives on the source buffer so it fires naturally as the user
-- navigates source; the extmarks live on the asm buffer so colorscheme
-- integration (link = CursorLine) works out of the box.

local M = {}

-- Cap on extmarks per source line. Hot inlined loops can map one source line
-- to hundreds of asm lines; past this we cap and annotate the last mark with
-- a `[+N more]` tag so the user knows the cap tripped. Named per
-- rules/algorithmic-complexity.md — the input (compiler output) is
-- user-controlled.
local MAX_HIGHLIGHT_EXTMARKS = 64

local NAMESPACE = "asmview_mapping"

---Compose the augroup name for a given source buffer. Keeping the augroup
---per-source lets multiple asm sessions on different source buffers coexist
---without cross-talk.
---@param source_bufnr integer
---@return string
local function augroup_name(source_bufnr)
  return "asmview_highlight_" .. source_bufnr
end

---Attach a CursorMoved listener on `source_bufnr` that mirror-highlights the
---asm lines matching the cursor's current source line onto `asm_bufnr`.
---
---`asm_line_offset` is the number of non-asm lines rendered before the asm
---body in the asm buffer (window.lua currently prepends a 2-line header).
---Mapping indices are 1-based into the raw asm text; the autocmd shifts to
---0-based buffer rows by adding `asm_line_offset` and subtracting 1.
---@param source_bufnr integer
---@param asm_bufnr integer
---@param asm_line_offset integer Lines rendered before the asm body (0 if none).
---@param line_map asmview.LineMap
---@param cfg asmview.Config
---@param deps? table Reserved for test injection.
function M.attach(source_bufnr, asm_bufnr, asm_line_offset, line_map, cfg, deps)
  assert(type(source_bufnr) == "number", "source_bufnr required")
  assert(type(asm_bufnr) == "number", "asm_bufnr required")
  assert(type(asm_line_offset) == "number" and asm_line_offset >= 0, "asm_line_offset must be >= 0")
  assert(type(line_map) == "table" and type(line_map.by_source) == "table", "line_map.by_source required")
  assert(type(cfg) == "table", "cfg required")
  _ = deps -- reserved; present for parity with other asmview modules

  -- `default = true` lets a user's colorscheme override by setting their own
  -- AsmviewSourceLine group; idempotent so a per-attach re-set is safe.
  vim.api.nvim_set_hl(0, "AsmviewSourceLine", { link = "CursorLine", default = true })

  local ns = vim.api.nvim_create_namespace(NAMESPACE)
  local group = vim.api.nvim_create_augroup(augroup_name(source_bufnr), { clear = true })

  local function refresh()
    -- Guard against the asm buffer being wiped out from under the autocmd
    -- (user closed the asm split with `q` while leaving the source open).
    if not vim.api.nvim_buf_is_valid(asm_bufnr) then
      return
    end

    vim.api.nvim_buf_clear_namespace(asm_bufnr, ns, 0, -1)

    local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
    local asm_lines = line_map.by_source[cursor_line]
    if not asm_lines or #asm_lines == 0 then
      return
    end

    local total_asm_rows = vim.api.nvim_buf_line_count(asm_bufnr)
    local placed = 0
    for i = 1, math.min(#asm_lines, MAX_HIGHLIGHT_EXTMARKS) do
      -- Shift raw-asm 1-based index into buffer 0-based row.
      local row = asm_lines[i] + asm_line_offset - 1
      if row >= 0 and row < total_asm_rows then
        local opts = { line_hl_group = "AsmviewSourceLine" }
        -- On the final allowed extmark, append a "[+N more]" tag when the
        -- cap tripped so the user sees that highlighting was truncated.
        if i == MAX_HIGHLIGHT_EXTMARKS and #asm_lines > MAX_HIGHLIGHT_EXTMARKS then
          opts.virt_text = { { string.format("  [+%d more]", #asm_lines - MAX_HIGHLIGHT_EXTMARKS), "Comment" } }
          opts.virt_text_pos = "eol"
        end
        vim.api.nvim_buf_set_extmark(asm_bufnr, ns, row, 0, opts)
        placed = placed + 1
      end
    end
    _ = placed -- extmark count is observable via nvim_buf_get_extmarks; no caller consumes this
  end

  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = group,
    buffer = source_bufnr,
    desc = "asmview: mirror source cursor on the asm buffer",
    callback = refresh,
  })
end

---Remove the CursorMoved listener for `source_bufnr`. Safe to call even if
---no attach ever ran for this buffer — the clear flag on
---`nvim_create_augroup` makes the delete idempotent.
---@param source_bufnr integer
function M.detach(source_bufnr)
  assert(type(source_bufnr) == "number", "source_bufnr required")
  local name = augroup_name(source_bufnr)
  -- `pcall` because `nvim_del_augroup_by_name` raises on an unknown group;
  -- detach must stay idempotent so window.lua's BufWipeout can call it
  -- unconditionally.
  pcall(vim.api.nvim_del_augroup_by_name, name)
end

return M
