# ELK Usage Guide

> **IMPORTANT: This documentation is incomplete!**
> See [#49](https://codeberg.org/dxrcy/elk/issues/4).

# About LC-3
- What is LC-3
- This is not an LC-3 tutorial

## Syntax Overview
- Instruction mnemonics
- Labels
- Directives / pseudo-operations
- Trap instruction aliases
- Registers
- Integer and string literals
- See also: [LC-3 style guide]

## Runtime Overview
- Memory layout
- General purpose registers
- Special registers
    - Program counter
    - Condition code

## Instruction Set
- ...

## Available Traps
- Standard traps
- Extension traps
- Custom traps

# Why ELK?
- Explain why ELK is best!
    - Compatiblity with other implementations
        - laser, lace, lc3tools
    - ISA and assembly extensions
        - See: [extensions]
    - Debugger
        - See: [debugger]
    - Diagnostics and linting
        - See also: [policies]
        - See also: [style guide]
    - Library/CLI distinction
    - Control over traps and their behaviour
        - See: [custom traps]
    - Runtime hooks, debug files
        - See: [runtime hooks]
        - See: [debug files]
- Who uses ELK?

# ELK Command-Line Interface
- Overview
    - Operations
    - Flags
    - Stdio filepaths (`-`)
- Quick example, including `--help`

## Assemble-and-Emulate
- Default operation, no flag

## Assemble Only
- `--assemble`
- ...
### Exporting debug files
- `--export-symbols`
- `--export-listing`
- ...

## Emulate Only
- `--emulate`
- ...

## Other Operations
### Check assembly file without compiling
- `--check`
- ...
### Clean all output files
- `--clean`
- ...
### Format assembly file
- `--format`
- See issue: [#14]
### Language server
- `--lsp`
- See issue: [#32]
- See also: [inline diagnostics for nvim/vscode]

## Debugger
- `--debug`
- ...
### How to use ELK debugger
- Step through execution
- Inspect/modify registers and memory
- View current line in assembly source
- Set breakpoints
- Evaluate arbitrary instructions
- Recover from HALT and runtime exceptions
- Persistent history across program runs
- Import label declarations from symbol table (see issue: [#12])
### Available commands
- List them here
### Initial commands
- `--commands`
- ...
### Change history filepath
- `--history-file`
- ...
## Example
- ...

## Output filepath
- `--output`
- ...

## Other Flags
### Importing a symbol table
- `--import-symbols`
- ...
### Overriding available trap aliases
- `--trap-aliases`
- ...
### Changing diagnostic strictness
- `--strict`
- `--relaxed`
- ...
### Showing consise diagnostics
- `--quiet`
- ...
### Ignoring lints and enabling extensions

The option `--permit <POLICIES>` (or `-p <POLICIES>`) specifies a set of
"policies" to be "permitted" by ELK.
See [here](#policies) for an explanation of what a "policy" is, and a
description of all available policies.
`--permit` may be used with any operation, and may affect assembly, emulation,
and formatting.

The policy set string `<POLICIES>` is a comma-separated list of policies (of the
form `CATEGORY.POLICY`) or [predefined policy set](#predefined-policy-sets)
names (of the form `+PREDEF`).
These policies and predefined sets may be mixed and matched in any order.

By default, ELK does not enable any policies, thus `--permit ""` is equivalent
to ommitting the `--permit` option.
Additionally, leading, trailing, and duplicate commas are ignored.

**Example:** Enable the [stack ISA extension]:
```sh
elk example.asm -p extension.stack_instructions
```
> By default, ELK will warn (or error if `--strict`) when stack instructions
>(`push`, `pop`, `call`, `rets`) are assembled or emulated.
> By specifying that we "permit" this policy, it silences the error.

**Example:** Opt-out of a handful of lints:
```sh
elk example.asm --permit +laser,smell.unused_label_definitions,smell.explicit_trap_instructions
```
> This permits all of the policies in the predefined set `laser`, as well as
> permitting "unused" label definitions, and the use of the `trap` mnemonic
> with an explicit trap vector.

# ELK Features

## Policies

Policies are a way of telling ELK which features or lints you wish to be
enabled for a certain program.
By default, all policies are set to `.forbid`, meaning they are all disabled.
You may opt-into a policy by setting it to `.permit`:

```zig
var policies: elk.Policies = .none;
policies.extension.stack_instructions = .permit;
```

Policies are used throughout ELK, and for both assembly and emulation.
A breach of policy during the assembly phase will trigger a diagnostic to be
reported, which, depending on the strictness level, will be classified as a
warning or an error.
If a policy is breached during emulation (such as a forbidden ISA extension),
this will trigger a runtime exception (eg. `error.UnsupportedOpcode`).

### Categories

There are 4 policy categories:
- `extension`, for extension features. See [extensions].
- `smell`, for linting of possible "code smells".
- `style`, for general code style. See [ELK style guide].
- `case`, for adherence to the case convention. See [ELK style guide].

The policies in each category are as follows:

- `extension`:
    - `stack_instructions`: Enable [stack instructions] ISA extension.
    - `implicit_origin`: Enable [implicit orig].
    - `implicit_end`: Enable [implicit end].
    - `multiline_strings`: Enable [multiline strings].
    - `more_integer_radixes`: Enable [octal and binary integer literals].
    - `more_integer_forms`: Allow [permissive integer syntax].
    - `label_definition_colons`: Allow [colons after label definitions].
    - `multiple_labels`: Allow [multiple labels for a single address].
    - `character_literals`: Allow [character integer literal].
- `smell`:
    - `pc_offset_literals`: Allow integer literal offsets in place of label references.
    - `explicit_trap_instructions`: Allow `trap` instruction with explicit vector literals.
    - `unknown_trap_vectors`: Allow explicit trap instructions with unknown vector literals.
    - `unused_label_definitions`: Allow label definitions with no references.
- `style`:
    - `undesirable_integer_forms`: Allow integer syntax which goes against style guide.
    - `missing_operand_commas`: Don't require commas between operands.
    - `whitespace_commas`: Treat all comma tokens as whitespace.
    - `line_too_long`: Allow lines longer than 80 characters.
- `case`:
    - `mnemonics`: Allow instruction mnemonics which aren't `lowercase`.
    - `trap_aliases`: Allow trap aliases which aren't `lowercase`.
    - `directives`: Allow directives which aren't `UPPERCASE`.
    - `labels`: Allow labels which aren't `PascalCase_WithUnderscores`.
    - `registers`: Allow registers with capital `R`.
    - `integers`: Allow integers with uppercase radix (`0X1F`) or lowercase digits (`0x1f`).

### Predefined policy sets

Predefined policy sets are used as a shorthand for stating each member of the
set. These sets are typically used for compatibility with other toolchains.

- `laser`: Compatiblity with [Lace](https://github.com/rozukke/lace), including
    all extensions.
    - `extension.stack_instructions`
    - `extension.implicit_origin`
    - `extension.implicit_end`
    - `extension.label_definition_colons`
    - `style.missing_operand_commas`
    - `style.whitespace_commas`
- `lace`: Compatiblity with [Laser](https://github.com/PaperFanz/laser).
    - `style.undesirable_integer_forms`

## Custom Traps
- How to define custom traps
- Example: [ELCI integration]
- See also: [trap aliases]
- See also: [extension traps]

## Runtime Hooks
- How to define runtime hooks

# ELK Extensions to LC-3

- ...
- See also: [policies]
- See also: [extension traps]
- See also: [custom traps]
- See also: [runtime hooks]

## Stack Instructions
- ...
## Permissive Syntax
- ...
### Implicit `.ORIG` / `.END`
- ...
### Multi-line strings
- ...
### Permissive integer syntax
- ...
### Post-label colons
- ...
## Octal and Binary Integer Literals
- ...
## Character Integer Literals
- ...
## Multiple labels for one address
- ...

# ELK Style Guide

- See issue: [#14]

- Whitespace
    - Indentation
    - Between tokens
    - Trailing whitespace
    - Consecutive empty lines
- Label position
    - For instructions
    - For directives
- Comment alignment
- Commas
    - Between operands
    - Other positions
- Colons after labels
- Case convention
    - Mnemonics
    - Directives
    - Registers
- Integer literal form
    - Decimal
    - Non-decimal

# Installation

> The instructions in this section are for POSIX sytems (Linux, MacOS, BSD,
> etc).
> ELK currently does not support Windows (see
> [#20](https://codeberg.org/dxrcy/elk/issues/20)), but will work on Windows via
> [WSL](https://learn.microsoft.com/en-us/windows/wsl/install) or similar
> compatibility layer.

## Install from offical releases

**1. Download the latest binary release:**
[available via GitHub releases](https://github.com/dxrcy/elk/releases).

**2. Install the downloaded file to your PATH**:

- **a) system-wide:**
```sh
sudo install <filename> /usr/local/bin/elk
```

- **b) OR for current user only:**
```sh
mkdir ~/.local/bin/
sudo install <filename> ~/.local/bin/elk
```

## Install from source

> Requires [Zig 0.16.x](https://ziglang.org/download/#release-0.16.0).

**1. Make sure Zig 0.16.x is installed:**
[available here](https://ziglang.org/download/#release-0.16.0).

**2. Download source code:**
```sh
git clone https://codeberg.org/dxrcy/elk
cd elk
```

**3. Compile with Zig:**
```sh
zig build install -Doptimize=ReleaseSafe
```

**4. Install compiled binary to system path:**
```sh
sudo install zig-out/bin/elk /usr/local/bin/
```

## Install with system package manager

> ELK is currently not available via package managers such as `brew` or `apt`
> (see [#50](https://codeberg.org/dxrcy/elk/issues/50)).
> Contribution is very welcome!

# Editor Integration

## Neovim

Before setting up [syntax highlighting](#syntax-highlighting) or
[diagnostics](#diagnostics), you need to tell Neovim which file extensions to
associate with the `lc3` filetype, which you can do in any file which runs at
startup, eg. `init.lua`.

```lua
-- init.lua, or any file which be ran on startup
vim.filetype.add({
    extension = {
        asm = "lc3",
        lc3 = "lc3",
    },
})
```

The following instructions assume that this filetype association is already
configured.

### Diagnostics

Install the [`elk.nvim`](https://github.com/twhlynch/elk.nvim) Neovim plugin.
You will also need to
[install ELK separately](https://codeberg.org/dxrcy/elk#installation), and
make sure the executable is in your PATH.

The following minimal setup uses [`lazy`](https://lazy.folke.io/), however
`elk.nvim` works with any plugin manager.
If you are using `lazy`, then add the following file to your plugins directory,
or as an entry in your plugins table:

```lua
-- elk.lua
return {
    "twhlynch/elk.nvim",
    opts = {
        -- See https://github.com/twhlynch/elk.nvim for configuration options
    },
}
```

> When a proper [Language Server](https://codeberg.org/dxrcy/elk/issues/32) is
> implemented, this setup will become a lot easier, and the functionality more
> powerful!

### Syntax Highlighting

The following minimal setup uses
[`nvim-treesitter`](https://github.com/nvim-treesitter/nvim-treesitter)
(`main` branch) with [`lazy`](https://lazy.folke.io/), however `tree-sitter-lc3`
works with any tree-sitter implementation and plugin manager.

1. If you are already using `nvim-treesitter` on its `main` branch, then edit
    your `nvim-treesitter` plugin configuration to add the `lc3` parser, as
    shown below (using `lazy` as an example).
2. If you are using `nvim-treesitter` on its older `master` branch, then either
   update the plugin to `main`, or follow the
   [older installation instructions](https://github.com/nvim-treesitter/nvim-treesitter/tree/master#adding-parsers)
3. If you are not using `nvim-treesitter`, then you will need to install the
    parser manually for `vim.treesitter` to use, which is out of scope for this
    guide.

```lua
return {
    "nvim-treesitter/nvim-treesitter",
    branch = "main",
    build = ":TSUpdate",

    config = function()
        vim.api.nvim_create_autocmd("User", {
            pattern = "TSUpdate",
            callback = function()
                -- Custom parsers go here
                parsers.lc3 = {
                    install_info = {
                        -- nvim-treesitter only supports GitHub links :'(
                        url = "https://github.com/dxrcy/tree-sitter-lc3",
                        branch = "master",
                    },
                }
            end,
        })

        require("nvim-treesitter").install({
            -- List of parsers to install goes here
            -- "zig",
            "lc3",
        })

        vim.api.nvim_create_autocmd("FileType", {
            desc = "Enable treesitter in supported buffers",
            callback = function()
                pcall(vim.treesitter.start)
            end,
        })
    end

}
```

> `tree-sitter-elk` relies on the case convention detailed in the in
> [ELK style guide] to show ambiguity-free syntax highlighting.
> However, any basic assembly parser will provide reasonable highlighting for
> LC-3, including
> [tree-sitter-asm](https://github.com/RubixDev/tree-sitter-asm) provided with
> `nvim-treesitter`.
> This option may be preferable for a simpler setup or if you are following a
> different case convention.

## Vscode

### Diagnostics

Install the [ELK Diagnostics](https://github.com/twhlynch/lc3-elk-diagnostics)
VSCode Extension.
This will automatically install the
[latest version of ELK](https://github.com/dxrcy/elk/releases) from GitHub if
a suitable `elk` executable is not found.

### Syntax Highlighting

> Currently, there is no official ELK syntax highlighting support for VSCode,
> however there are plenty of generic LC-3 extensions with syntax highlighting.

