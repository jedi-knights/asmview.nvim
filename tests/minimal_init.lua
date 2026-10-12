-- tests/minimal_init.lua
-- Minimal init for neospec test runs. Passed via `neospec run --init-file`.
--
-- neospec supplies describe / it / before_each / after_each and the assert
-- namespace from its own embedded harness. This file just gets our modules
-- on the require path and silences noisy editor side-effects during tests.

local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")

vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:append(root .. "/lua")

package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

vim.opt.swapfile = false
vim.opt.backup = false
vim.opt.writebackup = false
vim.opt.undofile = false

-- Silence vim.notify so the suite doesn't spew error popups when we
-- deliberately feed invalid configs to validate error paths.
vim.notify = function() end
