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
-- claims a top-level key on their behalf.
vim.keymap.set({ "n", "x" }, "<Plug>(AsmView)", function()
  require("asmview").show({ range = (vim.fn.mode() == "v" or vim.fn.mode() == "V") and 2 or 0 })
end, { desc = "asmview: show assembly" })
