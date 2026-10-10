; ============================================================================
; tools/spikes/ws_manager_spike.asm -- R10.7 Workspace Manager feasibility
; SPIKE. NON-PRODUCTION: not included by any Makefile target, not part of
; v2_home.asm / v2_exrom.asm, touches no production RAM. Exists only to
; MEASURE the real byte cost of the smallest useful workspace manager and to
; exercise its semantics (alloc, release, nesting, overflow, ownership).
;
; Build:  sjasmplus tools/spikes/ws_manager_spike.asm   (writes
;         build/spikes/ws_manager_spike.bin, a 24K ZEsarUX-style image)
; Run:    tools/spikes/run_ws_spike.sh   (border 4 = PASS, 2 = FAIL)
;
; Design: ONE arena [base,limit). Two ends.
;   LOW end  = temporary workspaces: WS_ALLOC bumps WS_TOP up, WS_MARK /
;              WS_RELEASE give strictly LIFO ownership (no fragmentation).
;   HIGH end = persistent allocations (sprite buffers, package scratch):
;              WS_ALLOC_HI bumps WS_LIMIT down, never released except by
;              WS_INIT (i.e. CLEAR/NEW). Temp and persistent collide ->
;              carry set, nothing changes.
; No heap, no free list, no compaction, no relocation.
; ============================================================================
    DEVICE NOSLOT64K

WS_TOP      EQU $8000       ; 2 B  next free byte (low end)
WS_LIMIT    EQU $8002       ; 2 B  one past last free byte (high end moves down)
RESULT      EQU $8010       ; test number that failed (0 = none)

    ORG 0
START:
    di
    ld   sp,$FF00
    jp   RUN_TESTS

; ---------------------------------------------------------------------------
; MEASURED CORE -- the four requested operations
; ---------------------------------------------------------------------------
WS_CORE_BEGIN:
; WS_INIT: HL = base, DE = limit (exclusive)
WS_INIT:
    ld   (WS_TOP),hl
    ld   (WS_LIMIT),de
    ret
; WS_MARK: -> HL = current top (opaque mark)
WS_MARK:
    ld   hl,(WS_TOP)
    ret
; WS_ALLOC: BC = size. -> HL = base of block, carry clear.
;           Failure: carry set, WS_TOP unchanged, HL undefined.
WS_ALLOC:
    ld   hl,(WS_TOP)
    add  hl,bc
    ret  c                  ; 16-bit wrap
    ex   de,hl              ; DE = new top
    ld   hl,(WS_LIMIT)
    or   a
    sbc  hl,de              ; carry if limit < new top
    ret  c
    ld   hl,(WS_TOP)        ; block base (carry is clear here)
    ld   (WS_TOP),de
    ret
; WS_RELEASE: HL = mark from WS_MARK. Frees everything allocated since.
WS_RELEASE:
    ld   (WS_TOP),hl
    ret
WS_CORE_END:

; ---------------------------------------------------------------------------
; OPTIONAL: persistent high-end allocation (sprite buffers etc.)
; WS_ALLOC_HI: BC = size -> HL = base, carry clear. Failure: carry set,
; nothing changes. Collides with the low end -> failure.
; ---------------------------------------------------------------------------
WS_HI_BEGIN:
WS_ALLOC_HI:
    ld   hl,(WS_LIMIT)
    or   a
    sbc  hl,bc              ; new limit
    ret  c                  ; went below 0
    ex   de,hl              ; DE = new limit
    ld   hl,(WS_TOP)
    or   a
    sbc  hl,de              ; carry clear if top <= new limit? (top - newlimit)
    jr   z,.ok
    jr   nc,.fail           ; top > new limit -> collision
.ok:
    ld   (WS_LIMIT),de
    ex   de,hl
    or   a                  ; carry clear, HL = new limit = block base
    ret
.fail:
    scf
    ret
WS_HI_END:

; ---------------------------------------------------------------------------
; OPTIONAL: ownership-checked release (rejects a mark above the current top,
; i.e. a stale/foreign mark). HL = mark. Carry set = rejected, nothing done.
; ---------------------------------------------------------------------------
WS_CHK_BEGIN:
WS_RELEASE_CHK:
    ld   de,(WS_TOP)
    ex   de,hl              ; HL = top, DE = mark
    or   a
    sbc  hl,de              ; top - mark
    ret  c                  ; mark > top -> reject
    ld   (WS_TOP),de
    or   a
    ret
WS_CHK_END:

; ===========================================================================
; TESTS
; ===========================================================================
BASE        EQU $9000
LIMIT       EQU $9100       ; 256-byte arena

T           MACRO n
            ld   a,n
            ld   (RESULT),a
            ENDM

