.ORIG 0x3000

    lea r1, Words       ; base = &Words
    and r2, r2, #0      ; i = 0

Loop_Start              ; while (true) {
    add r6, r1, r2      ;     if (*(base + i) == NUL)
    ldr r6, r6, 0x0     ;
    brz Loop_End        ;         break

    add r6, r2, #0      ;     if (i > 0)
    brnz Delim_End      ;
    lea r0, Delim       ;         print(Delim)
    puts                ;
    Delim_End           ;

    add r0, r1, r2      ; print(base + i)
    puts                ;

    ld r0, Size         ; r2 += Size
    add r2, r2, r0      ;

    br Loop_Start       ; }
Loop_End

    halt

Delim .STRINGZ ", "
Size .FILL #10
Words  ; Each [word + null block] takes up Size WORDS
    .STRINGZ "Monday"
    .BLKW #3
    .STRINGZ "Tuesday"
    .BLKW #2
    .STRINGZ "Wednesday"
    .BLKW #0
    .STRINGZ "Thursday"
    .BLKW #1
    .STRINGZ "Friday"
    .BLKW #3
    .STRINGZ "Saturday"
    .BLKW #1
    .STRINGZ "Sunday"
    .BLKW #3
    .FILL 0x0000 ; Equivalent to an empty null-terminated string

.END
