<h1 align="center">asmview.nvim</h1>

<p align="center">
  Compile the function at your cursor to assembly, side-by-side with your source, with the asm lines
  for the current source line highlighted as you navigate.
</p>

<p align="center">
  <strong>C</strong> · <strong>C++</strong> · <strong>Rust</strong> · <strong>Go</strong>
</p>

<p align="center">
  <a href="https://github.com/jedi-knights/asmview.nvim/actions/workflows/ci.yml"><img src="https://github.com/jedi-knights/asmview.nvim/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/jedi-knights/asmview.nvim/actions/workflows/badge.yaml"><img src="https://github.com/jedi-knights/asmview.nvim/actions/workflows/badge.yaml/badge.svg" alt="Badge"></a>
  <a href="https://github.com/jedi-knights/asmview.nvim/actions/workflows/release.yml"><img src="https://github.com/jedi-knights/asmview.nvim/actions/workflows/release.yml/badge.svg" alt="Release"></a>
  <img src="https://img.shields.io/badge/Tests-98%20passing-brightgreen" alt="Tests">
  <a href="https://jedi-knights.github.io/asmview.nvim/"><img src="https://img.shields.io/badge/Coverage-90%2E3%25-brightgreen" alt="Coverage"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License"></a>
  <a href="https://github.com/jedi-knights/asmview.nvim/releases/latest"><img src="https://img.shields.io/github/v/release/jedi-knights/asmview.nvim?label=release" alt="Latest release"></a>
</p>

<p align="center">
  <a href="#overview">Overview</a> ·
  <a href="#features">Features</a> ·
  <a href="#requirements">Requirements</a> ·
  <a href="#installation">Installation</a> ·
  <a href="#usage">Usage</a> ·
  <a href="#examples">Examples</a> ·
  <a href="#configuration">Configuration</a> ·
  <a href="#development">Development</a> ·
  <a href="#architecture">Architecture</a> ·
  <a href="#contributing">Contributing</a>
</p>

## Overview

You wonder what your inline function actually compiles to — did the compiler
hoist that bounds check? did it keep the SIMD intrinsic? did it inline that
helper? Normally you'd open [Compiler Explorer](https://godbolt.org), paste the
function, pick the compiler, pick the optimization level, paste in the include
guards and the project `-D` flags, and hope the result matches what your
build system actually emits.

The cost of doing that round-trip properly is where the friction actually
sits: hunting the project's `-D` flags out of a build log, pasting in the
include guards one at a time, and reconciling the copy-paste divergence
between the snippet you tested on godbolt and the function your build
actually ships.

**asmview** does the same thing inside the editor. Put the cursor on a
function, run `:Asm`, and a right-side vertical split shows the assembly —
compiled with the real toolchain on your `$PATH`, the real flags from your
`compile_commands.json`, and the function selected directly from your current
buffer. As you navigate the source, the asm lines that correspond to the
current source line light up on the right. `+` and `-` cycle through
optimization levels in place. `R` reruns the compiler. No browser, no
copy-paste, no divergence between what you see and what ships.

Supports **C**, **C++**, **Rust**, and **Go**. For C/C++ the exact flags from
`compile_commands.json` are harvested (minus the input file and `-O` so you
can cycle). For Go the gc compiler's `-gcflags=-S` output is captured from
stderr; snippets are compiled as a synthesized `package main`.

## Features

- **One keystroke, no leaving the editor** — `:Asm` on the function at the
  cursor; `:'<,'>Asm` on a visual selection.
- **Side-by-side layout** — a right-side vsplit; focus stays in source so
  `/`, LSP, treesitter, and marks keep working as you read.
- **Source→asm line sync** — the asm lines that correspond to the source
  line under your cursor are highlighted via the `AsmviewSourceLine`
  highlight group (links to `CursorLine` by default; override to taste).
  Powered by DWARF `.loc` directives (C/C++/Rust) and the `(file:line)`
  prefixes `go tool compile -S` emits (Go).
- **Live optimization cycling** — `+` / `-` in the asm window re-compiles at
  the next / previous `-O` level with the same source.
- **Honors `compile_commands.json`** — picks up the exact project flags
  (CMake, Bear, meson). Strips `-c`, `-S`, `-O*`, `-o`, and the input file
  itself so asmview owns those knobs.
- **Four languages** — C, C++, Rust, Go. Each goes through its own compile
  path with native toolchain conventions (`-S` for C/C++, `--emit=asm` for
  rustc, `go build -gcflags=-S` for go).
- **Symbol demangling** — pipes output through `c++filt` or `rustfilt` when
  they're on PATH.
- **Intel or AT&T syntax** — configurable for C/C++.
- **No auto-bound keymaps** — exposes `:Asm` and `<Plug>(AsmView)` only; you
  decide the top-level binding.
- **`:checkhealth asmview`** — confirms compilers, demanglers, and
  treesitter availability.

## Requirements

- **Neovim ≥ 0.10** — uses `vim.system`, `vim.uv`, `vim.health`
- **At least one compiler** on `PATH`:
  - `cc` for C
  - `c++` for C++
  - `rustc` for Rust
  - `go` for Go
