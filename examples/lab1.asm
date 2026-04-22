.ORIG 0x3000

    ; r0    X
    ; r1    Y
    ; r2    Address of result values (without offset)
    ; r3    Temporary value of each result
    ; r4    Value of ~r0
    ; r5    Value of ~r1

    ; Load the input values
    ldi r0, AddrX       ; Load into r0 the value at 0x3100
    ldi r1, AddrY       ; Load into r1 the value at 0x3101

    ld r2, AddrResults  ; Set r2 to the address of the results (x3102)

    ; Calculate (~r0) and (~r1)
    not r4, r0
    not r5, r1

    ; Store the result of (r0 + r1) at 0x3102 (x3102 + 0)
    add r3, r0, r1      ; r3 = r0 + r1
    str r3, r2, #0      ; memory[r2 + 0] = r3

    ; Store the result of (r0 & r1) at 0x3103 (x3102 + 1)
    and r3, r0, r1      ; r3 = r0 & r1
    str r3, r2, #1      ; memory[r2 + 1] = r3

    ; Store the result of (r0 | r1) at 0x3104 (x3102 + 2)
    and r3, r4, r5      ; OR using De Morgan's law
    not r3, r3          ; r3 = ~(~r0 & ~r1)
    str r3, r2, #2      ; memory[r2 + 2] = r3

    ; Store the result of (~r0) at 0x3105 (x3102 + 3)
    str r4, r2, #3      ; memory[r2 + 3] = r4

    ; Store the result of (~r1) at 0x3106 (x3102 + 4)
    str r5, r2, #4      ; memory[r2 + 4] = r5

    ; Store the result of (r0 + 3) at 0x3107 (x3102 + 5)
    add r3, r0, #3      ; r3 = r0 + 3
    str r3, r2, #5      ; memory[r2 + 5] = r3

    ; Store the result of (r0 - 3) at 0x3108 (x3102 + 6)
    add r3, r1, #-3     ; r3 = r1 - 3
    str r3, r2, #6      ; memory[r2 + 6] = r3

    ; Store the result of (r0 % 2) aka. (r0 & 1) at 0x3109 (x3102 + 7)
    and r3, r0, #1      ; r3 = r0 & 1
    str r3, r2, #7      ; memory[r2 + 7] = r3

    halt

AddrX       .FILL 0x3100     ; X is stored at 0x3100
AddrY       .FILL 0x3101     ; Y is stored at 0x3101
AddrResults .FILL 0x3102     ; The result values start at address 0x3102

.END
