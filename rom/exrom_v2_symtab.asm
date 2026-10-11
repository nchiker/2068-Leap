; ============================================================================
; rom/exrom_v2_symtab.asm -- R10.7 P2: the tagged compile symbol table.
;
; Replaces CSYMTAB, STRSYMTAB, ARRSYMTAB and STRARRSYMTAB (four fixed-size,
; fixed-address, partly tiered tables and ~600 bytes of near-identical scan /
; find-or-create code) with ONE append-only table of variable-length records
; that lives in the pool's free space (a "compile arena"), not in the dense
; table bank. Spike: tools/spikes/tagged_symtab_spike.asm (docs/v2/R10_7_
; WORKSPACE_MANAGER_FEASIBILITY.md s15).
;
;   record = [rec_len:1][kind:1][namelen:1][index:1][name:namelen][extra:n]
;   table  = records..., terminated by a 0 byte; SYM_END_V -> that 0 byte
;   kind   : 0 numeric scalar, 1 string scalar, 2 numeric array,
;            3 string array, 4 label/PROC/FN (P2b)
;   index  : per-kind running count -- exactly the 1-byte operand the VM and
;            bytecode already use, so the bytecode format is unchanged
;   extra  : numeric array = size(2); string array = size(2)+width(1)
;
; The table starts at PROG_END (SYM_RESET) and grows up toward SYM_LIMIT_V
; (V2_SOURCE_END; the compile stack of P2b moves it down). It persists after
; the compile until the next compile or edit, because SAVE/LOAD ... ARRAY look
; array names up here after a RUN. VM_INIT starts the array arena right after
; it (ARRAYS_END = SYM_END_V + 1), so the table can never be overwritten by an
; array, and any line-store change resets it (V2_CLEAR_ARRAYS).
;
; Per-kind caps (SYM_CAPS) are only the one-byte operand limit (255 per kind, less
; the temp slots); a 0 cap means "memory-limited only".
; ============================================================================
; (SYM_K_*, SYM_COUNTS, SYM_BASE_V, SYM_END_V, SYM_LIMIT_V, SS_NAME and the
; *_COUNT aliases are defined in include/v2_layout.inc so vm_core can see them.)

; [cap][error code when the cap is reached], per kind. R10.7 P3: the run-time
; tables are sized from the compiler's counts, so the only remaining caps are the
; one-byte symbol operand (255 per kind) less the round-robin temp slots that
; follow the numeric (float temps) and string (string temps) variables.
SYM_CAPS:
        db 255-FLOATTAB_TEMP_COUNT, 1
        db 255-STRTAB_TEMP_COUNT, 1
        db 255, 39
        db 255, 39
        db 0, 0

; SYM_RESET -- empty table at PROG_END, counts zeroed. Destroys: AF, BC, DE, HL.
SYM_RESET:
        ld hl,(PROG_END)
        ld (SYM_BASE_V),hl
        ld (SYM_END_V),hl
        ld (hl),0
        ld hl,V2_SOURCE_END
        ld (SYM_LIMIT_V),hl
        ld hl,SYM_COUNTS
        ld de,SYM_COUNTS+1
        ld bc,4
        ld (hl),b
        ldir
        ret

; SYM_FIND -- HL = name, B = length, C = kind.
;   found    : carry clear, A = index, HL = record start
;   not found: carry set,   A = next index for this kind, HL = free slot
; Preserves B and C. Destroys: DE.
SYM_FIND:
        ld (SS_NAME),hl
        ld a,b
        call CLAMP_IDENT_LEN    ; R10.7: >31 characters is error 61, never truncated silently
        ld b,a
        ld hl,(SYM_BASE_V)
