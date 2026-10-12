# CLAUDE.md

Context for Claude Code sessions in this repo. Keep terse — loaded on every session.

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
- `tests/minimal_init.lua` — neospec init.
- `tests/asmview/*_spec.lua` — black-box specs per module.

## Conventions (non-obvious, don't drift)

- **TDD is required.** Red → green → refactor. Characterization tests (black-box through the public API) are the fallback shape for existing code; new behavior gets a failing test first. See `rules/tdd.md` and `rules/black-box-testing.md`.
- **Every public function takes an optional `deps` table** for dependency injection. Specs pass stubs; production callers get `vim.*`. New public APIs must follow this.
- **Every public function has LuaCATS annotations** (`---@param`, `---@return`, `---@class`). Public types live in `types.lua`.
- **Every loop over external input has a named cap.** `GO_HEADER_SCAN_LIMIT`, `compile_commands_search_depth`, `scan_cap`. Never remove these without replacing them.
- **No shell interpolation.** Spawn via `vim.system` with argv lists.
- **No auto-bound keymaps.** Expose `<Plug>` mappings and let users bind. Non-negotiable — conflicts with user configs.
- **`setup()` is idempotent and side-effect-light.** Validation + option merge. No autocmds, no commands (those live in `plugin/`).
- **Formatting is `stylua.toml` at the repo root** (2 spaces, 120 cols). CI enforces via `make lint`.

## Dev loop

```bash
make lint              # stylua --check lua plugin
make format            # stylua lua plugin
make test              # neospec run against tests/asmview/*_spec.lua
make test-file FILE=tests/asmview/config_spec.lua
make test-coverage     # emits coverage/lcov.info + a console pct line
```

`make test` requires `neospec` on PATH. Install from https://github.com/jedi-knights/neospec/releases.

Parse-check a single lua file after edits:

```bash
nvim --headless --clean -c "luafile lua/asmview/<module>.lua" -c "quit"
```

## Branch & PR flow

Main is protected (`pull_request`, `non_fast_forward`, `deletion` rules). **Never commit on main.** Create a feature branch, push, open a PR, let CI run, merge. Conventional commit prefixes: `feat`, `fix`, `docs`, `chore`, `ci`, `refactor`, `perf`, `test`, `build`.

Release workflow fires on main pushes via `workflow_run` after CI succeeds; `jedi-knights/go-semantic-release@v0.11.0` picks the next tag from commit types. **Owner and repo are configured in `.semantic-release.yaml` at the repo root** — without that file the action silently POSTs to `/repos///releases` and 404s (upstream `jedi-knights/go-semantic-release#35`).

**CHANGELOG.md maintenance.** On every release-bumping merge to main (anything that produces a new `v0.x.y` tag), add a top-level section under `## [Unreleased]` in `CHANGELOG.md` with the new version and date, in Keep-a-Changelog format. Also update the compare-URL footer. The file is maintained manually rather than via `go-semantic-release`'s `changelog_file` prepare step, because the auto-commit requires push-to-main authority that this repo's branch ruleset denies the default `GITHUB_TOKEN` (same reason the Badge workflow doesn't auto-commit the Coverage %). The GitHub Releases page remains the authoritative per-release source; `CHANGELOG.md` is the human-readable summary at the repo root.

## Testing

- Runner: `neospec` (same as yoda.nvim; shares the composite install action).
- Specs live under `tests/asmview/<module>_spec.lua`, one file per module.
- Style: black-box through the public API. Use the `deps` table to inject stubs — never monkeypatch `vim.*` globals.
- Buffer-touching helpers (`detect.go_header`, `range.*`) create real scratch buffers with `vim.api.nvim_create_buf(false, true)`.
- Integration (full compile with `vim.system`) is deliberately **not** covered — those paths need real `cc`/`c++`/`rustc`/`go` and belong in a future integration tier.

## Known rough edges

- Function-range detection via brace balancing is heuristic; Go method receivers and C++ templates can confuse it. Treesitter is the first strategy and the one to invest in if someone files a parsing issue.
- Go snippets always compile under `package main`, so a function that references unexported identifiers from its original package won't build. Design trade — the alternative is checking out the whole module.
- Badge workflow (`.github/workflows/badge.yaml`) publishes the HTML coverage report to GitHub Pages after each successful CI run on main. It does **not** auto-commit the Coverage percentage back into README — doing so requires a `GH_TOKEN` repo secret with admin role that can bypass the branch ruleset (as yoda.nvim has). When coverage changes materially, update the shields.io URL in README manually.

## Pointers

- Upstream the plugin is modeled after: https://github.com/0xdeadf1sh/AssemblyForNeovim
- Sibling plugin whose CI we mirror: `jedi-knights/yoda.nvim`