- **Optional**:
  - `c++filt` / `rustfilt` — symbol demangling
  - `compile_commands.json` (CMake, Bear, meson) — faithful C/C++ project flags

## Installation

<details open>
<summary><strong>lazy.nvim</strong></summary>

```lua
{
  "jedi-knights/asmview.nvim",
  cmd = "Asm",
  keys = {
    { "<leader>a", "<Plug>(AsmView)", mode = { "n", "x" }, desc = "View assembly" },
  },
  opts = {},
}
```

</details>

<details>
<summary><strong>Native <code>vim.pack</code> (Neovim ≥ 0.12)</strong></summary>

`vim.pack.add` does not run `setup()` or wire keymaps for you — the follow-up
calls are explicit:

```lua
vim.pack.add({
  { src = "https://github.com/jedi-knights/asmview.nvim", version = "v0.2.0" },
})

require("asmview").setup({})
vim.keymap.set({ "n", "x" }, "<leader>a", "<Plug>(AsmView)", { desc = "View assembly" })
```

Omit `version` to track the default branch, or pin to a specific tag or
branch name. `vim.pack.add` is idempotent — it clones on first run and does
nothing on subsequent runs. Use `:lua vim.pack.update()` to pull new commits.

</details>

<details>
<summary><strong>packer.nvim</strong></summary>

```lua
use({
  "jedi-knights/asmview.nvim",
  config = function()
    require("asmview").setup()
  end,
})
```

</details>

## Usage

| Trigger                      | Behavior                                     |
| ---------------------------- | -------------------------------------------- |
| `:Asm` *(normal mode)*       | Compile the function enclosing the cursor    |
| `:'<,'>Asm`                  | Compile the visually-selected lines          |
| `<Plug>(AsmView)` *(n)*      | Function around the cursor                   |
| `<Plug>(AsmView)` *(x)*      | Visual selection                             |

Inside the asm window:

| Key | Action                                     |
| --- | ------------------------------------------ |
| `+` | Step optimization level up (`O0` → `Oz`)   |
| `-` | Step optimization level down               |
| `R` | Rerun the compiler at current settings     |
| `q` | Close the window                           |

The header line shows the range, the current `-O` level, the syntax
(intel/att), the exit code, and the elapsed time.

## Examples

### Compare `-O3` against `-O0` on a hot C function

You suspect the compiler isn't vectorizing the inner loop of a hot
function. Put the cursor anywhere inside the function and run `:Asm`.
The window opens at the configured default (`-O2`); hit `-` twice to
step down to `-O0`, note the stack traffic and the lack of SIMD, then
hit `+` three times to land on `-O3` and watch the same function fold
into a handful of `vmovaps` / `vfmadd231ps` lines.

```
:Asm
---  (then press -- then +++)
```

### View a Go snippet's gc assembly

Visually select a short function body in a `.go` file and run `:'<,'>Asm`.
asmview synthesizes a `package main`, compiles with `go build -gcflags=-S`,
and captures the gc assembly from stderr. The two-state `-O` toggle lets
you flip between `-S -N -l` (no optimization, no inlining — honest IR)
and plain `-S` (default optimizer) with `-` and `+`.

```
V3j:'<,'>Asm
```

### Honor the project's `compile_commands.json`

In a CMake or Bear-wrapped C/C++ project, generate the compilation
database once (`cmake -DCMAKE_EXPORT_COMPILE_COMMANDS=ON …` or `bear --
make`). Open any source file and run `:Asm` — asmview walks up to find
`compile_commands.json`, picks the matching entry, and reuses the real
`-std=`, `-I`, `-D`, and `-W` flags your build uses. What you see in the
asm window is what the build will actually emit.

```
:Asm
```

## Configuration

Every field below is optional. Pass only the ones you want to override — the
defaults are what you'd pick anyway.

```lua
require("asmview").setup({
  compilers = {
    c    = { cmd = "cc",    extra_args = {} },
    cpp  = { cmd = "c++",   extra_args = {} },
    rust = { cmd = "rustc", extra_args = {} },
    go   = { cmd = "go",    extra_args = {} },
  },
  opt_levels = { "0", "1", "2", "3", "s", "z" },
  default_opt = "2",
  syntax = "intel",                   -- "intel" or "att" (C/C++ only)
  demangle = true,                    -- pipe through c++filt / rustfilt when present
  use_compile_commands = true,
  compile_commands_search_depth = 6,  -- parent-dir hops looking for the DB
  -- `float` is accepted for backward compatibility and currently ignored —
  -- the asm view is a vertical split as of 0.3.0. The subtree may be
  -- removed in a future major release.
  float = {
    width_ratio = 0.8,
    height_ratio = 0.8,
    border = "rounded",
  },
  keymaps = {                         -- buffer-local, applied in the asm window only
    increase_opt = "+",
    decrease_opt = "-",
    rerun = "R",
    close = "q",
  },
})
```

### `compile_commands.json`

