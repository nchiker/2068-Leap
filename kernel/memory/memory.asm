; ============================================================================
; kernel/memory/memory.asm — line storage, program iterator, label table
;
; CURRENT STATUS: assembled into the working ROM and exercised under
; Fuse by the automated language/memory regression suite. The core fill,
; shift, line-storage, iterator, and label-table paths are implemented;
; remaining feature gaps are called out at their individual routines.
;
; Owns:
;   - The BASIC program area's on-disk/in-RAM format (line storage, no
;     line numbers — see docs/basic_language_reference.md).
;   - The program iterator (walk the program one statement at a time).
;   - Generic memory-shift primitives, reused by line storage, the
;     editor's insert/delete, and the label table's own insert/remove —
;     one implementation, several callers, per this project's "kernel
;     modules stay reusable" rule.
;   - The label table (name -> program position), which is what replaced
;     EDITOR_RENUMBER (see docs/basic_language_reference.md, "Label
;     table"). Top-level scope only for now — per-procedure scopes need
;     DEFine PROCedure/DEFine FuNction storage, which basic/ hasn't
;     designed yet.
;
; Explicitly NOT owned here: scanning program text for GOTO/GOSUB/RESTORE
; references to a label (the check EDITOR_BLOCK_DELETE needs before
; deleting a range). That requires understanding BASIC statement syntax,
; which is basic/'s job once it exists — kernel/memory only maintains the
; label DEFINITION table, not a reference index. EDITOR_BLOCK_DELETE's
; TODO reflects this split.
; ============================================================================

    INCLUDE "include/hardware.inc"
    INCLUDE "include/sysvars.inc"

; ---- line storage format (see docs/basic_language_reference.md) ----
; Each statement in the program area is stored as:
;   [length: 2 bytes, little-endian, counts the tokens+terminator below]
;   [tokenised statement text]
;   [terminator: 1 byte, $0D]
; No line-number field — the classic Sinclair BASIC format's 2-byte line
; number is simply absent, since there are no line numbers to store. The
; length-prefix mechanism itself (letting the iterator skip a whole
; statement without scanning it byte-by-byte) is otherwise unchanged from
; that lineage.
LINE_LEN_SIZE       EQU 2
LINE_TERMINATOR     EQU $0D

; ---- label table format (see docs/basic_language_reference.md) ----
; Table header:
;   [count: 2 bytes] — number of entries currently in this scope's table
; Each entry, contiguous, unsorted (tables are small — linear scan is
; fine; see "Open questions" in the language doc for the size budget):
;   [name_len: 1 byte]
;   [name: name_len bytes, NOT null-terminated]
;   [position: 2 bytes] — program-area address the label refers to
LABEL_COUNT_SIZE    EQU 2
LABEL_NAMELEN_SIZE  EQU 1
LABEL_POS_SIZE      EQU 2

; ============================================================================
; MEM_COLD_INIT
; Establishes the power-on invariant for every ROM-owned RAM byte.  Emulators
; commonly zero RAM, but real hardware and accuracy-oriented emulators may
; supply arbitrary values.  Clear the complete $8000-$BFFF system/program
; region before MEM_INIT or interrupts; the stack at $FF00 and display RAM are
; deliberately outside this range.
; In: none
; Out: $8000..PROG_AREA_MAX-1 = 0
; Destroys: AF, BC, DE, HL
; ============================================================================
MEM_COLD_INIT:
    ld   hl, $8000
    ld   bc, PROG_AREA_MAX - $8000
    jr   MEM_FILL_ZERO

; ============================================================================
; MEM_INIT
; Initializes the program area to empty and clears the top-level label
; table's entry count. Call once at cold start, and again on NEW. Without
; this, PROG_END holds whatever garbage was in RAM at power-on, and
; MEM_LINE_FIRST has no reliable way to tell "empty program" from
; "program starting at a stale pointer" — this was a real gap, caught by
; writing a test for MEM_LINE_FIRST rather than by inspection.
; In:  none
; Out: PROG_END = PROG_AREA_START; ARRAYS_END = PROG_END (no arrays
;      exist yet); VARS_START = PROG_AREA_MAX (no scalars exist yet);
;      LABEL_TABLE_TOP's count = 0; all sprite slots undefined/unshown
; Destroys: AF, BC, DE, HL
; ============================================================================
MEM_INIT:
    ld   hl, PROG_AREA_START
    ld   (PROG_END), hl
    ld   (ARRAYS_END), hl              ; dynamic arrays region starts
                                       ; empty (== PROG_END) — see
                                       ; sysvars.inc's own ARRAYS_END
                                       ; header for the full memory
                                       ; model
    ld   hl, PROG_AREA_MAX
    ld   (VARS_START), hl              ; scalar-variable pool also
                                       ; starts empty (== PROG_AREA_MAX)
                                       ; — see sysvars.inc's own VARS_
                                       ; START header. Previously this
                                       ; was VAR_TABLE's own separate
                                       ; zero-fill, done at NEW/LOAD but
                                       ; never at cold boot; folding it
                                       ; in here actually closes that
                                       ; gap rather than widening it
    xor  a
    ld   (STR_FUNC_POOL_NEXT), a        ; safety net, not load-bearing —
                                       ; correct acquire/release pairing
                                       ; within a statement's own
                                       ; evaluation should always leave
                                       ; this at 0 anyway (see sysvars.
                                       ; inc's own STR_FUNC_POOL header)
    ld   (EXTENSION_MAGIC), a           ; unregister RAM module before NEW/
    ld   (EXTENSION_MAGIC+1), a         ; cold boot can leave a stale target
    IFDEF FULL_ENGINE_PRESENT
    IFNDEF STACK_AUDIT
    ld   hl, EXT_SERVICE_TABLE_TEMPLATE
    ld   de, EXT_SERVICE_VERSION_ADDR
    ld   bc, EXT_SERVICE_TABLE_TEMPLATE_END - EXT_SERVICE_TABLE_TEMPLATE
    ldir
    ENDIF
    ENDIF
    ld   hl, SPRITE_SLOT_DEFINED
    ld   bc, SPRITE_SLOT_MAX * 2        ; DEFINED and SHOWN are contiguous
    call MEM_FILL_ZERO
    ld   (SPRITE_DISPLAY_DEPTH), a       ; MEM_FILL_ZERO returns A=0
    IFDEF FULL_ENGINE_PRESENT
    call BASIC_RESET_TEXT_ATTR           ; cold boot/NEW shared default
    ENDIF
    jr MEM_LABEL_TABLE_CLEAR

    IFDEF FULL_ENGINE_PRESENT
    IFNDEF STACK_AUDIT
; Fixed RAM ABI copied at NEW/cold initialization. Modules CALL the veneer
; addresses directly; each JP preserves the caller's stack and registers.
EXT_SERVICE_TABLE_TEMPLATE:
    DB EXT_SERVICE_ABI_VERSION
    DB $C3
    DW BASIC_EXTENSION_REGISTER
    DB $C3
    DW BASIC_COMPUTE_PRINT_ATTR
    DB $C3
    DW GFX_WRITE_PIXEL
    DB $C3
    DW BASIC_EXTENSION_READ_OVER
EXT_SERVICE_TABLE_TEMPLATE_END:
    ASSERT EXT_SERVICE_TABLE_TEMPLATE_END - EXT_SERVICE_TABLE_TEMPLATE == 13
    ENDIF
    ENDIF

; ============================================================================
; MEM_LABEL_TABLE_CLEAR
; Resets just the label table to empty, leaving the program itself
; untouched — split out of MEM_INIT (which still calls this) since
; basic/'s BASIC_RUN needs the same reset before its own label
; pre-pass, without wiping the program it's about to execute.
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
                                  ; Added when MEM_LABEL_ADD/REMOVE were
                                  ; written — LABEL_TABLE_USED didn't exist
                                  ; when this routine was first tested, so
                                  ; this line is new, not yet re-verified
                                  ; against rom/test_memory.asm.
    ret

; ============================================================================
; MEM_FILL_ZERO
; Zeroes BC bytes starting at HL. General utility, used by EDITOR_INIT and
; anywhere else that needs a cleared buffer.
; In:  HL = start address, BC = byte count
; Out: none
; Destroys: AF, BC, HL
; ============================================================================
MEM_FILL_ZERO:
    xor  a
MEM_FILL:
    ; MEM_FILL: as MEM_FILL_ZERO, but fills with A instead of always zero
    ; (falls through from MEM_FILL_ZERO with A already 0). Both entry
    ; points exposed since callers sometimes want a specific fill byte
    ; (e.g. padding) rather than always clearing to zero.
    ld   (hl), a
    ld   d, h
    ld   e, l
    inc  de
    dec  bc
    ld   a, b
    or   c
    ret  z                  ; BC was 1: single byte already written above
    ldir                     ; copy the just-written byte forward across
                            ; the rest of the range
    ret

; ============================================================================
; MEM_SHIFT_UP
; Shifts BC bytes starting at HL upward (to higher addresses) by DE bytes,
; opening a gap of DE bytes at HL for new data to be inserted into. Caller
; is responsible for writing the new data into the gap afterward; this
; routine only moves what was already there out of the way.
; In:  HL = start of block to shift, BC = block length, DE = shift amount
; Out: none
; Destroys: AF, BC, DE, HL
; ============================================================================
MEM_SHIFT_UP:
    ; BC=0 guard: LDDR with BC=0 on entry doesn't mean "0 bytes" — the Z80
    ; decrements BC first, so BC=0 wraps to $FFFF and copies 65536 bytes.
    ; Real Z80 gotcha, checked for explicitly rather than trusted to "just
    ; not come up."
    ld   a, b
    or   c
    ret  z

    ; Compute source_last = HL + BC - 1 (last byte of the block to move).
    add  hl, bc
    dec  hl

    ; Compute dest_last = source_last + DE (shift amount), landing in DE
    ; for LDDR, while HL keeps source_last. EX/ADD/EX rather than a
    ; direct "ADD DE,HL" — the Z80 doesn't have that instruction, only
    ; ADD HL,rr — so the swap is how you get the sum into DE instead of HL.
    ex   de, hl              ; DE = source_last, HL = shift amount
    add  hl, de              ; HL = shift amount + source_last = dest_last
    ex   de, hl              ; DE = dest_last, HL = source_last (restored)

    ; Traced by hand: start=$1000, len=5, shift=3 -> source_last=$1004,
    ; dest_last=$1007. LDDR copies $1004->$1007, $1003->$1006, ...,
    ; $1000->$1003, high-to-low, so no source byte is overwritten before
    ; it's read (destination addresses only catch up to source addresses
    ; that were already read in an earlier iteration). Leaves [$1000,
    ; $1002] — the opened gap — untouched, per this routine's contract.
    lddr
    ret

; ============================================================================
; MEM_SHIFT_DOWN
; Shifts BC bytes starting at HL downward (to lower addresses) by DE
; bytes, closing a gap — used after deleting data. Overlapping-safe via
; LDIR (forward copy is correct when shifting toward lower addresses).
; In:  HL = start of block to shift, BC = block length, DE = shift amount
; Out: none
; Destroys: AF, BC, DE, HL
; ============================================================================
MEM_SHIFT_DOWN:
    ; Same BC=0 gotcha as MEM_SHIFT_UP — LDIR with BC=0 wraps to 65536,
    ; not 0.
    ld   a, b
    or   c
    ret  z

    ; dest_start = HL - DE, computed via the stack rather than in-place
    ; so HL (source_start, needed by LDIR below) survives the subtraction.
    push hl
    or   a                    ; clear carry before SBC
    sbc  hl, de               ; HL = source_start - shift amount = dest_start
    ex   de, hl                ; DE = dest_start, HL = shift amount (unused
                              ; from here on)
    pop  hl                    ; HL = source_start (restored)

    ; Traced by hand: source_start=$1010, len=5, shift=3 -> dest_start=
    ; $100D. LDIR copies $1010->$100D, $1011->$100E, ..., $1014->$1011,
    ; low-to-high. Checked each write against still-pending reads: e.g.
    ; the write to $1010 (4th iteration) only happens after $1010 was
    ; already read (1st iteration), and no read after that point targets
    ; an address LDIR has already overwritten. Forward copy is what makes
    ; a downward shift overlap-safe — LDDR would be wrong here, LDIR
    ; would be wrong for MEM_SHIFT_UP above; each routine uses the one
    ; that's actually correct for its direction, not just "the other one."
    ldir
    ret

; ============================================================================
; MEM_LINE_FIRST
; Returns a pointer to the first statement in the program area.
; In:  none
; Out: HL = pointer to first statement's length prefix, or HL = 0 if the
;      program area is empty (PROG_END == PROG_AREA_START)
; Destroys: AF, DE, HL
; ============================================================================
MEM_LINE_FIRST:
    ld   hl, (PROG_END)
    ld   de, PROG_AREA_START
    or   a
    sbc  hl, de
    add  hl, de              ; restore HL, carry/zero flags now reflect
                            ; whether PROG_END == PROG_AREA_START
    jr   z, .empty
    ld   hl, PROG_AREA_START
    ret
.empty:
    ld   hl, 0
    ret

; ============================================================================
; MEM_LINE_NEXT
; Given a pointer to a statement's length prefix, returns a pointer to the
; next statement's length prefix.
; In:  HL = pointer to current statement's length prefix
; Out: HL = pointer to next statement's length prefix, or HL = 0 if the
;      given statement was the last one in the program
; Destroys: AF, BC, DE, HL
; ============================================================================
MEM_LINE_NEXT:
    push hl
    ld   e, (hl)
    inc  hl
    ld   d, (hl)             ; DE = this statement's stored length
    pop  hl
    ex   de, hl              ; HL = length, DE = pointer to length prefix
    ld   bc, LINE_LEN_SIZE
    add  hl, bc               ; HL = length + LINE_LEN_SIZE (whole record size)
    add  hl, de               ; HL = DE (record start) + record size = next record

    ; Check the candidate next pointer against PROG_END. Push/pop HL
    ; around the comparison so the candidate value survives (SBC HL,DE
    ; overwrites HL with the subtraction result — we only want its
    ; flags, not the result itself, so the original candidate is
    ; restored before returning it).
    push hl
    ld   de, (PROG_END)
    or   a
    sbc  hl, de               ; carry set means candidate < PROG_END
    pop  hl
    ret  c                    ; valid next statement — return candidate as-is
    ld   hl, 0                ; candidate >= PROG_END — no next statement
    ret

; ============================================================================
; MEM_LABEL_FIND (internal — not declared in kernel_api.inc)
; Shared scan logic for MEM_LABEL_LOOKUP and MEM_LABEL_REMOVE — both need
; to locate an entry by name, they just need different things back from
; it (LOOKUP wants the stored position; REMOVE wants to know where the
; entry starts and how big it is, to shift the gap closed). Written once
; here rather than duplicated in both callers.
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
    ; exactly on the position field — discard the saved value, nothing
    ; more to undo.
    pop  de
.match:
    or   a                        ; clear carry: found
    ret

.compare_fail:
    pop  hl                       ; HL restored = entry name start
    ; fall through — HL and C are now in the same state as the
    ; length-mismatch path below, so one skip_entry serves both
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
; Looks up a label by name in the top-level scope's table (see format
; note above this file's header). Thin wrapper around MEM_LABEL_FIND.
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
; name already exists in that scope (see docs/basic_language_reference.md,
; "Scope" — a label must be unique within its enclosing scope) or if the
; table is full (LABEL_TABLE_MAXLEN, see sysvars.inc).
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
                                      ; wrap to 256 iterations, same class
                                      ; of Z80 gotcha as LDIR/LDDR's BC=0
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
; MEM_LABEL_REMOVE
; Removes a label from the top-level scope's table by name.
; In:  HL = pointer to name, B = name length
; Out: carry clear on success; carry set if the name wasn't found
; Destroys: AF, BC, DE, HL
; ============================================================================
MEM_LABEL_REMOVE:
    call MEM_LABEL_FIND
    ret  c                          ; not found

    ; HL = position-field-start, C = name_len. entry_start = HL - C - 1.
    ld   a, c
    ld   e, a
    ld   d, 0
    or   a
    sbc  hl, de
    dec  hl
    ld   (REMOVE_ENTRY_START), hl

    ld   a, c
    add  a, 3
    ld   (REMOVE_ENTRY_SIZE), a

    ld   hl, (REMOVE_ENTRY_START)
    ld   a, (REMOVE_ENTRY_SIZE)
    ld   e, a
    ld   d, 0
    add  hl, de                      ; HL = block_start = entry_start + entry_size
    ld   (REMOVE_BLOCK_START), hl

    ld   hl, (REMOVE_ENTRY_START)
    ld   de, LABEL_TABLE_TOP
    or   a
    sbc  hl, de                       ; HL = entry_offset (from table base)

    ex   de, hl                        ; DE = entry_offset
    ld   hl, (LABEL_TABLE_USED)
    or   a
    sbc  hl, de                         ; HL = used - entry_offset
    ld   a, (REMOVE_ENTRY_SIZE)
    ld   e, a
    ld   d, 0
    or   a
    sbc  hl, de                          ; HL -= entry_size -> block_length
    ld   (REMOVE_BLOCK_LEN), hl

    ld   hl, (REMOVE_BLOCK_START)
    ld   bc, (REMOVE_BLOCK_LEN)
    ld   a, (REMOVE_ENTRY_SIZE)
    ld   e, a
    ld   d, 0
    call MEM_SHIFT_DOWN

    ld   hl, (LABEL_TABLE_USED)
    ld   a, (REMOVE_ENTRY_SIZE)
    ld   e, a
    ld   d, 0
    or   a
    sbc  hl, de
    ld   (LABEL_TABLE_USED), hl

    ld   hl, (LABEL_TABLE_TOP)
    dec  hl
    ld   (LABEL_TABLE_TOP), hl

    or   a
    ret

; ============================================================================
; MEM_LINE_STORE
; Replaces the statement at a given program position with new text
; (deletes the old statement's bytes, inserts the new ones) — this is
; what EDITOR_EXIT calls to commit an edited line back to the program
; area. Position, not line number, since there are no line numbers.
; In:  HL = program position to replace, DE = pointer to new statement
;      text (length-prefixed, per the format above)
; Out: carry clear on success; carry set if the program area is full
; Destroys: AF, BC, DE, HL
; ============================================================================

; ============================================================================
; MEM_FITS_CHECK
; Shared bounds check used by MEM_LABEL_ADD/MEM_LINE_STORE/MEM_LINE_
; INSERT below: is a projected total within some maximum, inclusive?
; In:  HL = projected total, DE = maximum allowed
; Out: carry clear if HL <= DE (fits); carry set if HL > DE (doesn't)
; Destroys: AF, HL
; ============================================================================
MEM_FITS_CHECK:
    or   a
    sbc  hl, de
    jr   c, .ok
    jr   z, .ok
    scf
    ret
.ok:
    or   a
    ret

; ============================================================================
; MEM_BLOCK_LEN_TO_END
; Shared first step for MEM_LINE_STORE/MEM_LINE_INSERT below: the byte
; count from STORE_POSITION to PROG_END (the "everything after this
; position" block length each one needs, for a different next step).
; In:  none (reads PROG_END, STORE_POSITION)
; Out: HL = PROG_END - STORE_POSITION
; Destroys: AF, DE
; ============================================================================
MEM_BLOCK_LEN_TO_END:
    ld   hl, (PROG_END)
    ld   de, (STORE_POSITION)
    or   a
    sbc  hl, de
    ret

; ============================================================================
; MEM_READ_STORE_NEW_LEN
; Shared step for MEM_LINE_STORE/MEM_LINE_INSERT below: reads the new
; statement's own content-length prefix (the first 2 bytes at
; STORE_NEW_PTR) into STORE_NEW_LEN.
; In:  none (reads STORE_NEW_PTR)
; Out: DE = STORE_NEW_LEN (also stored back to that sysvar)
; Destroys: HL
; ============================================================================
MEM_READ_STORE_NEW_LEN:
    ld   hl, (STORE_NEW_PTR)
    ld   e, (hl)
    inc  hl
    ld   d, (hl)
    ld   (STORE_NEW_LEN), de
    ret

; ============================================================================
; MEM_COPY_NEW_STMT
; Shared step for MEM_LINE_STORE/MEM_LINE_INSERT below: copies the new
; statement's bytes (STORE_NEW_TOTAL of them, from STORE_NEW_PTR) into
; the gap already opened at STORE_POSITION.
; In:  none (reads STORE_NEW_PTR, STORE_POSITION, STORE_NEW_TOTAL)
; Out: none
; Destroys: AF, BC, DE, HL
; ============================================================================
MEM_COPY_NEW_STMT:
    ld   hl, (STORE_NEW_PTR)
    ld   de, (STORE_POSITION)
    ld   bc, (STORE_NEW_TOTAL)
    ldir
    ret

MEM_LINE_STORE:
    ld   (STORE_POSITION), hl
    ld   (STORE_NEW_PTR), de

    ; Check whether an existing statement really is at this position,
    ; or whether position == PROG_END (appending into an empty program,
    ; or past the last statement) — in which case there is NOTHING
    ; there yet, and reading a "length field" would read uninitialized/
    ; garbage RAM. This distinction was missing from the original
    ; implementation: it always read 2 bytes at the given position as
    ; "the old statement's length," unconditionally. That's correct
    ; when replacing an existing statement, but the very first time
    ; this routine is ever used to store into a genuinely empty program
    ; (position == PROG_AREA_START == PROG_END, before anything has
    ; been written there), those 2 bytes are garbage, and every
    ; downstream shift/copy computed from that garbage corrupted
    ; memory in ways that showed up as misplaced text and corrupted
    ; screen attributes several rows away — caught via integration
    ; testing (rom/test_basic.asm actually storing a first statement),
    ; not by rom/test_memory.asm's own test, which only ever exercised
    ; replacing an EXISTING statement, never inserting into empty space.
    call MEM_BLOCK_LEN_TO_END
    jr   z, .no_existing              ; position == PROG_END
    jr   c, .no_existing               ; defensive: position > PROG_END
                                       ; shouldn't happen, but treat the
                                       ; same way rather than read garbage

    ; --- an existing statement really is here: read its length ---
    ld   hl, (STORE_POSITION)
    ld   e, (hl)
    inc  hl
    ld   d, (hl)
    ld   (STORE_OLD_LEN), de
    ld   hl, (STORE_OLD_LEN)
    ld   bc, LINE_LEN_SIZE
    add  hl, bc
    ld   (STORE_OLD_TOTAL), hl          ; old_total = old_len + 2
    jr   .have_old_total

.no_existing:
    ld   hl, 0
    ld   (STORE_OLD_LEN), hl
    ld   (STORE_OLD_TOTAL), hl            ; old_total = 0 — genuinely
                                         ; nothing to remove, NOT "a
                                         ; 2-byte header for an empty
                                         ; statement" (that was the bug)

.have_old_total:
    call MEM_READ_STORE_NEW_LEN

    ; Space check: projected PROG_END = PROG_END + new_len - old_len
    ; (the +2/-2 length-field bytes cancel out). Ceiling is VARS_START
    ; (the scalar pool's own high-water mark), not the fixed PROG_AREA_
    ; MAX — scalars can occupy that upper space too now, see sysvars.
    ; inc's own VARS_START header for the two-ended-pool design.
    ld   hl, (PROG_END)
    ld   de, (STORE_NEW_LEN)
    add  hl, de
    ld   de, (STORE_OLD_LEN)
    or   a
    sbc  hl, de
    ld   de, (VARS_START)
    call MEM_FITS_CHECK
    ret  c

    ; old_total was already computed above (either old_len+2, or
    ; genuinely 0 if nothing existed at this position) — not
    ; recomputed here. Recomputing it from a zeroed STORE_OLD_LEN would
    ; wrongly give 2 instead of 0, which was exactly the bug this fix
    ; addresses.

    ; Step A — remove the old statement: shift everything after it down
    ; by old_total, closing the gap. A genuine no-op when old_total=0
    ; (appending fresh), via MEM_SHIFT_DOWN's own BC=0 guard.
    ld   hl, (STORE_POSITION)
    ld   de, (STORE_OLD_TOTAL)
    add  hl, de
    ld   (STORE_BLOCK_START), hl       ; block_start = position + old_total

    ld   hl, (PROG_END)
    ld   de, (STORE_BLOCK_START)
    or   a
    sbc  hl, de
    ld   (STORE_BLOCK_LEN), hl          ; block_len = PROG_END - block_start

    ld   hl, (STORE_BLOCK_START)
    ld   bc, (STORE_BLOCK_LEN)
    ld   de, (STORE_OLD_TOTAL)
    call MEM_SHIFT_DOWN

    ld   hl, (PROG_END)
    ld   de, (STORE_OLD_TOTAL)
    or   a
    sbc  hl, de
    ld   (PROG_END), hl                  ; PROG_END -= old_total

    ; Step B — insert the new statement at STORE_POSITION, which is now
    ; exactly where the old statement used to start (everything after it
    ; has already been shifted down to close that gap).
    ld   hl, (STORE_NEW_LEN)
    ld   bc, LINE_LEN_SIZE
    add  hl, bc
    ld   (STORE_NEW_TOTAL), hl            ; new_total = new_len + 2

    call MEM_BLOCK_LEN_TO_END
    ld   (STORE_BLOCK_LEN), hl             ; reuse: block_len for the
                                          ; upward shift = PROG_END - position

    ld   hl, (STORE_POSITION)
    ld   bc, (STORE_BLOCK_LEN)
    ld   de, (STORE_NEW_TOTAL)
    call MEM_SHIFT_UP

    call MEM_COPY_NEW_STMT                 ; copy the new statement's
                                          ; bytes into the opened gap

    ld   hl, (PROG_END)
    ld   de, (STORE_NEW_TOTAL)
    add  hl, de
    ld   (PROG_END), hl

    or   a
    ret

; ============================================================================
; MEM_LINE_INSERT
; Inserts a NEW statement at the given position, shifting whatever's
; already there (and everything after it) later to make room — unlike
; MEM_LINE_STORE, which always treats the given position as "the old
; statement to replace," this never removes anything. Built on
; MEM_SHIFT_UP (already tested), which does the actual byte-moving;
; this routine just computes how much to shift and copies the new
; statement into the gap that opens up.
;
; Hand-traced: inserting a 7-byte "y=10" record before an existing
; "PRINT x" at $6006 (with "x=5" unchanged at $6000, PROG_END=$6010) —
; block_len (bytes to shift) = PROG_END - position = 10, exactly
; "PRINT x"'s own record size; after MEM_SHIFT_UP opens the gap and the
; new record is copied in, "y=10" occupies $6006-$600C and "PRINT x"
; has moved to $600D-$6016, with PROG_END now $6017 — verified
; numerically before writing this, not just by inspection.
;
; Reuses MEM_LINE_STORE's scratch variables (STORE_POSITION,
; STORE_NEW_PTR, etc.) rather than declaring separate ones — the two
; routines never run concurrently, so there's no conflict, and it
; avoids growing sysvars.inc for state that's already there.
; In:  HL = position to insert at (an existing statement's start; for
;      appending past the end of the program, use MEM_LINE_STORE
;      directly instead — it already handles that case correctly and
;      doesn't need a shift at all)
;      DE = pointer to the new statement's bytes
;      ([length:2][content][terminator])
; Out: carry set if it doesn't fit (PROG_END would exceed VARS_START,
;      the scalar pool's own high-water mark — see sysvars.inc's own
;      header for why that's the real ceiling now, not PROG_AREA_MAX);
;      carry clear on success, PROG_END updated
; Destroys: AF, BC, DE, HL
; ============================================================================
MEM_LINE_INSERT:
    ld   (STORE_POSITION), hl
    ld   (STORE_NEW_PTR), de

    call MEM_READ_STORE_NEW_LEN            ; new statement's content length

    ld   hl, (STORE_NEW_LEN)
    ld   bc, LINE_LEN_SIZE
    add  hl, bc
    ld   (STORE_NEW_TOTAL), hl              ; new_total = new_len + 2

    ; space check: PROG_END + new_total <= VARS_START
    ld   hl, (PROG_END)
    ld   de, (STORE_NEW_TOTAL)
    add  hl, de
    ld   de, (VARS_START)
    call MEM_FITS_CHECK
    ret  c

    ; block to shift = everything from position to PROG_END
    call MEM_BLOCK_LEN_TO_END
    ld   b, h
    ld   c, l                          ; BC = block_len

    ld   hl, (STORE_POSITION)
    ld   de, (STORE_NEW_TOTAL)
    call MEM_SHIFT_UP                    ; opens a gap of new_total bytes
                                        ; at position — HL/BC/DE all
                                        ; destroyed by this call, per
                                        ; its own contract, but nothing
                                        ; from before is needed anymore
                                        ; since it's all safely in
                                        ; memory (STORE_* vars)

    ; copy the new statement into the gap
    call MEM_COPY_NEW_STMT

    ; PROG_END += new_total
    ld   hl, (PROG_END)
    ld   de, (STORE_NEW_TOTAL)
    add  hl, de
    ld   (PROG_END), hl

    or   a
    ret

; ============================================================================
; MEM_LINE_DELETE_RANGE
; Deletes every statement between two program positions (inclusive).
; Backs EDITOR_BLOCK_DELETE — but NOT the dangling-label-reference check;
; see this file's header for why that's basic/'s job, not this routine's.
; In:  HL = first position, DE = last position (the START of the LAST
;      statement in the range, not one-past-the-end)
; Out: carry clear on success
; Destroys: AF, BC, DE, HL
; ============================================================================
MEM_LINE_DELETE_RANGE:
    ld   (DELRANGE_FIRST), hl
    ld   (DELRANGE_LAST_START), de

    ld   hl, (DELRANGE_LAST_START)
    ld   e, (hl)
    inc  hl
    ld   d, (hl)
    ld   (DELRANGE_LAST_LEN), de

    ld   hl, (DELRANGE_LAST_START)
    ld   de, (DELRANGE_LAST_LEN)
    add  hl, de
    ld   de, LINE_LEN_SIZE
    add  hl, de
    ld   (DELRANGE_LAST_END), hl          ; one past the last byte in range

    ld   hl, (DELRANGE_LAST_END)
    ld   de, (DELRANGE_FIRST)
    or   a
    sbc  hl, de
    ld   (DELRANGE_TOTAL_LEN), hl          ; total bytes being removed

    ld   hl, (PROG_END)
    ld   de, (DELRANGE_LAST_END)
    or   a
    sbc  hl, de
    ld   (DELRANGE_BLOCK_LEN), hl           ; bytes after the deleted range

    ld   hl, (DELRANGE_LAST_END)
    ld   bc, (DELRANGE_BLOCK_LEN)
    ld   de, (DELRANGE_TOTAL_LEN)
    call MEM_SHIFT_DOWN

    ld   hl, (PROG_END)
    ld   de, (DELRANGE_TOTAL_LEN)
    or   a
    sbc  hl, de
    ld   (PROG_END), hl

    or   a
    ret

; ============================================================================
; MEM_FREE_BYTES
; Bytes still free between the two ends of the dynamic pool — VARS_
; START (the scalar-variable pool's own high-water mark, growing DOWN
; from PROG_AREA_MAX — see sysvars.inc's own header for the full two-
; ended-pool design) minus ARRAYS_END. ARRAYS_END tracks PROG_END
; exactly (== PROG_END) whenever no arrays are currently DIM'd, and
; grows past it as they are; VARS_START tracks PROG_AREA_MAX exactly
; whenever no scalars exist yet, and shrinks below it as they're
; created. So this one subtraction correctly reports plain "room left
; for more program text" when nothing else has claimed any of this
; region, and the array-and-scalar-aware number once some of each
; exist, with no branch needed either way. Backs BASIC's FREE().
; In:  none
; Out: HL = free bytes
; Destroys: AF, HL, DE
; ============================================================================
MEM_FREE_BYTES:
    ld   hl, (VARS_START)
    ld   de, (ARRAYS_END)
    or   a
    sbc  hl, de
    ret
