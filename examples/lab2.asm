.ORIG 0x3000

    ; r0    X
    ; r1    Y
    ; r2    Address of result values (without offset)
    ; r3    Temporary value of each result
    ; r4    Value of ~r0
    ; r5    Value of ~r1
    ; r6    Value of abs(r0)
    ; r7    Value of abs(r1) (later becomes -abs(r1))

    ; Load the input values
    ld r0, AddrX        ; Load into r0 the value at 0x3100
    ldr r0, r0, #0      ; Load into r0 the value at 0x3100
    ldi r1, AddrY       ; Load into r1 the value at 0x3101

    ld r2, AddrResults  ; Set r2 to the address of the results (x3102)

    ; Calculate (-r0) and (-r1)
    not r4, r0
    add r4, r4, #1
    not r5, r1
    add r5, r5, #1

    ; Calculate abs(r0)
    add r6, r0, #0      ; r6 = r0 (set CC)
    brzp AbsXEnd        ; if ( !(r6 >= 0) ) {   ; If negative
    add r6, r4, #0      ;     r6 = r4 (= -r0)
AbsXEnd                 ; }

    ; Calculate abs(r1)
    add r7, r1, #0      ; r7 = r1 (set CC)
    brzp AbsYEnd        ; if ( !(r7 >= 0) ) {   ; If negative
    add r7, r5, #0      ;     r7 = r5 (= -r1)
AbsYEnd                 ; }

    ; Store the result of (r0 - r1) at 0x3122 (x3122 + 0)
    add r3, r0, r5      ; r3 = r0 + r5 (= r0 - r2)
    str r3, r2, #0      ; memory[r2 + 0] = r3

    ; Store the result of abs(r0) at 0x3123 (x3122 + 1)
    str r6, r2, #1      ; memory[r2 + 1] = r6
    ; Store the result of abs(r1) at 0x3124 (x3122 + 2)
    str r7, r2, #2      ; memory[r2 + 2] = r7

    ; Store a number at 0x3125 (x3122 + 3)
    ;     0: if abs(r0) == abs(r1)
    ;     1: if abs(r0) > abs(r1)
    ;     2: if abs(r0) < abs(r1)

    ; Flip r7 to use in subtraction
    not r7, r7          ; r7 = -r7
    add r7, r7, #1

    and r3, r3, #0      ; r3 = 0                ; Default if abs(r0)==abs(r1)
    add r6, r6, r7      ; r6 = r6 + r7          ; = abs(r0) - abs(r1)
    brz MaxEnd          ; if ( r6 != 0 ) {      ; abs(r0) == abs(r1)
    add r3, r3, #1      ;     r3 = 1
    add r6, r6, #0      ;                       ; Update CC
    brzp MaxEnd         ;     if (r6 < 0)       ; abs(r1) is larger
    add r3, r3, #1      ;         r3 = 2
MaxEnd                  ; }

    str r3, r2, #3      ; memory[r2 + 3] = r3

    halt

AddrX       .FILL 0x3120     ; X is stored at 0x3120
AddrY       .FILL 0x3121     ; Y is stored at 0x3121
AddrResults .FILL 0x3122     ; The result values start at address 0x3102

.END
