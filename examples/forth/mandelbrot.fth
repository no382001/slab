variable CR0  variable CI0
variable ZR   variable ZI
variable I    variable TMP

4 constant CSTEP
6 constant RSTEP

: fx * 64 / ;

: mandel
  -80 begin dup 80 < while
    dup CI0 !
    -160 begin dup 96 < while
      dup CR0 !
      0 ZR ! 0 ZI ! 0 I !
      begin
        ZR @ ZR @ fx ZI @ ZI @ fx - CR0 @ + TMP !
        ZR @ ZI @ fx 2 * CI0 @ + ZI !
        TMP @ ZR !
        I @ 1 + I !
        ZR @ ZR @ fx ZI @ ZI @ fx + 256 <
        I @ 32 <
        and
      while repeat
      I @ 32 < if 42 else 32 then emit
    CSTEP + repeat drop cr
  RSTEP + repeat drop ;

mandel