.rec:
        ld a,(hl)
        or a
        jr z,.nf
        push hl
        inc hl
        ld a,(hl)               ; kind
        cp c
        jr nz,.skip
        inc hl
        ld a,(hl)               ; namelen
        cp b
        jr nz,.skip
        inc hl
        inc hl                  ; -> name
        ld de,(SS_NAME)
        push bc
        call NAME_CMP_FOLD
        pop bc
        jr nz,.skip
        pop hl
        inc hl
        inc hl
        inc hl
        ld a,(hl)               ; index
        dec hl
        dec hl
        dec hl
        or a                    ; carry clear
        ret
.skip:
        pop hl
        ld e,(hl)
        ld d,0
        add hl,de
        jr .rec
.nf:
        push hl
        ld hl,SYM_COUNTS
        ld e,c
        ld d,0
        add hl,de
        ld a,(hl)
        pop hl
        scf
        ret

; SYM_ADD -- after a not-found SYM_FIND: A = next index, HL = free slot,
; C = kind, B = name length, E = size of the extra fields (zero-filled); the
; name pointer is still in SS_NAME.
;   success: carry clear, A = index, HL -> the extra bytes
;   failure: carry set,   A = the compile error code to raise (the kind's
;            cap error, or 62 = compile memory exhausted); nothing changed
SYM_ADD:
        push hl                 ; slot
        push de                 ; E = extra size
        push af                 ; count
        ld l,c
        ld h,0
        add hl,hl
        ld de,SYM_CAPS
        add hl,de
        ld e,(hl)               ; cap (0 = none)
        inc hl
        ld d,(hl)               ; error code
        pop af
        ld h,a                  ; H = count
        ld a,e
        or a
        jr z,.capok
        cp h
        jr nz,.capok
        ld a,d
        jr .fail
.capok:
        pop de                  ; E = extra size
        pop hl                  ; slot
        ld a,b
        add a,4
        add a,e
        ld d,a                  ; D = rec_len
        push hl
        push de
        ld e,d
        ld d,0
        add hl,de
        inc hl                  ; slot + rec_len + 1 (terminator included)
        ld de,(SYM_LIMIT_V)
        or a
        sbc hl,de
        jr c,.fits
        jr z,.fits
        pop de
        pop hl
        ld a,62
        scf
        ret
.fail:
        pop de
        pop hl
        scf
        ret
.fits:
        pop de                  ; D = rec_len, E = extra
        pop hl                  ; slot
        ld (hl),d
        inc hl
        ld (hl),c
        inc hl
        ld (hl),b
        inc hl
        push hl
        push de
        ld hl,SYM_COUNTS
        ld e,c
        ld d,0
        add hl,de
        ld a,(hl)
        inc (hl)
        pop de
        pop hl
        ld (hl),a               ; index
        inc hl
        push af
        push de                 ; E = extra
        ex de,hl                ; DE = destination
        ld hl,(SS_NAME)
        ld c,b
        ld b,0
        ldir                    ; copy the name
        ex de,hl                ; HL = first extra byte
        pop de                  ; E = extra size
        push hl
        ld a,e
        or a
        jr z,.noext
        ld b,a
.zx:
        ld (hl),0
        inc hl
        djnz .zx
.noext:
        ld (hl),0               ; terminator
        ld (SYM_END_V),hl
        pop hl                  ; HL -> extra bytes
        pop af                  ; A = index
        or a                    ; carry clear
        ret

; SYM_FOC -- find-or-create a symbol with no extra fields. HL = name, B =
; length, C = kind. Out: A = index. Table full: the error is raised and A = 0
; (the contract CSYM/STRSYM_FIND_OR_CREATE always had).
SYM_FOC:
        call SYM_FIND
        ret nc
        ld e,0
        call SYM_ADD
        ret nc
        call COMPILE_RAISE_ERROR
        xor a
        ret

; CSYM_FIND_OR_CREATE / STRSYM_FIND_OR_CREATE -- HL = name pointer, B = name
; length (already clamped to IDENT_MAX_LEN by the caller). Out: A = index.
CSYM_FIND_OR_CREATE:
        ld c,SYM_K_NUM
        jr SYM_FOC
STRSYM_FIND_OR_CREATE:
        ld c,SYM_K_STR
        jr SYM_FOC

