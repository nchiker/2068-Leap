; ============================================================================
; basic/legacy_kernel_compat.asm — legacy-fixture-only kernel compatibility
; shims, owned entirely by the non-production V1 component-test chain
; (basic/basic.asm and friends — see this file's own header and
; docs/v2/R10_7_DORMANT_ARCHITECTURE_AUDIT.md §3/§6.4 for the full
; disposition).
;
; The six routines below (MEM_LABEL_TABLE_CLEAR/FIND/LOOKUP/ADD,
; IO_ANY_KEY_DOWN, STICK_READ, IO_CHECK_BREAK) were removed from the
; shared, production-resident kernel/memory/memory.asm and kernel/io/
; io.asm by the R10.7 dormant-ROM-consolidation pass on the correct
; evidence that rom/v2_home.asm/rom/v2_exrom.asm (the real, shipping V2
; production ROM) never call them. That removal was correct and is NOT
; reversed here, and production ROM bytes are NOT spent restoring these.
;
; What IS true: basic/basic.asm (never shipped, never production --
; confirmed by direct INCLUDE-chain trace in the dormant-architecture
; audit) still calls all six, because it predates the V2 cutover and was
; deliberately kept, unmodified, as a component-test fixture backing a
; handful of still-useful tests (tools/run_editor_auto_test.sh,
; tools/run_storage_named_load_test.sh and friends). The kernel removal
; broke that fixture's own assembly, because kernel/memory.asm and
; kernel/io.asm are SHARED files, included by both the real V2 chain and
; this legacy chain.
;
; This file is the fixture's own copy of its own obsolete dependencies --
; "legacy test scaffolding owns its own obsolete dependencies" rather than
; the shared production kernel carrying dead code to keep an old test
; building. It is included ONLY from basic/basic.asm, which is itself
; included ONLY by the non-production test harnesses listed above; it
; contributes zero bytes to rom/v2_home.asm or rom/v2_exrom.asm.
;
; Bodies below are verbatim copies of the original kernel/memory/
; memory.asm and kernel/io/io.asm routines, restored unchanged from the
; pre-removal source (git history) -- not reimplemented, not altered.
; ============================================================================

; ============================================================================
; MEM_LABEL_TABLE_CLEAR
; Resets just the label table to empty, leaving the program itself
; untouched. basic/basic.asm's own BASIC_RUN needs this reset before its
; label pre-pass; this fixture also calls it explicitly right after every
; MEM_INIT call (cold boot, NEW, and the load-failed-dirty path), since
; production's own MEM_INIT no longer tail-jumps here the way it did
; before the R10.7 removal.
; In:  none
; Out: none
; Destroys: AF, HL
; ============================================================================
MEM_LABEL_TABLE_CLEAR:
    xor  a
    ld   (LABEL_TABLE_TOP), a
    ld   (LABEL_TABLE_TOP+1), a
    ld   hl, 2                    ; LABEL_TABLE_USED starts at 2: just the
    ld   (LABEL_TABLE_USED), hl   ; 2-byte count header, no entries yet.
    ret

; ============================================================================
; MEM_LABEL_FIND (internal — not declared in kernel_api.inc)
; Shared scan logic for MEM_LABEL_LOOKUP. Written once here rather than
; duplicated in every caller.
; In:  HL = pointer to name, B = name length
; Out: carry clear + HL = pointer to the entry's 2-byte position field,
;      C = entry's name_len; carry set if not found
; Destroys: AF, BC, DE, HL
; ============================================================================
MEM_LABEL_FIND:
    ld   (LOOKUP_NAME_PTR), hl
    ld   a, b
    ld   (LOOKUP_NAME_LEN), a

    ld   hl, (LABEL_TABLE_TOP)
    ld   (LOOKUP_ENTRY_COUNT), hl
    ld   hl, LABEL_TABLE_TOP
    inc  hl
    inc  hl                       ; HL = first entry (past the 2-byte count)

.scan_loop:
    ld   de, (LOOKUP_ENTRY_COUNT)
    ld   a, d
    or   e
    jr   z, .not_found

    ld   a, (hl)
    inc  hl                       ; HL -> entry name bytes (entry_start+1)
    ld   c, a                     ; C = this entry's name_len

    ld   a, (LOOKUP_NAME_LEN)
    cp   c
    jr   nz, .skip_entry

    ld   a, c
    or   a
    jr   z, .match                ; both zero-length: trivially equal —
                                  ; HL is already correctly positioned
                                  ; (no name bytes to skip over)

    push hl                       ; save entry name start, in case of a
                                  ; length-matched-but-content-differs fail
    ld   de, (LOOKUP_NAME_PTR)
    ld   b, c
.compare_loop:
    ld   a, (de)
    cp   (hl)
    jr   nz, .compare_fail
    inc  hl
    inc  de
    djnz .compare_loop
    ; full match: HL has advanced C times from entry name start, landing
    ; exactly on the position field — discard the saved value.
    pop  de
.match:
    or   a                        ; clear carry: found
    ret

.compare_fail:
    pop  hl                       ; HL restored = entry name start
    ; fall through — same skip as the length-mismatch path below.
.skip_entry:
    ld   b, 0
    add  hl, bc                    ; HL += name_len -> position field start
    inc  hl
    inc  hl                         ; HL += 2 -> next entry's name_len byte
    ld   de, (LOOKUP_ENTRY_COUNT)
    dec  de
    ld   (LOOKUP_ENTRY_COUNT), de
    jr   .scan_loop

.not_found:
    scf
    ret

