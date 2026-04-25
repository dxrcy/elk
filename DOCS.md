# ELK Usage Guide

[Official Codeberg repository](https://codeberg.org/dxrcy/elk)
| [Documentation](https://codeberg.org/dxrcy/elk/src/branch/master/DOCS.md)
| [Releases](https://github.com/dxrcy/elk/releases)
| [GitHub mirror](https://github.com/dxrcy/elk)

> **IMPORTANT: This documentation is incomplete!**
> See [#49](https://codeberg.org/dxrcy/elk/issues/49).
> The following table-of-contents shows the sections which are complete in blue.

- [Why ELK?](#why-elk)
- [About LC-3](#about-lc-3)
    - [Assembly Overview](#assembly-overview])
    - [Runtime Overview](#runtime-overview)
    - [Available Traps](#available-traps)
- ELK Command-Line Interface
    -  Assemble-and-Emulate
    -  Assemble Only
        -  Exporting debug files
    -  Emulate Only
        -  Check assembly file without compiling
        -  Clean all output files
        -  Format assembly file
        -  Language server
    -  Debugger
        -  How to use ELK debugger
        -  Available commands
        -  Initial commands
        -  Change history filepath
    -  Example
    -  Output filepath
    -  Other Flags
    - Other Flags
        -  Importing a symbol table
        - [Overriding available trap aliases](#overriding-available-trap-aliases)
        -  Changing diagnostic strictness
        -  Showing consise diagnostics
        - [Ignoring lints and enabling extensions](#ignoring-lints-and-enabling-extensions)
- ELK Library Features
    - [Policies](#policies)
        - [Categories](#categories)
        - [Predefined policy sets](#predefined-policy-sets)
    -  Custom Traps
    -  Runtime Hooks
- ELK Extensions to LC-3
    -  Stack Instructions
    -  Permissive Syntax
        -  Implicit `.ORIG` / `.END`
        -  Multi-line strings
        -  Permissive integer syntax
        -  Post-label colons
    -  Octal and binary integer literals
    -  Character integer literals
    -  Multiple labels for one address
- ELK Style Guide
- [Installation](#installation)
    - [Install from official releases](#install-from-official-releases)
    - [Install from source](#install-from-source)
    - [Install with system package manager](#install-with-system-package-manager)
- [Editor Integration](#editor-integration)
    - [Neovim](#neovim)
        - [Diagnostics](#diagnostics)
        - [Syntax Highlighting](#syntax-highlighting)
    - [VSCode](#vscode)
        - [Diagnostics](#diagnostics-1)
        - [Syntax Highlighting](#syntax-highlighting-1)

# Why ELK?

ELK focuses on feature richness and frictionless usage, without sacrificing
compatibility.
It achieves this in two ways: by isolating the two project components (library
and command-line interface), and giving users control over everything from
custom traps to extension features.
Besides this, ELK's offers the most functional LC-3 command-line debugger that
exists, designed with usability in mind.

ELK is used in real-world educational situations, by students learning low-level
concepts.
Thanks to the straightforward interface and informative diagnostics, users can
easily identify and debug their assembly code, without dealing with frustrating
implementation shortcomings.
At the same time, ELK does not limit their exploration of any LC-3 internals.
Because of ELK's modular separation of functionality, anyone can extend the
library with their own traps or hooks, allowing for integration into any domain.

# About LC-3

The [LC-3](https://en.wikipedia.org/wiki/Little_Computer_3)
(*Little Computer 3*) is a simple computer architecture and assembly language
designed for educational use.
It is designed on a simple Von Neumann model with 16-bit words, and no
distinction between code and data.
The 16 instructions available in the ISA cover arithmetic, logic, branching, and
memory access.
Despite its intentional limitations, an LC-3 computer or emulator is a
Turing-complete system capable of complex behaviour.

> Note: This document is not an LC-3 tutorial.
> This section will be written primarily implementation-nonspecific, however
> the terminology used may be specific to ELK.

## Assembly Overview

The LC-3 assembly language is a one-to-one abstraction of an LC-3 program. It
allocates and initialises memory by using *instructions* and *directives*, each
of which can be prepended with a *label definition*.

An instruction consists of two parts: the *mnemonic* and the *operands*.
An instruction mnemonic is a closed set of 16 identifiers, eg. `lea`.
An instruction operand may be one of three tokens: a register, an integer
literal (known as an *immediate* in this context), or a label reference.
Each instruction has a strict expectation of which operands are valid, but may
accept multiple operand forms, eg. `add` accepts either a register or immediate
as its third operand.

A directive (also known as a *psuedo-operation*) is a special type of statement,
prefixed with a period, which informs the assembler to perform certain actions,
such as allocating and initialising memory for arbitrary data (in the case of
`.FILL` and `.STRINGZ`), denoting the address of user memory (`.ORIG`), or
stopping the assembly phase (`.END`).
No text is lexed or parsed after the `.END` directive.
Implementations are free to describe and implement additional directives with
custom semantics.
A directive may have a number of arguments following it, such as a *string
literal* or *integer literal*.

A *trap alias* is an alternative to a `trap` instruction, which aids
readability since it avoids a hardcoded vector operand.
An example is `halt` which is equivalent to `trap 0x25`.
Since a trap's behaviour is implemented in the emulator, the set of trap
aliases is an open set, which the assembler must be aware of to avoid ambiguity
with labels.

A label definition gives a name to a memory location allocated with an
instruction statement or directive, which the assembler can use when compiling
instructions with label operands.
The label operand is a reference to the label definition, and is converted into
an offset value of 9, 10, or 11 bits, signifying the signed distance between the
instruction which references the label, and the location which the label
definition names.
A label definition may be immediately followed by a colon, though this is
optional.

A general-purpose register is written with an `r` or `R` followed by a number
`0-7` (inclusive).
It is not possible to name a "special" register (such as the program counter) in
assembly, since these registers are not directly accessible.

An integer literal may be in decimal or hexadecimal (or binary or octal with an
extension enabled).
A decimal integer may be prefixed with a `#` character, but this is optional.
A hexadecimal integer must be prefixed with a `x` or `X`, which itself may be
preceeded by a leading `0`.
These are examples of valid hexadecimal integer literals: `0x1f`, `xbeef`,
`0X0`.
Because of this bespoke syntax, a token beginning with `x` or `X`, which is
intended to be a label, may instead be parsed as a hexadecimal integer; this is
unavoidable and necessary.

> See the [ELK style guide] for more information, and how possible ambiguity
> concerns are addressed.

## Runtime Overview

The LC-3 runtime is simple. The state of the entire computer can be expressed as
a tuple $(M, GP, PC, CC)$, where $M$ is $2^{16}$ words of memory, $GP$ are eight
16-bit general-purpose registers, $PC$ is the program counter register,
signifying the address of the *next instruction to be interpreted*, and $CC$ is
the condition code register, which is one of `negative`, `zero`, or `positive`,
signifying the *sign of the value in the last-modified register*.

Memory is partitioned into segments, with user program memory in the range
`[0x3000, 0xFDFF]`. Access of memory outside of this user program segment is
implementation-specific and thus undefined in this context.
An assembled LC-3 program is loaded into memory at the program's "origin" (the
address specified by `.ORIG`), which is typically `0x3000` (the start of user
memory).
The rest of user memory, as well as all general purpose registers, are
typically initialised to zero.
The program counter ($PC$) is initially set to the program's origin addreess.
The condition code register ($CC$) may be initialised as `zero`, or a sentinel
"undefined" value in some implementations.

The LC-3 machine runs a fetch-decode-execute loop until this flow is broken,
either by a `halt` invokation or a *runtime exception*.
The value at the memory location pointed to by the program counter is loaded,
and the highest 4 bits are decoded as the instruction's *opcode*.
The rest of the instruction is decoded differently depending on the instruction.
The execution of an instruction may read multiple registers or memory
locations, and/or write exactly one register or memory location.
If, and only if, a register was modified, the condition code ($CC$) is set to
the sign of that register's value.
It may also modify the program counter by adding an offset, known as branching
or jumping.
A `trap` instruction decodes its lowest 8 bits as the *trap vector*, which
determines which *trap routine* to run.
A trap routine may perform "privileged" operations, such as halting the program,
invoking input/output operations, or anything else.

## Available Traps

ELK provides full control over trap behaviour, allowing a library user to
override traps or create their own traps with custom routines.
ELK provides several "built-in" traps for convenience, but they are not magic;
the exact same behaviour can be achieved with user-provided traps.
The built-in traps are as follows: 6 "standard" traps, which are expected in all
LC-3 implementations, as well as 2 "extension" traps, which are provided for
debugging use and may be undefined on other implementations.

| Type | Alias | Vector | Name | Description |
|------|-------|--------|------|-------------|
| Standard  | `getc`  | `0x20` | "Get Char"          | Read character from stdin, store in `r0`, **without echoing** |
| Standard  | `out`   | `0x21` | "Output Char"       | Load from `r0`, write to stdout as a character  |
| Standard  | `puts`  | `0x22` | "Put String"        | Load address from `r0`, write each **word** starting from that address to stdout until null terminator (`0x0000`) is reached |
| Standard  | `in`    | `0x23` | "Input Char"        | Read character from stdin, store in `r0`, **echo to stdout** |
| Standard  | `putsp` | `0x24` | "Put String Padded" | Load address from `r0`, write each **byte** starting from that address to stdout until null terminator (`0x00`) is reached |
| Standard  | `halt`  | `0x25` | "Halt"              | Ends program |
| Extension | `putn`  | `0x26` | "Put Number"        | Load from `r0`, write to stdout as an integer |
| Extension | `reg`   | `0x27` | "Registers"         | Write all register values to stdout, in a table form |

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

The option `--trap-aliases <ALIASES>` overrides the set of trap aliases which
are recognised.
This new set of aliases will *replace* the existing set.

An alias set `<ALISES>` is a comma-separated list of trap alias definitions of
the form (`ALIAS=VECTOR`), where `ALIAS` is an identifier and `VECTOR` is the
hexadecimal trap vector prefixed with `0x`.
See [available traps](#available-traps) for a list of built-in trap aliases and
their vectors.

`--trap-aliases` must be used with `--assemble`, `--check`, or `--format`, as
it only affects the parsing/assembling component.
No actual runtime implementation is required for a trap alias to be used in the
assembly stage.

**Example:** Remove all trap aliases
```sh
elk example.asm --assemble --trap-aliases ""
```
> The assembler will not support any trap aliases, regardless of whether they
> were built-in or custom.

**Example:** Check assembly code, with additional trap aliases
```sh
elk example.asm --check --trap-aliases "getc=0x20,out=0x21,puts=0x22,in=0x23,putsp=0x24,halt=0x25,putn=0x26,reg=0x27,explode=0x40"
```
> Since standard and extension trap aliases were specified, they will still
> work.
> Additionally, an identifier `explode` (case-insensitive) will be treated as a
> trap alias, instead of a label as it would otherwise.
> `explode` does not need to have an actual runtime implementation.
>
> This is useful for editor integration when custom trap aliases can be used
> without changing the `elk` executable being used.

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
> (`push`, `pop`, `call`, `rets`) are assembled or emulated.
> By specifying that we "permit" this policy, it silences the error.

**Example:** Opt-out of a handful of lints:
```sh
elk example.asm --permit +laser,smell.unused_label_definitions,smell.explicit_trap_instructions
```
> This permits all of the policies in the predefined set `laser`, as well as
> permitting "unused" label definitions, and the use of the `trap` mnemonic
> with an explicit trap vector.

# ELK Library Features

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
## Octal and binary integer literals
- ...
## Character integer literals
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

## Install from official releases

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

---

> Want to contribute? Check out the
> [open issues](https://codeberg.org/dxrcy/elk/issues), or share your own ideas!
> 😀

