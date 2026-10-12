# Changelog

All notable changes to asmview.nvim are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The authoritative per-release notes live on the
[GitHub Releases page](https://github.com/jedi-knights/asmview.nvim/releases).
This file is the project-root summary and is updated manually alongside each
release — see `CLAUDE.md` for the maintenance protocol.

## [Unreleased]

## [0.1.4] - 2026-10-12

### Fixed

- Added `.semantic-release.yaml` at the repo root with `github.owner` and
  `github.repo` populated. Without this file the upstream
  `jedi-knights/go-semantic-release@v0.11.0` silently POSTs to
  `/repos///releases` and 404s on every main push; the symptom is the tag
  landing on origin but no Release page getting created, requiring a manual
  `gh release create` dance. Root cause writeup lives in upstream issue
  [`jedi-knights/go-semantic-release#35`](https://github.com/jedi-knights/go-semantic-release/issues/35).
  First release to publish end-to-end without manual intervention. (#10)

## [0.1.3] - 2026-10-12

### Fixed

- Addressed 19 adversarial-review findings across 5 `/code grill` passes. Key
  changes: hop out of libuv fast-event context via `vim.schedule` before any
  sync I/O or nested `vim.system`; `demangle()` rewritten as async with a
  continuation callback (no `:wait()` blocking the main thread); `recompile`
  re-fetches current source from the buffer on each `R`, so edits are
  reflected in the assembly output (previously silently stale);
  `nvim_buf_is_valid` guard against `:bdelete`-then-`R` tracebacks; bounded
  caps on compile_commands DB size (`10 MB`), entry count (`100 000`), and
  per-entry argv length (`512`); explicit `vim.validate` at `range.resolve`
  entry; `nvim_win_is_valid` assertion after `nvim_open_win`; brace-counter
  comment stripping in the range fallback; `health.check()` emits
  `health.error` for missing compiler keys instead of raising; comment-strip
  for `//` and `--` single-line comments in the brace-balance walk; `cwd`
  falls back to `vim.fn.getcwd()` for unsaved source buffers. (#9)

## [0.1.2] - 2026-10-12

### Added

- CI, Badge, Tests, Coverage badge row in the README. (#5)
- `make test-coverage` scoped to `lua/asmview` with branch instrumentation
  and lcov output. (#5)
- `.github/workflows/badge.yaml` — publishes the HTML coverage report to
  GitHub Pages after each successful CI run. (#5)
- 28 characterization specs covering the `init`, `health`, `compile`, and
  `window` modules. Coverage jumped from 42.8% to 82.4%. (#6)
- Specs across the remaining modules to lift every file above the 80%
  floor; `types` to 100%, `range` to 92%, `compile` to 86%. Suite grew to
  87 passing. Introduced the deps-injection pattern on `health.check` to
  avoid monkey-patching `vim.health`. (#7)

### Fixed

- `permissions: contents: read` block on `.github/workflows/ci.yml`
  (OWASP A02:2025); release.yml and badge.yaml already had narrower
  explicit permissions. (#8)
- Dead `out_path` fallback branch in `compile.lua` removed. (#8)
- `vim.validate` added at `build_argv` and `build_go_argv` entry so misuse
  of the public argv-builder surface fails at the function boundary, not
  deep inside argv assembly. (#8)
- Treesitter ancestor walk capped at `MAX_AST_DEPTH = 1000`
  (`rules/algorithmic-complexity.md` on bounded loops over user-controlled
  input). (#8)
- `float_opts` clamps to `vim.o.columns − 2` × `vim.o.lines − 2` so
  `nvim_open_win` never receives dimensions larger than the terminal. (#8)
- `<Plug>(AsmView)` split into one nmap and one xmap so each callback
  knows its mode without `vim.fn.mode()` sniffing. (#8)

## [0.1.1] - 2026-10-12

### Added

- neospec test harness with 50 initial characterization specs covering
  the pure/injectable surface of every module. Mirrors yoda.nvim's install
  pattern via the shared `install-neospec` composite action. (#4)
- `make test` and `make test-file FILE=…` targets; `Test` job in CI
  gating alongside Lint; Validate now gates on both. (#4)
- `CLAUDE.md` at the repo root with the project context, non-obvious
  conventions, dev loop, branch/PR flow, testing style, and known rough
  edges. (#4)

### Fixed

- Stale "C/C++/Rust" header in `doc/asmview.txt` — now reads
  "C/C++/Rust/Go" to match the actual language support. (#2)

## [0.1.0] - 2026-10-12

### Added

- Initial plugin scaffold. Compiles the function at the cursor to assembly
  and renders the result in a floating window. Supports **C**, **C++**,
  and **Rust** via a `-S` / `--emit=asm` file-output pipeline through
  `vim.system`. Modular layout under `lua/asmview/` with the
  deps-injection pattern on every public function, LuaCATS annotations
  throughout, bounded loops with named caps, no auto-bound keymaps
  (`:Asm` + `<Plug>(AsmView)` only), `vim.validate`-driven config, and a
  `:checkhealth asmview` surface.
- **Go** support via `go build -gcflags=-S`. Each compile synthesizes a
  temp module (`go.mod` + `snippet.go`) that forces `package main`,
  prepends the buffer's import block, and appends a `func main() {}`
  stub if the snippet lacks one. Assembly is captured from the gc
  compiler's stderr. opt_level cycling collapses to a two-state toggle
  on Go (`"0"` → `-S -N -l`; anything else → `-S`).
- `.github/workflows/ci.yml` (Lint via stylua, Validate gate) and
  `.github/workflows/release.yml` chaining
  `jedi-knights/go-semantic-release@v0.11.0` on CI success. (#1)
- `Makefile` with `lint`/`format` targets. (#1)

[Unreleased]: https://github.com/jedi-knights/asmview.nvim/compare/v0.1.4...HEAD
[0.1.4]: https://github.com/jedi-knights/asmview.nvim/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/jedi-knights/asmview.nvim/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/jedi-knights/asmview.nvim/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/jedi-knights/asmview.nvim/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/jedi-knights/asmview.nvim/releases/tag/v0.1.0
