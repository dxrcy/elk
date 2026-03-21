# LC-Z

Complete [LC-3](https://en.wikipedia.org/wiki/Little_Computer_3) toolchain
(currently incomplete).
Available as a both Zig library and a command-line program.

> This project is *currently* unlicensed, so **do not** use, modify, or
> distribute without my prior express permission.

# Features

- [x] Assembler (includes linting)
- [x] Emulator
- [x] Debugger (see below)
- [ ] Formatter

## Debugger Features

- [x] Step through execution
- [x] Inspect/modify registers and memory
- [x] View current line in assembly source
- [x] Set breakpoints
- [x] Evaluate arbitrary instructions
- [x] Recover from `HALT` and runtime exceptions
- [x] Persistent history across program runs
- [ ] Import label declarations from symbol table

## Optional Extension Features

- [x] Builtin debug traps (compatible with [Lace](https://github.com/rozukke/lace))
- [x] Stack instructions (compatible with [Lace](https://github.com/rozukke/lace))
- [x] Extra-permissive assembly syntax
- [x] Full support for arbitrary user-defined traps
- [x] Support for arbitrary runtime hooks
- [ ] Multiple file support (compatible with [Laser](https://github.com/PaperFanz/laser))
- [ ] Preprocessor macros (compatible with [Leap](https://github.com/twhlynch/leap))
- [ ] Output symbol table and assembly listing

## Quality-of-Life Features

- [x] Descriptive warnings and error messages
- [x] Assembly code style hints

## Other Toolchain Components

- [ ] Language server
- [ ] Tree-sitter parser (syntax highlighting)

## Supported Applications

- [x] [ELCI](https://github.com/rozukke/lace/tree/minecraft) inter-op (see
[`minecraft` branch](https://codeberg.org/dxrcy/lcz/src/branch/minecraft))