For C and C++ sources, asmview walks up from the source file (capped at
`compile_commands_search_depth` hops) looking for `compile_commands.json`.
If found, it harvests the matching entry's flags but strips:

- `argv[0]` (the compiler — asmview chooses its own via `compilers.{c,cpp}.cmd`)
- `-c`, `-S` (asmview sets `-S`)
- any `-O…` flag (asmview owns the optimization level)
- `-o <path>` (asmview writes to its own temp)
- the input file (asmview supplies its own)

Everything else — `-std=c++20`, `-I...`, `-D...`, `-Wno-…` — passes through.

asmview also injects `-g1` (C/C++) or `-C debuginfo=1` (Rust) **before**
your harvested flags, so DWARF `.loc` directives are present in the asm
and source→asm highlighting works out of the box. To override — e.g.
disable debug info for a cleaner asm dump — add the overriding flag to
`cfg.compilers.<lang>.extra_args` (gcc/clang/rustc all honor last-flag-wins
for `-g*` / `-C debuginfo=*`):

```lua
require("asmview").setup({
  compilers = { c = { cmd = "cc", extra_args = { "-g0" } } },
})
```

### Go specifics

Go's gc toolchain doesn't expose six optimization dials, so `opt_level`
cycling collapses to a two-state toggle:

| `opt_level`   | `gcflags` sent to `go build`     |
| ------------- | -------------------------------- |
| `"0"`         | `-S -N -l` (no opt, no inline)   |
| anything else | `-S` (default optimizer on)      |

For each compile, asmview writes a self-contained temp module (`go.mod` +
`snippet.go`) that forces `package main`, prepends the buffer's `import`
block, and appends a `func main() {}` stub when the snippet lacks one.
Assembly is captured from the gc compiler's stderr. Third-party imports
resolve the same way `go build` does — via `GOPATH`, module proxy, or
vendor directory.

## Health check

```
:checkhealth asmview
```

Verifies the configured compilers are on `PATH`, reports whether the optional
demanglers are available, and whether treesitter is loaded.

## Architecture

```
asmview.nvim/
├── plugin/asmview.lua       — guard, :Asm command, <Plug> mappings
├── lua/asmview/
│   ├── init.lua             — public facade (setup / show)
│   ├── config.lua           — defaults + validate + setup
│   ├── types.lua            — LuaCATS classes
│   ├── detect.lua           — filetype map, PATH probe, compile_commands lookup
│   ├── range.lua            — treesitter → brace-fallback range resolver
│   ├── compile.lua          — argv build + vim.system invocation + demangle
│   ├── window.lua           — right-side vsplit + buffer-local keymaps
│   ├── mapping.lua          — parse .loc / go-stderr → source→asm line map
│   ├── highlight.lua        — CursorMoved-driven extmark highlights
│   └── health.lua           — :checkhealth asmview
├── doc/asmview.txt          — vimdoc
└── tests/asmview/*_spec.lua — neospec specs, one file per module
```

## Development

```bash
make lint              # stylua --check against lua/ and plugin/
make format            # rewrite with stylua
make test              # neospec run against tests/asmview/*_spec.lua
make test-file FILE=tests/asmview/config_spec.lua
make test-coverage     # emits coverage/lcov.info + console percentage
```

`make test` requires [`neospec`](https://github.com/jedi-knights/neospec) on
`PATH`. Install the latest release binary from
[its Releases page](https://github.com/jedi-knights/neospec/releases).

Every public function takes an optional `deps` table so specs can inject
stubs instead of monkey-patching `vim.*`. New public API must follow the
same pattern — see `CLAUDE.md` for the conventions in effect.

## Changelog

See [`CHANGELOG.md`](CHANGELOG.md) for the per-release summary. The
authoritative per-release notes live on the
[GitHub Releases page](https://github.com/jedi-knights/asmview.nvim/releases).

## Contributing

Pull requests are welcome. The flow this repo uses:

1. Fork and branch from `main` — never commit directly to `main` (the branch
   is ruleset-protected).
2. Use [Angular Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0-angular/)
   (`feat:`, `fix:`, `docs:`, `test:`, `chore:`, `ci:`, …). The release
   workflow uses these to pick the next version.
3. Keep `make lint` and `make test` green. New behavior ships with a failing
   test first (see `rules/tdd.md` in `CLAUDE.md`).
4. Open the PR against `main`; CI runs Lint + Test + Validate.

More extensive contributor guidance lives in [`CLAUDE.md`](CLAUDE.md).

## Credits

- **[AssemblyForNeovim](https://github.com/0xdeadf1sh/AssemblyForNeovim)**
  by [0xdeadf1sh](https://github.com/0xdeadf1sh) — the original idea and
  the `+` / `-` / `R` / `q` window-key convention.
- **[yoda.nvim](https://github.com/jedi-knights/yoda.nvim)** — the CI,
  release, and badge-publishing patterns are mirrored directly from yoda,
  including the `install-neospec` composite action.
- **[neospec](https://github.com/jedi-knights/neospec)** — the test runner
  that boots a pinned Neovim and runs the spec files.

## License

MIT. See [`LICENSE`](LICENSE).