RUN_TESTS:
    xor  a
    ld   (RESULT),a

    ; 1: alloc returns sequential bases
    T 1
    ld   hl,BASE : ld de,LIMIT : call WS_INIT
    ld   bc,100 : call WS_ALLOC : jp c,FAIL
    ld   de,BASE : or a : sbc hl,de : jp nz,FAIL
    ld   bc,50 : call WS_ALLOC : jp c,FAIL
    ld   de,BASE+100 : or a : sbc hl,de : jp nz,FAIL
    call WS_MARK : ld de,BASE+150 : or a : sbc hl,de : jp nz,FAIL

    ; 2: mark / alloc / release restores top exactly
    T 2
    call WS_MARK : push hl
    ld   bc,30 : call WS_ALLOC : jp c,FAIL
    pop  hl : call WS_RELEASE
    call WS_MARK : ld de,BASE+150 : or a : sbc hl,de : jp nz,FAIL

    ; 3: nesting (LIFO): outer mark, inner mark, release inner then outer
    T 3
    call WS_MARK : push hl            ; outer
    ld   bc,10 : call WS_ALLOC : jp c,FAIL
    call WS_MARK : push hl            ; inner
    ld   bc,20 : call WS_ALLOC : jp c,FAIL
    pop  hl : call WS_RELEASE         ; inner
    call WS_MARK : ld de,BASE+160 : or a : sbc hl,de : jp nz,FAIL
    pop  hl : call WS_RELEASE         ; outer
    call WS_MARK : ld de,BASE+150 : or a : sbc hl,de : jp nz,FAIL

    ; 4: exact fit allowed (top == limit), then 1 more byte fails, top intact
    T 4
    ld   bc,LIMIT-(BASE+150) : call WS_ALLOC : jp c,FAIL
    call WS_MARK : ld de,LIMIT : or a : sbc hl,de : jp nz,FAIL
    ld   bc,1 : call WS_ALLOC : jp nc,FAIL        ; must fail
    call WS_MARK : ld de,LIMIT : or a : sbc hl,de : jp nz,FAIL  ; unchanged

    ; 5: overflow by wrap (size 0xFFFF) fails, top unchanged
    T 5
    ld   hl,BASE : call WS_RELEASE
    ld   bc,$FFFF : call WS_ALLOC : jp nc,FAIL
    call WS_MARK : ld de,BASE : or a : sbc hl,de : jp nz,FAIL

    ; 6: zero-size alloc returns top and changes nothing
    T 6
    ld   bc,0 : call WS_ALLOC : jp c,FAIL
    ld   de,BASE : or a : sbc hl,de : jp nz,FAIL

    ; 7: failed alloc leaves a usable arena (alloc after failure succeeds)
    T 7
    ld   bc,$0200 : call WS_ALLOC : jp nc,FAIL
    ld   bc,16 : call WS_ALLOC : jp c,FAIL

    ; 8: high-end persistent alloc shrinks the limit; temp alloc sees it
    T 8
    ld   hl,BASE : ld de,LIMIT : call WS_INIT
    ld   bc,64 : call WS_ALLOC_HI : jp c,FAIL
    ld   de,LIMIT-64 : or a : sbc hl,de : jp nz,FAIL
    ld   bc,256-64 : call WS_ALLOC : jp c,FAIL        ; exactly fills the rest
    ld   bc,1 : call WS_ALLOC : jp nc,FAIL            ; now full

    ; 9: high alloc collides with temp -> fails, limit unchanged
    T 9
    ld   hl,BASE : ld de,LIMIT : call WS_INIT
    ld   bc,100 : call WS_ALLOC : jp c,FAIL           ; temp 100
    ld   bc,100 : call WS_ALLOC_HI : jp c,FAIL        ; 100+100 <= 256 ok
    ld   de,LIMIT-100 : or a : sbc hl,de : jp nz,FAIL
    ld   bc,100 : call WS_ALLOC_HI : jp nc,FAIL       ; 100+100+100 > 256
    ld   hl,(WS_LIMIT) : ld de,LIMIT-100 : or a : sbc hl,de : jp nz,FAIL

    ; 10: temp release does not free persistent memory
    T 10
    ld   hl,BASE : call WS_RELEASE
    ld   hl,(WS_LIMIT) : ld de,LIMIT-100 : or a : sbc hl,de : jp nz,FAIL
    ld   bc,156 : call WS_ALLOC : jp c,FAIL           ; fills up to persistent
    ld   bc,1 : call WS_ALLOC : jp nc,FAIL

    ; 11: ownership-checked release rejects a stale mark above top
    T 11
    ld   hl,BASE : call WS_RELEASE
    ld   bc,10 : call WS_ALLOC
    ld   hl,BASE+50 : call WS_RELEASE_CHK : jp nc,FAIL   ; 50 > top(10): reject
    call WS_MARK : ld de,BASE+10 : or a : sbc hl,de : jp nz,FAIL
    ld   hl,BASE+4 : call WS_RELEASE_CHK : jp c,FAIL     ; valid
    call WS_MARK : ld de,BASE+4 : or a : sbc hl,de : jp nz,FAIL

    ; 12: phase reuse (compile zone -> run zone share the same bytes)
    T 12
    ld   hl,BASE : ld de,LIMIT : call WS_INIT
    call WS_MARK : push hl
    ld   bc,40 : call WS_ALLOC : jp c,FAIL            ; compile table A
    push hl
    ld   bc,60 : call WS_ALLOC : jp c,FAIL            ; compile table B
    pop  de : pop  hl : push de
    call WS_RELEASE                                   ; compile phase ends
    ld   bc,90 : call WS_ALLOC : jp c,FAIL            ; run table reuses base
    pop  de : or a : sbc hl,de : jp nz,FAIL           ; same base as table A
    jp   PASS

FAIL:
    ld   a,2
    out  ($FE),a
    halt
    jr   FAIL
PASS:
    ld   a,4
    out  ($FE),a
.h: halt
    jr   .h

    DISPLAY "WS core bytes (INIT+MARK+ALLOC+RELEASE): ", WS_CORE_END-WS_CORE_BEGIN
    DISPLAY "WS_ALLOC_HI bytes: ", WS_HI_END-WS_HI_BEGIN
    DISPLAY "WS_RELEASE_CHK bytes: ", WS_CHK_END-WS_CHK_BEGIN
    DISPLAY "WS_INIT=", WS_MARK-WS_INIT, " WS_MARK=", WS_ALLOC-WS_MARK, " WS_ALLOC=", WS_RELEASE-WS_ALLOC, " WS_RELEASE=", WS_CORE_END-WS_RELEASE
    DS $6000-$,0
    SAVEBIN "build/spikes/ws_manager_spike.bin",0,$6000
