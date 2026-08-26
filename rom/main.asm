; ============================================================================
; rom/main.asm — Milestone 0 boot stub
;
; Purpose: prove the ORG $0000 layout, RST vector table, and stack init are
; correct on real/emulated TS2068 hardware, BEFORE any of the real kernel
; (memory, io text output, editor) exists. Deliberately does not depend on
; screen text output or fonts — neither exists yet — so the only thing this
; can fail on is the boot chain itself, not something built later.
;
; Smoke test: the border colour cycles through all 8 values in a loop. If
; you see that in Fuse (or on real hardware), the vector table and stack
; init below are sound and it's safe to build kernel/io text output on top
; of this file. If you see nothing (blank/frozen screen), the bug is here,
; not in something more complex layered on top later.
;
; NOT YET FULLY VERIFIED ON REAL HARDWARE OR IN AN EMULATOR — assembles
; cleanly under sjasmplus 1.23.1 as of the DEVICE fix below, but hasn't
; been run in Fuse yet. Treat the border-cycle behaviour as reviewed-by-
; eye only until confirmed.
;
; Build:
;   sjasmplus rom/main.asm
;   (produces rom0.bin per the SAVEBIN line at the end of this file)
;
; Run:
;   fuse --machine ts2068 --rom-ts2068-0 rom0.bin --rom-ts2068-1 <placeholder>
;   (rom0.bin is 16K — Fuse itself confirmed this; see docs/memory_map.md.
;   ROM1 doesn't matter yet — kernel/sound and the extended kernel routines
;   that will eventually live there don't exist. Any 8K placeholder file
;   is fine for --rom-ts2068-1 for now, though its exact required size
;   hasn't been confirmed against Fuse the way ROM0's has.)
; ============================================================================

    INCLUDE "include/hardware.inc"

    DEVICE NOSLOT64K        ; plain 64K address space, no memory-mapped
                            ; hardware model — required by sjasmplus before
                            ; SAVEBIN can be used (see end of this file)

    ORG $0000

; ---- RST 00: cold start ----
RST_00:
    di
    jp   COLD_START

    DS   $0008 - $, $FF
RST_08:
    ret                     ; TODO: unallocated — reserve for kernel/memory
                            ; or kernel/io once one of them wants a fast
                            ; RST-callable entry point here.

    DS   $0010 - $, $FF
RST_10:
    ret                     ; TODO: unallocated, see RST_08 note.

    DS   $0018 - $, $FF
RST_18:
    ret                     ; TODO: unallocated, see RST_08 note.

    DS   $0020 - $, $FF
RST_20:
    ret                     ; TODO: unallocated, see RST_08 note.

    DS   $0028 - $, $FF
RST_28:
    ; Calculator engine entry point (matches the real Spectrum ROM's own
    ; RST $28 convention). MUST be a bare `jp`, not `call`: RST pushed
    ; the byte immediately after this instruction (the literal-op stream
    ; that follows every RST $28 call site) as the return address, and
    ; CALC_ENTRY_TRAMPOLINE/the calculator itself need that exact value
    ; sitting untouched on top of the stack — a `call` here would push a
    ; second address on top of it and corrupt the mechanism. See basic/
    ; basic.asm's CALC_ENTRY_TRAMPOLINE header for the full chain.
    jp   CALC_ENTRY_TRAMPOLINE

    DS   $0030 - $, $FF
RST_30:
    ret                     ; TODO: unallocated, see RST_08 note.

    DS   $0038 - $, $FF
; ---- RST 38 / IM 1 maskable interrupt entry point ----
RST_38:
    ei
    ret                     ; TODO(kernel/interrupt, not yet written): this
                            ; stub is never actually reached in this
                            ; milestone, since COLD_START below never
                            ; executes EI — interrupts stay masked for the
                            ; whole boot-stub smoke test on purpose, to keep
                            ; this file's only failure mode the vector
                            ; table/stack init, not interrupt timing too.

    DS   $0066 - $, $FF
; ---- NMI entry point ----
NMI_ENTRY:
    retn                    ; TODO: confirm TS2068-specific NMI behaviour
                            ; (e.g. any RESET-button wiring) before relying
                            ; on this — currently just a safe no-op return.

    DS   $0100 - $, $FF     ; leave the low page clear of code past the
                            ; fixed vectors, matching convention on
                            ; Spectrum-family ROMs this one is descended from

; ============================================================================
; COLD_START
; Entry point after reset. Sets up the stack, then runs the border-cycle
; smoke test. Nothing here touches kernel/memory, kernel/io, or any other
; not-yet-written module — this milestone stands alone.
; ============================================================================
COLD_START:
    ; Placeholder stack pointer. docs/memory_map.md hasn't finalized the
    ; real BASIC-area/stack boundary yet (see its "Open questions" list),
    ; so this value is provisional — revisit once kernel/memory exists.
    ld   sp, $FF00

    ; Zero the border-cycle counter. RAM content is undefined at power-on
    ; (unlike a value baked into the ROM image), so this can't be skipped
    ; the way it could if BORDER_COUNTER lived in ROM — see the note on
    ; BORDER_COUNTER below for why it doesn't.
    xor  a
    ld   (BORDER_COUNTER), a

; ============================================================================
; BORDER_LOOP (smoke test — see file header)
; Cycles the border through all 8 colours with a crude delay between steps.
; No screen writes, no fonts, no interrupts: isolates the test to exactly
; the boot chain above.
; ============================================================================
BORDER_LOOP:
    ld   a, (BORDER_COUNTER)
    and  $07
    out  (PORT_ULA), a

    ld   hl, BORDER_COUNTER
    inc  (hl)

    ld   bc, $4000
DELAY_LOOP:
    dec  bc
    ld   a, b
    or   c
    jr   nz, DELAY_LOOP

    jr   BORDER_LOOP

; BORDER_COUNTER lives in RAM, not as DB data in this file. Everything in
; this file assembles into rom0.bin, i.e. the READ-ONLY $0000-$3FFF range
; — a counter defined here as ROM data can be read but INC (HL) writing
; the incremented value back would silently fail on real hardware (and
; any accurate emulator), leaving the border frozen at colour 0. This bit
; us once already; $8000 is an arbitrary scratch RAM address for this
; isolated milestone, not a real system-variable allocation — revisit
; once kernel/memory owns the real RAM map.
BORDER_COUNTER EQU $8000

    DS   $4000 - $, $FF     ; pad out to the full 16K ROM0 image Fuse expects
                            ; for --rom-ts2068-0 (confirmed by Fuse itself
                            ; rejecting an 8K file — corrects this project's
                            ; earlier "8K Home bank" assumption in
                            ; docs/memory_map.md, now also fixed there)

    SAVEBIN "rom0.bin", $0000, $4000
