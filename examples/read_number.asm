.ORIG 0x3000

    lea r0, InputPrompt
    puts

    jsr ReadUint

    ld r0, AsciiLf
    out
    lea r0, OutputPrompt
    puts
    add r0, r1, #0
    putn

    halt


; @output r1 result
ReadUint_R0 .FILL 0x0
ReadUint_R2 .FILL 0x0
ReadUint_R7 .FILL 0x0
ReadUint
    st r0, ReadUint_R0
    st r2, ReadUint_R2
    st r7, ReadUint_R7

    and r1, r1, #0 ; result = 0

ReadUint_Loop               ; while (true) {
    getc

    ; if (r0 == '\n') break
    ld r2, AsciiLf
    not r2, r2
    add r2, r2, #1
    add r2, r0, r2
    brz ReadUint_Done

    ; r0 -= '0'
    ; if (r0 < 0) continue
    ld r2, AsciiZero
    not r2, r2
    add r2, r2, #1
    add r0, r0, r2
    brn ReadUint_Loop
    ; if (r0 > 9) continue
    add r2, r0, #-10
    brzp ReadUint_Loop

    ; result = (result * 10) + r0
    jsr Mul10
    add r1, r1, r0

    ; Echo digit read
    ld r2, AsciiZero
    add r0, r0, r2
    out

    br ReadUint_Loop        ; }
ReadUint_Done

    ld r0, ReadUint_R0
    ld r2, ReadUint_R2
    ld r7, ReadUint_R7
    ret


; @input  r1 x
; @output r1 10*x
Mul10_R2 .FILL 0x0
Mul10
    st r2, Mul10_R2

    add r2, r1, #0          ; i = x
    and r1, r1, #0          ; x' = 0
Mul10_Loop                  ; while (
    add r2, r2, #-1         ;     --i,
    brn Mul10_Done          ;     i >= 0
                            ; ) {
    add r1, r1, #10         ;     x' += 10
    br Mul10_Loop           ; }
Mul10_Done

    ld r2, Mul10_R2
    ret


OutputPrompt    .STRINGZ "Your number is: "
InputPrompt     .STRINGZ "Input a positive number: "
AsciiLf         .FILL  0x0a
AsciiZero       .FILL  0x30

.END
