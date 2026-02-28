# LC-Z

Complete [LC-3](https://en.wikipedia.org/wiki/Little_Computer_3) toolchain.

> This project is *currently* unlicensed, so **do not** use, modify, or
> distribute without my prior express permission.

# Features

- [x] Assembler
- [x] Emulator
- [ ] Debugger
- [ ] Formatter
- [ ] and more coming...

## Optional Extension Features

- [x] Debug traps (compatible with [Lace](https://github.com/rozukke/lace))
- [x] Stack instructions (compatible with [Lace](https://github.com/rozukke/lace))
- [x] Extra-permissive assembly syntax
- [x] Custom user-supplied trap procedures
- [ ] Preprocessor metaprogramming

# Usage

Compile and run:

```sh
zig build run
```

Compile and install:

```sh
zig build
sudo install ./zig-out/bin/lcz /usr/bin/
```

