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
### Exporting debug files
- `--export-symbols`
- `--export-listing`

## Emulate Only
- `--emulate`

## Other Operations
### Check assembly file without compiling
- `--check`
### Clean all output files
- `--clean`
### Format assembly file
- `--format`
- See issue: [#14]
### Language server
- `--lsp`
- See issue: [#32]
- See also: [inline diagnostics for nvim/vscode]

## Debugger
- `--debug`
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
### Change history filepath
- `--history-file`
## Example
- ...

## Output filepath
- `--output`

## Other Flags
### Importing a symbol table
- `--import-symbols`
### Overriding available trap aliases
- `--trap-aliases`
### Changing diagnostic strictness
- `--strict`
- `--relaxed`
### Showing consise diagnostics
- `--quiet`
### Ignoring lints and enabling extensions
- `--permit`
- See: [policies]

# ELK Features

## Policies
- What are policies

### Categories
#### Extension features
- `extensions`
#### Code linting
- `smell`
#### General code style
- `style`
#### Case convention
- `case`

### Predefined policy sets
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

- See also: [policies]
- See also: [extension traps]
- See also: [custom traps]
- See also: [runtime hooks]

## Stack Instructions
## Permissive Syntax
## Character Integer Literals

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

# Other ELK Toolchain Components
- Tree-sitter parser
- Inline diagnostics for VSCode
- Inline diagnostics for Neovim

