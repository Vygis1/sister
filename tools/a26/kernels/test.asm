; test.asm - the gate kernel for sim/tb_a26.v.
;
; A 262-line NTSC frame with a known picture, built so that every pixel the bench
; checks follows from the console's documented rules:
;
;   playfield  PF0=$F0 PF1=$55 PF2=$00, repeated (no reflect)
;   player 0   solid, at pixel 3 (RESP0 in horizontal blank)
;   player 1   $81, at pixel 80 (the divide-by-15 positioning loop + HMOVE)
;   missile 0  one clock wide, positioned "at 40" by the same loop -> pixel 39
;   ball       one clock wide, positioned "at 100" -> pixel 99
;
; Before the first frame the RIOT timer is exercised and the results stored in
; RAM; during the frame the switches, the fire button and the collision latches
; are read into RAM. Addresses and expected values are listed at the bottom.
;
; Assemble: python tools/a26/asm.py tools/a26/kernels/test.asm test.bin

VSYNC   = $00
VBLANK  = $01
WSYNC   = $02
NUSIZ0  = $04
NUSIZ1  = $05
COLUP0  = $06
COLUP1  = $07
COLUPF  = $08
COLUBK  = $09
CTRLPF  = $0A
PF0     = $0D
PF1     = $0E
PF2     = $0F
RESP0   = $10
GRP0    = $1B
GRP1    = $1C
ENAM0   = $1D
ENABL   = $1F
HMP0    = $20
HMOVE   = $2A
HMCLR   = $2B
CXCLR   = $2C
CXP0FB  = $02
CXBLPF  = $06
CXPPMM  = $07
INPT4   = $0C
SWCHA   = $0280
SWCHB   = $0282
INTIM   = $0284
TIMINT  = $0285
TIM8T   = $0295
TIM64T  = $0296

    .org $F000
start:
    sei
    cld
    ldx #$FF
    txs
    lda #0
clear:
    sta 0,x             ; TIA and RAM both; the strobes it hits do no harm here
    dex
    bne clear

; --- the RIOT timer -----------------------------------------------------------
; Cycle counts from the write edge W (the fourth cycle of STA TIM8T):
;   lda INTIM reads at W+4   -> 5          (one step every 8 cycles)
;   lda INTIM reads at W+17  -> 3
;   the flag is up for reads from W+49; the loop's reads are at W+28,37,46,55 -> X=4
;   lda INTIM reads at W+64  -> $FF - 15 = $F0 (one step a cycle after underflow)
;   lda TIMINT after that    -> 0 (the INTIM read cleared the flag)
    lda #5
    sta TIM8T
    lda INTIM
    sta $80
    nop
    nop
    nop
    lda INTIM
    sta $81
    ldx #0
tloop:
    inx
    lda TIMINT
    bpl tloop
    stx $82
    lda INTIM
    sta $83
    lda TIMINT
    sta $84

; --- the frame ----------------------------------------------------------------------
frame:
    lda #2
    sta VSYNC
    sta WSYNC
    sta WSYNC
    sta WSYNC
    lda #0
    sta VSYNC
    lda #43
    sta TIM64T          ; 2752 cycles of the 37-line vertical blank

    lda #$46
    sta COLUP0
    lda #$86
    sta COLUP1
    lda #$C8
    sta COLUPF
    lda #0
    sta COLUBK
    sta CTRLPF
    sta NUSIZ0
    sta NUSIZ1
    lda #$F0
    sta PF0
    lda #$55
    sta PF1
    lda #0
    sta PF2

    sta WSYNC
    sta RESP0           ; written in horizontal blank: player 0 lands at pixel 3

    lda #80
    ldx #1
    jsr pos             ; player 1 at 80
    lda #40
    ldx #2
    jsr pos             ; missile 0 "at 40": a missile pipelines one clock less -> 39
    lda #100
    ldx #4
    jsr pos             ; ball "at 100" -> 99
    lda #0
    sta HMP0            ; player 0 stays where it is
    sta WSYNC
    sta HMOVE           ; applies the fine positions, with the usual black bar

    lda SWCHA
    sta $94
    lda INPT4
    sta $95
    lda SWCHB
    sta $96
    lda #$FF
    sta GRP0
    lda #$81
    sta GRP1
    lda #2
    sta ENAM0
    sta ENABL
    inc $97             ; frames seen ($FE/$FF are the stack: the 6507's stack lives in the RIOT's 128 bytes)
    sta WSYNC
    sta HMCLR

vbwait:
    lda INTIM
    bne vbwait
    sta WSYNC
    lda #0
    sta VBLANK          ; the picture: 192 lines
    ldy #192
pic:
    sta WSYNC
    dey
    bne pic

    lda #2
    sta VBLANK          ; before the picture would start again on this line
    lda CXP0FB
    sta $90             ; player 0 is over the playfield
    lda CXBLPF
    sta $91             ; the ball is not
    lda CXPPMM
    sta $92             ; the players do not meet
    lda #0
    sta GRP0
    sta GRP1
    sta ENAM0
    sta ENABL
    sta WSYNC           ; a whole line with nothing drawn
    sta WSYNC
    sta CXCLR
    lda CXP0FB
    sta $93             ; clear
    ldy #28             ; the rest of the 30-line overscan, counted in lines
osloop:
    sta WSYNC
    dey
    bne osloop
    jmp frame

; --- horizontal positioning --------------------------------------------------------
; A = pixel (0-159), X = object (0 P0, 1 P1, 2 M0, 3 M1, 4 BL). The classic loop:
; each pass is 15 pixels of processor time, the remainder becomes the fine motion.
; RESP0,x is written on cycle 5k+17 of the line, k passes: colour clock 15k+54,
; and the player's first pixel is 5 clocks on, at 15(k-1)+6; the motion of
; +6..-8 then reaches every pixel in the block of 15.
pos:
    sec
    sta WSYNC
ploop:
    sbc #15
    bcs ploop
    eor #7
    asl
    asl
    asl
    asl
    sta.wx HMP0,x       ; absolute,X: the fifth cycle is what puts RESP0 on the grid
    sta RESP0,x
    rts

; --- expected RAM ($80..): 05 03 04 F0 00; $90..: 82 06 07 02; $94: SWCHA $95: INPT4 $96: SWCHB $97: frames
    .org $FFFC
    .word start
    .word start