; ARRSYM_FIND_OR_CREATE -- a DIM: HL = name, B = length, ARR_SIZE_TMP = size.
; Redeclaring is error 38; table full 39. Out: A = the new array's index.
ARRSYM_FIND_OR_CREATE:
        ld c,SYM_K_ARR
        call SYM_FIND
        jr c,.nf
        ld a,38
        jp COMPILE_RAISE_ERROR
.nf:
        ld e,2
        call SYM_ADD
        jp c,COMPILE_RAISE_ERROR
        ld de,(ARR_SIZE_TMP)
        ld (hl),e
        inc hl
        ld (hl),d
        ret

; ARRSYM_LOOKUP -- HL = name, B = length. Not found: carry set. Found:
; carry clear, A = index, ARR_SIZE_TMP = its size.
ARRSYM_LOOKUP:
        ld c,SYM_K_ARR
        call SYM_FIND
        ret c
        push af
        ld de,4
        add hl,de
        ld e,b
        ld d,0
        add hl,de               ; -> extra bytes
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld (ARR_SIZE_TMP),de
        pop af
        or a
        ret

STRARRSYM_FIND_OR_CREATE:
        ld c,SYM_K_SARR
        call SYM_FIND
        jr c,.nf
        ld a,38
        jp COMPILE_RAISE_ERROR
.nf:
        ld e,3
        call SYM_ADD
        jp c,COMPILE_RAISE_ERROR
        push af                 ; A = the new index must survive the width load
        ld de,(STRARR_SIZE_TMP)
        ld (hl),e
        inc hl
        ld (hl),d
        inc hl
        ld a,(STRARR_WIDTH_TMP)
        ld (hl),a
        pop af
        ret

STRARRSYM_LOOKUP:
        ld c,SYM_K_SARR
        call SYM_FIND
        ret c
        push af
        ld de,4
        add hl,de
        ld e,b
        ld d,0
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld (STRARR_SIZE_TMP),de
        inc hl
        ld a,(hl)
        ld (STRARR_WIDTH_TMP),a
        pop af
        or a
        ret

; ---------------------------------------------------------------------------
; Labels, PROCs and DEF FNs (kind 4): extra = [value:2][defined:1].
; Forward references need NO table: an unresolved operand slot holds the
; previous unresolved slot's address (0 ends the chain) and the label record
; holds the chain head; LABEL_DEFINE walks the chain once and patches it.
; Replaces LABELTAB (8 entries) and FIXUPTAB (8 entries) and their ~260 bytes
; of code; a program may now define as many labels/PROCs/FNs as memory allows.
; ---------------------------------------------------------------------------

; LABEL_REF -- HL = name, B = length (<= IDENT_MAX_LEN), DE = address of the
; 16-bit operand slot to fill (already emitted).
;   defined label : slot = its offset
;   undefined     : slot = previous chain head, record head = this slot
LABEL_REF:
        push de
        ld c,SYM_K_LAB
        call SYM_FIND
        jr nc,.have
        ld e,3
        call SYM_ADD
        jr nc,.have2
        pop de
        jp COMPILE_RAISE_ERROR  ; A = the error code
.have:
        ld de,4
        add hl,de
        ld e,b
        ld d,0
        add hl,de               ; -> extra bytes
.have2:
        pop de                  ; DE = slot
        inc hl
        inc hl
        ld a,(hl)               ; defined?
        dec hl
        dec hl
        or a
        jr z,.fwd
        ld a,(hl)               ; defined: slot = offset
        ld (de),a
        inc hl
        inc de
        ld a,(hl)
        ld (de),a
        ret
.fwd:
        ld a,(hl)               ; slot = old head
        ld (de),a
        inc hl
        inc de
        ld a,(hl)
        ld (de),a
        dec de
        ld (hl),d               ; head = this slot
        dec hl
        ld (hl),e
        ret

