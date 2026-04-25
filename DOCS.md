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
- Tree-sitter parser
- Inline diagnostics for Neovim

## Vscode
- Inline diagnostics for VSCode

