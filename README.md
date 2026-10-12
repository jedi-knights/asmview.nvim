# asmview.nvim

<p>
  <a href="https://github.com/jedi-knights/asmview.nvim/actions/workflows/ci.yml"><img src="https://github.com/jedi-knights/asmview.nvim/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/jedi-knights/asmview.nvim/actions/workflows/badge.yaml"><img src="https://github.com/jedi-knights/asmview.nvim/actions/workflows/badge.yaml/badge.svg" alt="Badge"></a>
  <img src="https://img.shields.io/badge/Tests-87%20passing-brightgreen" alt="Tests">
  <a href="https://jedi-knights.github.io/asmview.nvim/"><img src="https://img.shields.io/badge/Coverage-89%2E5%25-green" alt="Coverage"></a>
</p>

Compile the function under your cursor to assembly and display it in a floating
window, without leaving Neovim. Supports **C**, **C++**, **Rust**, and **Go**.

Equivalent in spirit to [AssemblyForNeovim][upstream] but rewritten with:

- No auto-bound keymaps — exposes `:Asm` and `<Plug>(AsmView)` only
- A validated, LuaCATS-typed configuration
- Bounded loops (no unbounded walks on hostile filesystems)
- Dependency-injectable modules so each piece is unit-testable
- `compile_commands.json` support that strips the input file and the project's
  `-O` so you can cycle optimization levels without the DB fighting you
- `:checkhealth asmview`

[upstream]: https://github.com/0xdeadf1sh/AssemblyForNeovim

## Requirements

- Neovim ≥ 0.10 (uses `vim.system`, `vim.uv`, `vim.health`)
- At least one of: `cc` / `c++` / `rustc` / `go` on `PATH`
- Optional: `c++filt`, `rustfilt` (demangling)
- Optional: a `compile_commands.json` (CMake, Bear, meson) for faithful C/C++ flags

## Installation

Lazy.nvim:

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

Packer:

```lua
use({
  "jedi-knights/asmview.nvim",
  config = function()
    require("asmview").setup()
  end,
})
```

## Usage

| Trigger                | Behavior                                     |
| ---------------------- | -------------------------------------------- |
| `:Asm` (normal mode)   | Compile the function enclosing the cursor    |
| `:'<,'>Asm`            | Compile the visually-selected lines          |
| `<Plug>(AsmView)` in n | Function around the cursor                   |
| `<Plug>(AsmView)` in x | Visual selection                             |

Inside the asm window:

| Key | Action                                     |
| --- | ------------------------------------------ |
| `+` | Step optimization level up (`O0` → `Oz`)   |
| `-` | Step optimization level down               |
| `R` | Rerun the compiler                         |
| `q` | Close the window                           |

The header line in the window shows the range, the current `-O` level, the
syntax (intel/att), the exit code, and the elapsed time.

## Configuration

Every field below is optional. Pass only the ones you want to override.

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

### `compile_commands.json` behavior

For C and C++ sources, asmview walks up from the source file (capped at
`compile_commands_search_depth` hops) looking for `compile_commands.json`.
If found, it harvests the matching entry's flags but strips:

- `argv[0]` (the compiler — asmview chooses its own via `compilers.{c,cpp}.cmd`)
- `-c`, `-S` (asmview sets `-S`)
- any `-O…` flag (asmview owns the optimization level)
- `-o <path>` (asmview writes to its own temp)
- the input file (asmview supplies its own)

Everything else — `-std=c++20`, `-I...`, `-D...`, `-Wno-…` — is passed through.

### Go specifics

Go's gc toolchain doesn't expose six optimization dials, so the opt_level
cycling collapses to a two-state toggle:

| opt_level | `gcflags` sent to `go build` |
| --------- | ---------------------------- |
| `"0"`     | `-S -N -l` (no opt, no inline) |
| anything else | `-S` (default optimizer on) |

For each compile asmview writes a self-contained temp module (`go.mod` +
`snippet.go`) that forces `package main`, prepends the buffer's `import`
block, and appends a `func main() {}` stub when the snippet lacks one.
Assembly is captured from the gc compiler's stderr. Third-party imports
resolve the same way `go build` does — via `GOPATH`, module proxy, or
vendor directory.

## Architecture

```
asmview.nvim/
├── plugin/asmview.lua       — guard, :Asm command, <Plug> mapping (no auto-binds)
├── lua/asmview/
│   ├── init.lua             — public facade (setup/show)
│   ├── config.lua           — defaults + validate + setup
│   ├── types.lua            — LuaCATS classes
│   ├── detect.lua           — filetype map, PATH probe, compile_commands lookup
│   ├── range.lua            — treesitter → brace-fallback range resolver
│   ├── compile.lua          — argv build + vim.system invocation + demangle
│   ├── window.lua           — floating window + buffer-local keymaps
│   └── health.lua           — :checkhealth asmview
└── doc/asmview.txt          — vimdoc
```

## Health check

```
:checkhealth asmview
```

Verifies the configured compilers are on `PATH`, reports whether the optional
demanglers are available, and whether treesitter is loaded.

## License

MIT. See `LICENSE`.