; LABEL_DEFINE -- HL = name, B = length: defines the label at the CURRENT
; bytecode offset and patches every pending forward reference. A name that is
; already defined keeps its first definition (the behaviour LABEL_LOOKUP's
; first-match always gave).
LABEL_DEFINE:
        push hl
        push bc
        call COMPILE_RELATIVE_OFFSET
        ex de,hl                ; DE = offset
        pop bc
        pop hl
        push de
        ld c,SYM_K_LAB
        call SYM_FIND
        jr nc,.have
        ld e,3
        call SYM_ADD
        jr c,.full
        jr .set
.have:
        ld de,4
        add hl,de
        ld e,b
        ld d,0
        add hl,de
        inc hl
        inc hl
        ld a,(hl)
        dec hl
        dec hl
        or a
        jr z,.walk
        pop de                  ; already defined: first definition wins
        ret
.walk:
        pop de
        push de                 ; DE = offset
        ld c,(hl)
        inc hl
        ld b,(hl)               ; BC = chain head
        dec hl
.chain:
        ld a,b
        or c
        jr z,.set
        ld a,(bc)
        push af                 ; next slot lo
        inc bc
        ld a,(bc)
        push af                 ; next slot hi
        ld a,d
        ld (bc),a               ; slot+1 = offset hi
        dec bc
        ld a,e
        ld (bc),a               ; slot+0 = offset lo
        pop af
        ld b,a
        pop af
        ld c,a
        jr .chain
.set:
        pop de
        ld (hl),e
        inc hl
        ld (hl),d
        inc hl
        ld (hl),1               ; defined
        ret
.full:
        pop de
        jp COMPILE_RAISE_ERROR  ; A = the error code

; LABEL_CHECK_ALL -- after the compile: raise error 7 if any label was
; referenced but never defined.
LABEL_CHECK_ALL:
        ld hl,(SYM_BASE_V)
.rec:
        ld a,(hl)
        or a
        ret z
        ld e,a
        ld d,0
        inc hl
        ld a,(hl)               ; kind
        dec hl
        cp SYM_K_LAB
        jr nz,.next
        push hl
        add hl,de
        dec hl                  ; defined flag = last byte of the record
        ld a,(hl)
        pop hl
        or a
        jr nz,.next
        ld a,7
        jp COMPILE_RAISE_ERROR
.next:
        add hl,de
        jr .rec

; ---------------------------------------------------------------------------
; Compile stack: 5-byte frames that grow DOWN from V2_SOURCE_END while the
; symbol table grows up, so the two share one memory-limited arena. The
; innermost frame is at (SYM_LIMIT_V); no frame is open when SYM_LIMIT_V ==
; V2_SOURCE_END. Used for the FOR loops currently being compiled:
;   frame = [var_index:1][top_offset:2][exit_chain_head:2]
; ---------------------------------------------------------------------------
CSTK_FRAME_LEN: equ 7           ; STUDY: +2 = the source line of the FOR (frame+5)

; CSTK_PUSH -- open a frame. Out: carry clear, HL = the new frame; carry set
; (error 62 raised) when the arena is full.
CSTK_PUSH:
        ld hl,(SYM_LIMIT_V)
        ld de,CSTK_FRAME_LEN
        or a
        sbc hl,de
        ex de,hl                ; DE = new limit
        ld hl,(SYM_END_V)
        or a
        sbc hl,de               ; carry if SYM_END < new limit (terminator fits)
        jr c,.ok
        ld a,62
        call COMPILE_RAISE_ERROR
        scf
        ret
.ok:
        ld (SYM_LIMIT_V),de
        ex de,hl                ; HL = new limit = the frame
        or a
        ret

; CSTK_TOP -- Out: Z set if no frame is open, else NZ and HL = innermost frame.
CSTK_TOP:
        ld hl,(SYM_LIMIT_V)
        ld de,V2_SOURCE_END
        or a
        sbc hl,de
        ret z
        ld hl,(SYM_LIMIT_V)
        ret                     ; NZ from the sbc
