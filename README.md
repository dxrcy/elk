# ELK

ELK is a complete
[LC-3](https://en.wikipedia.org/wiki/Little_Computer_3) toolchain
available both as a CLI program and a [Zig](https://ziglang.org)
library.
ELK /ɛlk/ strives to be the most compatible and featureful implementation
available.

[Official Codeberg repository](https://codeberg.org/dxrcy/elk)
| [Documentation](https://codeberg.org/dxrcy/elk/src/branch/master/DOCS.md)
| [Releases](https://github.com/dxrcy/elk/releases)
| [GitHub mirror](https://github.com/dxrcy/elk)

<div align="center">

![ELK Logo](images/elk.svg)

</div>

# Usage

> For more detailed documentation, see the [**ELK Usage Guide**](DOCS.md).

```sh
# Show all options
elk --help

# Assemble and emulate
elk hello.asm

# Assemble and debug
elk hello.asm --debug

# Assemble to object file
elk hello.asm --assemble [--output hello.obj]

# Emulate object file
elk hello.obj --emulate
```

## Quick Installation

> For more detailed installation instructions, see the
[**ELK Usage Guide**](DOCS.md#installation).

1. Download the latest binary release from
[GitHub releases](https://github.com/dxrcy/elk/releases).
2. Install the downloaded file to your PATH:

```sh
sudo install <filename> /usr/local/bin/elk
```

# Learn More

- [Why ELK?](DOCS.md#why-elk)
- [About LC-3](DOCS.md#about-lc3)
- Setup
    - [Installation](DOCS.md#installation)
    - [Editor Integration](DOCS.md#editor-integration)
- Reference
    - [ELK Command-Line Interface](DOCS.md#elk-command-line-interface)
    - [ELK Library Features](DOCS.md#elk-library-features)
    - [ELK Extensions to LC-3](DOCS.md#elk-extensions-to-lc-3)
- Style guide
    - [ELK Style Guide](STYLE.md)

# Contributors

> Want to contribute? Check out the
> [open issues](https://codeberg.org/dxrcy/elk/issues), or share your own ideas!
> 😀

<!-- Codeberg has no equivalent -->
<a href="https://github.com/dxrcy/elk/graphs/contributors">
    <img src="https://contrib.rocks/image?repo=dxrcy/elk" />
</a>

- Thanks to [@twhlynch](https://github.com/twhlynch) for providing editor
  integration for Neovim and VSCode!

# Usage Examples

> *Inspecting a running program with the ELK debugger*
![Example debugger usage](images/example2.svg)

> *Some useful diagnostics whilst compiling a faulty assembly program*
![Example assembler usage](images/example1.svg)

