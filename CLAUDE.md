# CLAUDE.md

Context for Claude Code sessions in this repo. Keep terse — this file is loaded on every session.

## What this is

`asmview.nvim` — a Neovim plugin that compiles the function at the cursor (or a selected range) to assembly and shows the result in a floating window. Supports C, C++, Rust, and Go.

## Layout

- `plugin/asmview.lua` — guard + `:Asm` command + `<Plug>(AsmView)` mapping. **No auto-bound keymaps.**
- `lua/asmview/init.lua` — public facade: `setup()`, `show()`, `get_config()`.
- `lua/asmview/config.lua` — defaults + `vim.validate` + `vim.tbl_deep_extend` merge.
- `lua/asmview/types.lua` — LuaCATS classes. Public types belong here.
- `lua/asmview/detect.lua` — filetype → language map, PATH probe, `compile_commands.json` walk, `go_header` extractor.
- `lua/asmview/range.lua` — treesitter-first function range, brace-balanced fallback.
- `lua/asmview/compile.lua` — dispatcher: `run_file_based` for C/C++/Rust (writes `-S` output), `run_go` for Go (temp module + stderr capture).
- `lua/asmview/window.lua` — floating window, buffer-local keymaps, per-buffer state table.
- `lua/asmview/health.lua` — `:checkhealth asmview`.
- `doc/asmview.txt` — vimdoc.

## Conventions (non-obvious, don't drift)

- **Every public function takes an optional `deps` table** for dependency injection. Internal callers use the real module; tests pass stubs. New public APIs must follow this.
- **Every public function has LuaCATS annotations** (`---@param`, `---@return`, `---@class`). Types live in `types.lua`.
- **Every loop over external input has a named cap**. See `GO_HEADER_SCAN_LIMIT`, `compile_commands_search_depth`, `scan_cap`. Never remove these without replacing them.
- **No shell interpolation.** Spawn via `vim.system` with an argv list. The whole plugin runs on argv-list spawns.
- **No auto-bound keymaps.** Expose `<Plug>` mappings and let users bind. This is non-negotiable — it conflicts with user configs.
- **`setup()` is idempotent and side-effect-light.** Validation + option merge. No autocmds, no commands (those live in `plugin/`).
- **Formatting is `stylua.toml` at the repo root** (2 spaces, 120 cols). CI enforces via `make lint`.

## Dev loop

```bash
make lint         # stylua --check lua plugin
make format       # stylua lua plugin
```

Parse-check any lua file after edits:

```bash
nvim --headless --clean -c "luafile lua/asmview/<module>.lua" -c "quit"
```

End-to-end smoke (compose + setup):

```bash
nvim --headless --clean --cmd "set rtp+=." -c "lua assert(require('asmview').setup({}))" -c "quit"
```

## Branch & PR flow

Main is protected (`pull_request`, `non_fast_forward`, `deletion` rules). **Never commit on main.** Create a feature branch, push, open a PR, let CI run, merge. Conventional commit prefixes: `feat`, `fix`, `docs`, `chore`, `ci`, `refactor`, `perf`, `test`, `build`.

The release workflow fires on main pushes via `workflow_run` after CI succeeds; `jedi-knights/go-semantic-release@v0.11.0` picks the next tag from commit types.

## Testing status

**No test suite yet.** CI only runs stylua. The `tests/` directory does not exist. Do not invent empty neospec scaffolding — if we add tests, we add real ones first and the composite action + CI job together.

## Known rough edges

- Function-range detection via brace balancing is heuristic; Go method receivers and C++ templates can confuse it. Treesitter is the first strategy and the one that should be invested in if someone files a parsing issue.
- Go snippets always compile under `package main`, so a function that references unexported identifiers from its original package won't build. That's a design trade — the alternative is checking out the whole module.
- `go-semantic-release` 404'd on the very first `POST /releases` for this repo (empty-releases edge case). The follow-up `fix(doc)` PR is the test to confirm it's resolved.

## Pointers

- Upstream the plugin is modeled after: `https://github.com/0xdeadf1sh/AssemblyForNeovim`
- Sibling plugin whose CI we mirror: `jedi-knights/yoda.nvim` (drops the test/badge jobs since asmview has no suite yet)
