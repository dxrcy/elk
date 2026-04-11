.ORIG 0x3000

    lea r0, InputPrompt
    puts
    getc

    ld r1, NegAsciiZero
    add r1, r0, r1

    and r0, r0, #0
    add r3, r3, #1

FibLoop
    add r4, r0, r3
    add r3, r0, #0
    add r0, r4, #0

    add r1, r1, #-1
    brp FibLoop

    putn

    halt

InputPrompt     .STRINGZ "Input a number 1-9: "
NegAsciiZero    .FILL -0x30

.END
