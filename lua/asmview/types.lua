-- lua/asmview/types.lua
-- Type definitions for asmview.nvim

---@class asmview.Config
---@field compilers asmview.CompilerConfig Per-language compiler settings
---@field opt_levels string[] Allowed optimization levels (cycled by +/-)
---@field default_opt string Starting optimization level (must appear in opt_levels)
---@field syntax string Assembly syntax: "intel" or "att" (C/C++ only)
---@field demangle boolean Pipe compiler output through c++filt / rustfilt when available
---@field use_compile_commands boolean Honor compile_commands.json when present
---@field compile_commands_search_depth integer Max dir depth to walk up looking for compile_commands.json
---@field float asmview.FloatConfig Floating window geometry
---@field keymaps asmview.KeymapConfig Buffer-local keymap bindings in the asm window
---@field notify_title string Title used in vim.notify calls
---@field log_level integer Minimum log level (vim.log.levels.*)

---@class asmview.CompilerConfig
---@field c asmview.CompilerSpec
---@field cpp asmview.CompilerSpec
---@field rust asmview.CompilerSpec
---@field go asmview.CompilerSpec

---@class asmview.CompilerSpec
---@field cmd string Executable name or absolute path
---@field extra_args string[] Extra args appended to every invocation

---@class asmview.FloatConfig
---@field width_ratio number Fraction of columns (0..1)
---@field height_ratio number Fraction of lines (0..1)
---@field border string Border style passed to nvim_open_win

---@class asmview.KeymapConfig
---@field increase_opt string Default: "+"
---@field decrease_opt string Default: "-"
---@field rerun string Default: "R"
---@field close string Default: "q"

---@class asmview.Request
---@field bufnr integer Source buffer whose code we are compiling
---@field filetype "c"|"cpp"|"rust"|"go" Detected source language
---@field source string Full source snippet to compile (standalone unit)
---@field opt_level string Optimization flag value (member of config.opt_levels)
---@field cwd string Working directory for the compiler process
---@field cflags string[] Flags harvested from compile_commands.json (C/C++ only; empty otherwise)
---@field go_header? string Package + import block prepended to a Go snippet (Go only)

---@class asmview.Result
---@field ok boolean Whether the compiler exited 0
---@field asm string Assembly text (or compiler stderr on failure)
---@field exit_code integer Compiler exit code
---@field duration_ms integer Wall-clock duration

---@class asmview.Range
---@field start_line integer 1-based inclusive
---@field end_line integer 1-based inclusive
---@field source string Lines joined with "\n"
---@field label string Human-readable label (e.g. "foo()" or "lines 10-20")

---@class asmview.LineMap
---@field by_source table<integer, integer[]> Source line (1-based, buffer-relative) → asm line indices (1-based into the raw asm text)
---@field by_asm table<integer, integer> Reverse index: asm line → first source line that pointed at it
---@field unmapped_asm_count integer Count of asm lines attributed to a .loc/path that did not match the compiled snippet

return {}