; ============================================================================
; MEM_LABEL_LOOKUP
; Looks up a label by name in the top-level scope's table. Thin wrapper
; around MEM_LABEL_FIND.
; In:  HL = pointer to name, B = name length
; Out: carry clear + DE = program position on match; carry set if not found
; Destroys: AF, BC, DE, HL
; ============================================================================
MEM_LABEL_LOOKUP:
    call MEM_LABEL_FIND
    ret  c
    ld   e, (hl)
    inc  hl
    ld   d, (hl)
    or   a
    ret

; ============================================================================
; MEM_LABEL_ADD
; Adds a label to the top-level scope's table. Fails (carry set) if the
; name already exists in that scope or if the table is full
; (LABEL_TABLE_MAXLEN, see include/sysvars.inc).
; In:  HL = pointer to name, B = name length, DE = program position
; Out: carry clear on success; carry set on failure
; Destroys: AF, BC, DE, HL
; ============================================================================
MEM_LABEL_ADD:
    ld   (ADD_POSITION), de
    call MEM_LABEL_LOOKUP          ; also stashes LOOKUP_NAME_PTR/LEN,
                                   ; which the rest of this routine reads
                                   ; back rather than trusting HL/B to
                                   ; have survived the call
    jr   nc, .duplicate

    ld   a, (LOOKUP_NAME_LEN)
    add  a, 3                      ; entry size = name_len + 1 (len byte)
                                   ; + 2 (position)
    ld   c, a
    ld   b, 0
    ld   hl, (LABEL_TABLE_USED)
    add  hl, bc                    ; HL = projected new total
    ld   de, LABEL_TABLE_MAXLEN
    call MEM_FITS_CHECK
    ret  c                           ; table full
    ld   hl, LABEL_TABLE_TOP
    ld   de, (LABEL_TABLE_USED)
    add  hl, de                      ; HL = write pointer (current table end)

    ld   a, (LOOKUP_NAME_LEN)
    ld   (hl), a
    inc  hl

    ld   de, (LOOKUP_NAME_PTR)
    ld   a, (LOOKUP_NAME_LEN)
    or   a
    jr   z, .skip_name_copy           ; guard: B=0 into DJNZ below would
                                      ; wrap to 256 iterations
    ld   b, a
.copy_name_loop:
    ld   a, (de)
    ld   (hl), a
    inc  de
    inc  hl
    djnz .copy_name_loop
.skip_name_copy:

    ld   de, (ADD_POSITION)
    ld   (hl), e
    inc  hl
    ld   (hl), d

    ld   a, (LOOKUP_NAME_LEN)
    add  a, 3
    ld   c, a
    ld   b, 0
    ld   hl, (LABEL_TABLE_USED)
    add  hl, bc
    ld   (LABEL_TABLE_USED), hl

    ld   hl, (LABEL_TABLE_TOP)
    inc  hl
    ld   (LABEL_TABLE_TOP), hl

    or   a
    ret

.duplicate:
    scf
    ret

; ============================================================================
; IO_ANY_KEY_DOWN
; Checks whether any key anywhere on the keyboard is currently pressed.
; In:  none
; Out: carry set if at least one key is down, carry clear if none are
; Destroys: AF, BC, HL
; ============================================================================
IO_ANY_KEY_DOWN:
    call IO_KEY_SCAN_ALL           ; HL = IO_SCAN_TABLE
    ld   b, KEY_ROW_COUNT
.check_loop:
    ld   a, (hl)
    and  $1F                       ; only bits 0-4 are meaningful
    cp   $1F                        ; all 5 bits set = nothing pressed
                                   ; in this row
    jr   nz, .found
    inc  hl
    djnz .check_loop
    or   a                          ; clear carry: nothing found
    ret
.found:
    scf
    ret

; ============================================================================
; STICK_READ
; Reads a joystick's state through the AY-3-8912's I/O port A — see
; kernel/io/io.asm's removal comment for the real-ROM-disassembly
; provenance of this exact bit layout.
; In:  HL = device (1 or 2 — caller's own job to validate)
; Out: HL = stick value (device 1: 0-15, one bit per direction; device
;      2: 0 or 1)
; Destroys: AF, BC, HL
; ============================================================================
STICK_READ:
    ld   a, l
    ld   d, a                          ; D = device (1 or 2)
    ld   a, $0E
    out  (PORT_AY_REG), a               ; select AY register 14 (I/O
                                        ; port A)
    ld   c, PORT_AY_DATA
    in   a, (c)                          ; A = raw joystick lines
    cpl                                   ; active-low -> active-high
    ld   b, d                             ; B = device, DJNZ's own
                                          ; counter
    djnz .stick2
    and  $0F                              ; stick 1: low nibble = the
                                          ; four direction bits
    cp   $0F
    jr   c, .done                         ; not all four bits set
    xor  a                                 ; all bits set -> force 0
    jr   .done
.stick2:
    rlca                                   ; stick 2: only bit 7
                                           ; (rotated into bit 0) is
                                           ; meaningful
    and  $01
.done:
    ld   l, a
    ld   h, 0
    ret

; ============================================================================
; IO_CHECK_BREAK
; Non-blocking check for the BREAK combo (CAPS SHIFT+SPACE) currently
; being held down. Meant to be polled once per statement from inside
; basic/basic.asm's own BASIC_RUN execution loop.
; In:  none
; Out: carry set if BREAK is currently held, carry clear otherwise
; Destroys: AF, BC, DE, HL
; ============================================================================
IO_CHECK_BREAK:
    call IO_KEY_SCAN_ALL
    call IO_FIND_KEY
    ret  nc                       ; zero, or 2+, non-modifier keys down —
                                  ; can't be an exact CAPS SHIFT+SPACE combo
    call IO_DECODE_KEY            ; B/C = the one non-modifier key found;
                                  ; checks CAPS SHIFT state itself
    cp   KEY_BREAK
    jr   z, .found
    or   a                        ; some other key/combo — clear carry
    ret
.found:
    scf
    ret
