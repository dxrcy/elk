.ORIG 0x3000

    ; for (r1 = R; r1+R > 0; --r1)
    ld r1, Radius
Grid_Outer

    ; for (r2 = R; r2+R > 0; --r2)
    ld r2, Radius
Grid_Inner

    jsr InCircle            ; if (InCircle(r1, r2))
    add r0, r0, #0          ;
    brzp PickChar_Else      ;
    ld r0, CharSet          ;     r0 = CharSet
    br PickChar_End         ;
PickChar_Else               ; else
    ld r0, CharUnset        ;     r0 = CharUnset
PickChar_End

    out                     ; print(r0, r0)
    out

    add r2, r2, #-1         ; --r2
    ld r6, Radius           ; CC = R + r2
    add r6, r6, r2
    brzp Grid_Inner

    ld r0, CharLf           ; print('\n')
    out

    add r1, r1, #-1         ; --r1
    ld r6, Radius           ; CC = R + r1
    add r6, r6, r1
    brzp Grid_Outer

    halt

; @input  r1 y
; @input  r2 x
; @output r0 non-zero iff (x,y) is in circle
InCircle_R1 .FILL 0x0
InCircle_R2 .FILL 0x0
InCircle_R3 .FILL 0x0
InCircle_R7 .FILL 0x0
InCircle
    st r1, InCircle_R1
    st r2, InCircle_R2
    st r3, InCircle_R3
    st r7, InCircle_R7

    ; r3 = x^2 + y^2
    add r0, r1, #0          ; r3 = x^2
    jsr Square
    add r3, r0, #0
    add r0, r2, #0          ; r3 += y^2
    jsr Square
    add r3, r3, r0

    ; r0 = (x^2 + y^2) - R^2
    ld r0, Radius           ; r0 = R^2
    jsr Square
    not r0, r0              ; r0 = -r0
    add r0, r0, #1
    add r0, r3, r0          ; r0 = r3 - R^2

    ld r1, InCircle_R1
    ld r2, InCircle_R2
    ld r3, InCircle_R3
    ld r7, InCircle_R7
    ret

; @input  r0 x
; @output r0 x^2
Square_R1 .FILL 0x0
Square_R2 .FILL 0x0
Square_R7 .FILL 0x0
Square
    st r1, Square_R1
    st r2, Square_R2
    st r7, Square_R7

    ; r1 = |x|
    add r1, r0, #0          ; r1 = x
    brzp Square_Negate_End  ; if (x < 0)
    not r1, r1              ;     x = -x
    add r1, r1, #1
Square_Negate_End

    ; r2 = |x|, r0 = 0
    add r2, r1, #0
    and r0, r0, #0

Square_Loop                 ; while (r2 > 0)
    add r0, r0, r1          ;     r0 += |x|
    add r2, r2, #-1
    brp Square_Loop

    ld r1, Square_R1
    ld r2, Square_R2
    ld r7, Square_R7
    ret

Radius      .FILL #20
CharLf      .FILL 0x0a      ; '\n'
CharSet     .FILL 0x23      ; '#'
CharUnset   .FILL 0x2e      ; '.'

.END
