# ELK Usage Guide

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
- `--permit`
- ...
- See: [policies]

# ELK Features

## Policies
- What are policies
- See also: [extensions]
- See also: [style guide]

### Categories

- `extensions` - Extension features:
    - `stack_instructions`: Enable [stack instructions] ISA extension.
    - `implicit_origin`: Enable [implicit orig].
    - `implicit_end`: Enable [implicit end].
    - `multiline_strings`: Enable [multiline strings].
    - `more_integer_radixes`: Enable [octal and binary integer literals].
    - `more_integer_forms`: Allow [permissive integer syntax].
    - `label_definition_colons`: Allow [colons after label definitions].
    - `multiple_labels`: Allow [multiple labels for a single address].
    - `character_literals`: Allow [character integer literal].

- `smell` - Code linting:
    - `pc_offset_literals`: Allow integer literal offsets in place of label references.
    - `explicit_trap_instructions`: Allow `trap` instruction with explicit vector literals.
    - `unknown_trap_vectors`: Allow explicit trap instructions with unknown vector literals.
    - `unused_label_definitions`: Allow label definitions with no references.

- `style` - General code style:
    - `undesirable_integer_forms`: Allow integer syntax which goes against style guide.
    - `missing_operand_commas`: Don't require commas between operands.
    - `whitespace_commas`: Treat all comma tokens as whitespace.
    - `line_too_long`: Allow lines longer than 80 characters.

- `case` - Case convention:
    - `mnemonics`: Allow instruction mnemonics which aren't `lowercase`.
    - `trap_aliases`: Allow trap aliases which aren't `lowercase`.
    - `directives`: Allow directives which aren't `UPPERCASE`.
    - `labels`: Allow labels which aren't `PascalCase_WithUnderscores`.
    - `registers`: Allow registers with capital `R`.
    - `integers`: Allow integers with uppercase radix (`0X1F`) or lowercase digits (`0x1f`).

### Predefined policy sets
- ...
- `laser`
- `lace`

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

# Editor Integration

## Neovim

Before setting up [syntax highlighting] or [diagnostics], you need to tell
Neovim which file extensions to associate with the `lc3` filetype, which you
can do in any file which runs at startup, eg.
`init.lua`.

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
make sure the executable is in your `PATH`.

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

