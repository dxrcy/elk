.ORIG 0x3000

    lea r0, HW
    add r0, r0, #1
    PUTS ; foo comment

    HALT

HW .STRINGZ "Hello world\n"

.END
