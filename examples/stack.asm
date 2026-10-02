.ORIG x3000

    ; Initialize the stack pointer
    lea r6, StackTop

    ; Initialize R0 and R1
    and r0, r0, #0
    add r0, r0, #2

    and r1, r1, #0
    add r1, r1, #3

    reg

    ; Push R0
    add r6, r6, #-1
    str r0, r6, #0

    ; Push R1
    add r6, r6, #-1
    str r1, r6, #0

    ; Modify Values
    add r0, r0, r1
    add r1, r1, r0
    reg

    ; Pop R1
    ldr r1, r6, #0
    add r6, r6, #1

    ; Pop R2
    ldr r0, r6, #0
    add r6, r6, #1

    reg

    halt

_Stack    .BLKW #32
StackTop

.END
