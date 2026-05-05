.ORIG x3000

    ld r1, Height
Rows

    ld r2, Width
Columns

    add r3, r1, r2
    and r3, r3, x1
    brnp CharElse

    lea r0, Solid
    puts
    br CharEnd

CharElse
    lea r0, Empty
    puts

CharEnd

    add r2, r2, #-1
    brp Columns

    ld r0, Newline
    out

    add r1, r1, #-1
    brp Rows

    halt

Newline .FILL x0A ; '\n'

Width   .FILL #20
Height  .FILL #20

Solid   .STRINGZ "[]"
Empty   .STRINGZ "  "

.END
