# ELK Style Guide

> **IMPORTANT: This style guide is incomplete!**

TODO:
- Integer literal form
    - Add zero before non-decimal radix symbol
    - Move sign character to before non-decimal radix symbol
    - Move sign character to after decimal radix symbol
- Alignment
    - Post-label directive
    - Directive argument
- Trap literal

## Terminology

- *Trailing comment*: A comment which follows a parsable token on the same line.

## Whitespace

A line, comment, directive, or directive argument may be indented, and these
indentations are considered independantly.

All indentation must be done using space characters (`0x20`).
Linebreaks must be done using line feed characters (`0x0a`).
No tabs (`0x09`), carriage returns (`0x0d`), or other control characters may be
used.

No line may end with a space character.

Linebreak characters may not be used consecutively, i.e. there must be no
multiple consecutive empty lines.


**No:**
```
    puts


    puts
```

Space characters may not be used consecutively, except for indentation of the
first token of a line or indentation of a trailing comment, or for the sake of
aligning post-label directives or directive arguments.

**Yes:**
```
    puts    ; comment

Foo     .FILL    #1
BarBar  .STRINGZ "Hi"
```
**No:**
```
    lea  r0,  Hw

Foo     .FILL    #1
Bar     .FILL    #2
```

All indentation must place the indented token on a column which is a multiple of
4, unless the indentation is only 1 space.

**Yes:**
```
    puts    ; comment

Fo .FILL #1

Fo  .FILL   #1
```
**No:**
```
     puts  ; comment

Fo   .FILL   #1
```

A line beginning with an instruction must be indented exactly 4 spaces.

**Yes:**
```
    puts
```
**No:**
```
puts
        puts
```

A line beginning with a label must be uninindented.

**Yes:**
```
Foo .FILL #1
Bar
    .FILL #2
```
**No:**
```
    Foo .FILL #1
    Bar
    .FILL #2
```

A line beginning with a directive must be unindented if no label preceeds it, or
indented exactly 4 spaces if one does.

**Yes:**
```
Foo
    .FILL #1
Bar
    .FILL #2
```
**No:**
```
Foo
.FILL #1
Bar
        .FILL #2
```

A line beginning with a comment, before a non-empty line, must be either
indented the same amount as the line following it, or such that it is aligned
with the comment of the following line.

**Yes:**
```
    ; comment
    puts ; comment

         ; comment
    puts ; comment
```
**No:**
```
; comment
    puts ; comment

        ; comment
    puts ; comment
```

A line beginning with a comment, before an empty line and after a non-empty
line, must be either indented the same amount as the line preceeding it, or such
that it is aligned with the comment of the preceeding line.

**Yes:**
```
    puts ; comment
    ; comment

    puts ; comment
         ; comment
```
**No:**
```
    puts ; comment
; comment

    puts ; comment
        ; comment
```

A line beginning with a comment, neither preceeding nor following a non-empty
line, must be either unindented or indented with exactly 4 spaces.

**Yes:**
```
; comment

    ; comment
```
**No:**
```
  ; comment

        ; comment
```

A trailing comment, before a line with a trailing comment, must be indented the
same as the trailing comment on the following line.

**Yes:**
```
    puts       ; comment
    lea r0, Hw ; comment

    puts            ; comment
    lea r0, Hw      ; comment
```
**No:**
```
    puts ; comment
    lea r0, Hw ; comment

    puts        ; comment
    lea r0, Hw      ; comment
```

A trailing comment, before a line without a trailing comment and after a line
with a trailing comment, must be indented the same as the trailing comment on
the preceeding line.

**Yes:**
```
    lea r0, Hw ; comment
    puts       ; comment

    lea r0, Hw      ; comment
    puts            ; comment
```
**No:**
```
    lea r0, Hw ; comment
    puts ; comment

    lea r0, Hw      ; comment
    puts        ; comment
```

A non-empty comment must have exactly 1 space following the semicolon `;`
character.

**Yes:**
```
    ; comment
    ; comment
```
**No:**
```
    ;comment
    ;  comment
```

A comment must not be empty, unless preceeding or following a line with a
comment of the same indentation, which either is non-empty or it itself follows
this rule. i.e. a non-empty comment must have an unbroken line of comments of
the same indentation, with at least one being non-empty. i.e. a block of aligned
comments must have at least one being non-empty.

**Yes:**
```
    puts       ;
    lea r0, Hw ; comment

    puts       ; comment
    puts       ;
    puts       ;
    lea r0, Hw ;
```
**No:**
```
    puts ;
    lea r0, Hw ; comment

    puts       ; comment
    puts
    puts       ;
    lea r0, Hw ;
```

No whitespace may be used before a comma `,` or colon `:` character, or after a
period `.` character.

**Yes:**
```
    lea r0, Hw
Foo: .FILL #1
```
**No:**
```
    lea r0 , Hw
Foo : . FILL #1
```

## Label Definitions

A label definition preceeding an instruction must be on the line directly above
that instruction.

**Yes:**
```
Foo
    puts
Bar
    puts
```
**No:**
```
Foo

    puts
Bar puts
```

A label definition preceeding a directive must be either on the same line as
that directive, or on the line directly above it.

**Yes:**
```
Foo .FILL #1
Bar
    .FILL #2
```
**No:**
```
Foo .FILL #1
Bar

    .FILL #2
```

## Commas and colons

Operands must be separated by commas.

**Yes:**
```
    ldr r0, r1, #1
```
**No:**
```
    ldr r0 r1 #1
```

Commas must not be used, except between operands.

**Yes:**
```
    ldr r0, r1, #1
Foo .FILL #1
```
**No:**
```
    ,ldr, r0 r1 #1,
Foo, .FILL, #1,
```

Colons must not be used.

**Yes:**
```
Foo .FILL #1
Bar
    puts
```
**No:**
```
Foo: .FILL #1
Bar:
    puts
```

## Case Convention

Instruction mnemonics must be lowercase.

**Yes:**
```
    lea r0, Hw
    add r0, r0, #1
```
**No:**
```
    LEA r0, Hw
    Add r0, r0, #1
```

Trap aliases must be lowercase.

**Yes:**
```
    puts
    getc
```
**No:**
```
    PUTS
    Getc
```

Directives must be uppercase.

**Yes:**
```
.FILL #1
.STRINGZ "Hi"
```
**No:**
```
.fill #1
.Stringz "Hi"
```

Labels *should* be PascalCase_WithUnderscores.

> This is a breaking change if the exported symbol table being used.

**Yes:**
```
FooBar .FILL #1
Loop_End
    puts
```
**No:**
```
FOO_BAR .FILL #1
loopend
    puts
```

Registers must be lowercase.

**Yes:**
```
    lea r0, Hw
```
**No:**
```
    lea R0, Hw
```

Integer prefixes must be lowercase.

**Yes:**
```
.FILL 0x14
.FILL b101
```
**No:**
```
.FILL 0X14
.FILL B101
```

Integer digits must be uppercase.

**Yes:**
```
.FILL 0xDEAD
.FILL 0x7F
```
**No:**
```
.FILL 0xDeaD
.FILL 0x7f
```

## Integer Literals

Decimal integer literals must be prefixed with `#`.

**Yes:**
```
.FILL #1
```
**No:**
```
.FILL 1
```

---

> Want to contribute? Check out the
> [open issues](https://codeberg.org/dxrcy/elk/issues), or share your own ideas!
> 😀
