-- plugin/asmview.lua
-- Entry point for asmview.nvim. Minimal by design — all work is
-- deferred into command/mapping bodies so startup cost is near-zero.

if vim.g.loaded_asmview then
  return
end
vim.g.loaded_asmview = true

vim.api.nvim_create_user_command("Asm", function(opts)
  require("asmview").show(opts)
end, {
  range = true,
  desc = "asmview: show assembly for the function at cursor or selected range",
})

-- <Plug> mappings — users bind these in their config; asmview never
-- claims a top-level key on their behalf. Separate n and x definitions
-- so each callback knows its mode by virtue of which mapping fired,
-- instead of sniffing vim.fn.mode() at call time.
vim.keymap.set("n", "<Plug>(AsmView)", function()
  require("asmview").show({ range = 0 })
end, { desc = "asmview: show assembly (function at cursor)" })

vim.keymap.set("x", "<Plug>(AsmView)", function()
  require("asmview").show({ range = 2 })
end, { desc = "asmview: show assembly (visual selection)" })
