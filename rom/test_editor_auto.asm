; ============================================================================
; rom/test_editor_auto.asm — AUTOMATED (non-interactive) editor/typing
; regression test
;
; WHY THIS EXISTS: the two real bugs found this session ("only the first
; character of a typed line ever rendered", "cursor stuck at a fixed
; column on a wrapped line") both lived specifically in the Home<->EXROM
; boundary code kernel/editor's word-wrap machinery crosses on every
; keystroke (rom/exrom_editor.asm's EDITOR_WRAP_TABLE_ADDR/EDITOR_WRAP_
; OFFSET_TO_ROWCOL, called through basic/basic.asm's BASIC_EDITOR_WRAP_
; *_EXROM wrappers). Neither rom/test_editor.asm (real-keyboard
; interactive, never actually run against real hardware per its own
; header) nor kernel/editor/editor.asm's standalone Home-only copy
; (bypasses the EXROM boundary entirely — same-file `call`, no
; trampoline/register-survival risk at all) would have caught either
; bug. This harness drives the REAL, unmodified, shipped exrom.bin
; through that exact boundary, with no keyboard/X11/human involved —
; per-the-user's own instruction to stop using synthetic X11 keystrokes
; for testing (2026-08-22ish, this session).
;
; TECHNIQUE: kernel/io's IO_READ_KEY (kernel/io/io.asm) is a thin
; consumer of two ISR-latched sysvars, KBD_LASTK/KBD_KEYHIT (see that
; sysvar's own comment in include/sysvars.inc — "owned/written only by
; KBD_ISR_TICK... to avoid a race against the ISR"). Real hardware sets
; those from kernel/interrupt's KBD_ISR_TICK, called from RST_38 every
; timer tick. This harness REPLACES RST_38's target with its own tiny
; injector (TEST_KEY_INJECT_TICK below) that writes the SAME two
; sysvars from a queue instead of a real matrix scan — becoming the
; session's sole writer, same single-writer invariant the real ISR
; already relies on, just substituted whole rather than raced against.
; EDITOR_ENTER/EDITOR_LOOP (rom/exrom_editor.asm) and everything they
; call run 100% unmodified, through the real KTAB boundary, exactly as
; a human typing would drive them.
;
; The queue itself (TEST_KEY_QUEUE, $F010) is Fuse-debugger-injected
; RAM, not compile-time ROM data (2026-08-23 — see "ROM budget" below):
; INJECT_POINT (COLD_START) is a stable breakpoint address a generated
; .dbg script pokes bytes into before real execution resumes, same
; natural-pause-point technique tools/fuse_suite_inject.py already
; uses for the general regression suite. Without a .dbg script
; attached, this harness doesn't produce a meaningful result — it was
; never meant to run standalone, same caveat tools/fuse_load_inject.py's
; own CHECK_HARNESS_TEMPLATE already documents for its equivalent.
;
; This harness calls BASIC_COMMAND_LOOP (basic/basic.asm) directly —
; not a hand-rolled shortcut — since that routine's own defensive
; cold-boot init (CUR_EDIT_POS, CUR_EDIT_INDEX, VIEW_TOP_INDEX,
; CALC_SP, etc., see its own comments just above its `.loop:` label) is
; real and non-trivial; reusing it whole avoids silently omitting a
; step a hand-rolled init might miss. BASIC_COMMAND_LOOP never returns
; (by design — see its own file header), so verification happens from
; INSIDE the injector once the key queue is fully drained AND the last
; injected key has actually been consumed (KBD_KEYHIT back to 0) —
; the moment EDITOR_LOOP itself will be sitting parked in IO_READ_KEY's
; busy-wait with EDIT_LINE_BUF/EDIT_BUF_OFFSET in their final, stable
; state. This is why the test's key queue deliberately never includes
; KEY_ENTER: an ENTER would commit the line and let BASIC_COMMAND_LOOP
; race ahead to its next loop iteration (which re-zeroes EDIT_LINE_BUF
; via BASIC_EDITOR_INIT_EXROM) before this harness's own verification
; ever got a chance to read it — parking mid-edit instead sidesteps
; that race entirely.
;
; TEST CASE: types 33 'A' characters (queue injected via a Fuse .dbg
; script poking TEST_KEY_QUEUE, mirroring tools/fuse_suite_inject.py's
; approach — no such script exists yet as of 2026-08-23; building one
; is pointless until the ROM-budget gap below is closed, see "ROM
; budget" note further down) — one more than one screen row's
; 32-column width, with no space anywhere for word-wrap to break on,
; forcing EDITOR_WRAP_CALC's hard-break-at-column-32 path
; (rom/exrom_editor.asm's own EDITOR_WRAP_CALC, `.hard_break`).
; Verifies two things against the REAL production call path:
;   1. EDIT_LINE_BUF holds exactly 33 'A's + a null terminator — catches
;      any character silently dropped or duplicated during insert+
;      redraw (the exact symptom of the first bug found this session,
;      even though that bug's actual root cause was in the DISPLAY
;      path, not insertion itself — this is cheap insurance either way).
;   2. BASIC_EDITOR_WRAP_OFFSET_TO_ROWCOL_EXROM — the real Home-side
;      wrapper crossing the real EXROM boundary, same one basic/'s own
;      cursor-drawing code calls (see basic/basic.asm's BASIC_REDRAW_
;      PROGRAM `.draw_cursor`) — returns row=1, col=1 for offset 33.
;      Reuses EDIT_WRAP_START/LEN/COUNT exactly as the last real
;      keystroke's own redraw (via the BASIC_REDRAW_PROGRAM hook) left
;      them, rather than re-running EDITOR_WRAP_CALC a second time —
;      those tables are already fresh, nothing invalidated them since.
;      Hand-computed from EDITOR_WRAP_CALC's own documented algorithm:
;      33 chars, no spaces, row 0 hard-breaks at column 32 (content len
;      32, consumed 32), remaining 1 char is the whole of row 1 (last
;      row: content len=remaining=1) — so buffer offset 33 (one past
;      the last typed char) falls in row 1 at column 1. This is a
;      DIRECT regression check on EDITOR_WRAP_OFFSET_TO_ROWCOL
;      specifically, the exact routine the "cursor stuck at column 13"
;      bug lived in.
;
; Border verdict: green (BORDER_DEFAULT-style pass color) = both checks
; passed; red = at least one failed. Session stays parked forever
; afterward (EDITOR_LOOP's own busy-wait) — this is the DONE state, not
; a hang, same as this project's other interactive test binaries that
; end in a deliberate hold.
;
; ROM budget: this file's own extra content (TEST_KEY_INJECT_TICK,
; TEST_VERIFY, COLD_START's own init lines) still has to fit on top of
; basic/basic.asm's own budget, same as rom/test_basic.asm — that
; budget is razor-thin after the Phase 4 dynamic-scalar-pool migration
; (docs/programmers_reference.md), down to low single-digit bytes free.
; Moving TEST_KEY_QUEUE's 34 bytes of data out to injected RAM
; (2026-08-23) was necessary but not sufficient by itself; TEST_VERIFY
; stays in ROM (see file header's own "no host-file-write primitive"
; reasoning, tools/fuse_load_inject.py) since a visible border signal
; is the only proven output channel back to the host.
;
; Build:
;   sjasmplus rom/exrom_build.asm        (REQUIRED first — this harness
;                                         links against the real,
;                                         unmodified exrom.bin)
;   sjasmplus rom/test_editor_auto.asm --sym=rom/test_editor_auto.sym
; Run: NOT YET RUNNABLE (2026-08-23) — see "ROM budget" above; this
; harness currently fails to assemble within Home ROM's 16K. Once a
; basic.asm size-audit closes the gap, run needs a Fuse debugger
; script poking TEST_KEY_QUEUE at INJECT_POINT (no such script or
; wrapper exists yet — build one mirroring tools/fuse_suite_inject.py/
; tools/run_suite_test.sh once this actually assembles):
;   fuse --machine ts2068 --rom-ts2068-0 test_editor_auto.bin \
;        --rom-ts2068-1 exrom.bin --debugger-command "$(cat X.dbg)"
; ============================================================================

    INCLUDE "include/hardware.inc"
    INCLUDE "include/sysvars.inc"
    INCLUDE "include/keys.inc"

    DEVICE NOSLOT64K
    ORG $0000

RST_00:
    di
    jp   COLD_START
    DS   $0038 - $, $FF

; ---- RST 38 / IM 1 — replaced with the synthetic key injector instead
; of kernel/interrupt's real KBD_ISR_TICK (see file header). ----
RST_38:
    call TEST_KEY_INJECT_TICK
    ei
    reti

    DEFINE EXROM_JUMPTABLE_HOME_SIDE
    INCLUDE "include/exrom_jumptable.inc"
    ORG  KTAB_BASE
    KTAB_LIST
    ASSERT $ <= KTAB_END
    DB   KTAB_MAGIC

    DS   $0100 - $, $FF

COLD_START:
    ld   sp, $FF00

    call MEM_INIT

    xor  a
    ld   (KBD_LASTK), a
    ld   (KBD_KEYHIT), a
    ld   (TEST_VERIFIED_FLAG), a
    ld   hl, TEST_KEY_QUEUE
    ld   (TEST_QUEUE_POS), hl

INJECT_POINT:
    ; Fuse breaks here (stable label address, read via --sym) and pokes
    ; the key queue's bytes at TEST_KEY_QUEUE before real execution
    ; continues into `ei` below — same natural-pause-point injection
    ; tools/fuse_suite_inject.py already uses, no PC redirection or
    ; stack surgery needed. If no .dbg script is attached, TEST_KEY_
    ; QUEUE's first byte is whatever RAM happened to power on with (not
    ; guaranteed 0) — this harness was never meant to run standalone.
    im   1
    ei

    call BASIC_COMMAND_LOOP          ; never returns — see file header;
                                     ; verification happens from inside
                                     ; TEST_KEY_INJECT_TICK once the
                                     ; queue drains

; ============================================================================
; TEST_KEY_INJECT_TICK
; Replaces kernel/interrupt's KBD_ISR_TICK for this harness only (see
; file header for the full design). Every tick: if the queue's next
; byte is the 0 sentinel AND the previous injected key has already been
; consumed (KBD_KEYHIT==0) AND verification hasn't run yet, run it once
; — this is the moment EDITOR_LOOP is guaranteed parked in IO_READ_KEY's
; busy-wait with EDIT_LINE_BUF/EDIT_BUF_OFFSET stable (see header for
; why no ENTER is ever queued). Otherwise, inject the next queued key
; exactly like the real ISR would (only when the previous one has been
; consumed — same pacing discipline, one key per "previous one already
; read").
; ============================================================================
TEST_KEY_INJECT_TICK:
    push af
    push hl

    ld   a, (TEST_VERIFIED_FLAG)
    or   a
    jr   nz, .maybe_inject

    ld   hl, (TEST_QUEUE_POS)
    ld   a, (hl)
    or   a
    jr   nz, .maybe_inject          ; queue not drained yet

    ld   a, (KBD_KEYHIT)
    or   a
    jr   nz, .maybe_inject          ; last injected key not consumed yet

    call TEST_VERIFY
    ld   a, 1
    ld   (TEST_VERIFIED_FLAG), a

.maybe_inject:
    ld   a, (KBD_KEYHIT)
    or   a
    jr   nz, .done                  ; previous key still unconsumed

    ld   hl, (TEST_QUEUE_POS)
    ld   a, (hl)
    or   a
    jr   z, .done                   ; queue drained, nothing to inject

    ld   (KBD_LASTK), a
    ld   a, $FF
    ld   (KBD_KEYHIT), a
    ld   hl, (TEST_QUEUE_POS)
    inc  hl
    ld   (TEST_QUEUE_POS), hl

.done:
    pop  hl
    pop  af
    ret

; ============================================================================
; TEST_VERIFY
; The two checks described in this file's header. Sets BORDER
; green/red. Destroys AF, BC, DE, HL — safe, this only ever runs once,
; from inside the injector, with the caller (TEST_KEY_INJECT_TICK)
; itself already saving/restoring its own AF/HL around the call.
; ============================================================================
TEST_VERIFY:
    ; Check 1: EDIT_LINE_BUF == 33 'A' + null
    ld   hl, EDIT_LINE_BUF
    ld   b, 33
.check_loop:
    ld   a, (hl)
    cp   "A"
    jr   nz, .fail
    inc  hl
    djnz .check_loop
    ld   a, (hl)
    or   a
    jr   nz, .fail

    ; Check 2: the real production wrap/rowcol call path (see basic/
    ; basic.asm's BASIC_REDRAW_PROGRAM .draw_cursor) returns row=1,
    ; col=1 for offset 33 — EDIT_WRAP_START/LEN/COUNT are already
    ; fresh from the last real keystroke's own redraw, no need to
    ; re-run EDITOR_WRAP_CALC here
    call BASIC_EDITOR_WRAP_OFFSET_TO_ROWCOL_EXROM   ; B=row, C=col
    ld   a, b
    cp   1
    jr   nz, .fail
    ld   a, c
    cp   1
    jr   nz, .fail

    ld   a, 4                        ; green — both checks passed
    out  (PORT_ULA), a
    ret

.fail:
    ld   a, 2                        ; red — at least one check failed
    out  (PORT_ULA), a
    ret

    INCLUDE "basic/basic.asm"
    INCLUDE "kernel/memory/memory.asm"
    INCLUDE "kernel/io/io.asm"
    INCLUDE "kernel/graphics/graphics.asm"
    INCLUDE "kernel/math/math.asm"
    INCLUDE "kernel/sound/sound.asm"
    INCLUDE "kernel/interrupt/interrupt.asm"   ; unused (KBD_ISR_TICK/
                                               ; INIT dead code here,
                                               ; RST_38 points at TEST_
                                               ; KEY_INJECT_TICK instead)
                                               ; — included only because
                                               ; basic.asm's BASIC_STMT_
                                               ; PAUSE calls INT_GET_
                                               ; FRAMES directly by label
    INCLUDE "kernel/bank/bank.asm"

    DS   $4000 - $, $FF

    SAVEBIN "test_editor_auto.bin", $0000, $4000

; ---- test-harness-only scratch RAM: chunk 7 ($E000-$FFFF), well clear
; of both the machine stack (SP=$FF00, ~4K of headroom below it) and
; chunk 6 (paged to EXROM for the whole session — writing test scratch
; there would be inaccessible while paged in). NOT in include/
; sysvars.inc on purpose: this is test-harness-only state, not a real
; product sysvar, and must never compete with PROG_AREA_START's own
; zero-slack budget. ----
TEST_QUEUE_POS      EQU $F000   ; 2 bytes
TEST_VERIFIED_FLAG  EQU $F002   ; 1 byte
TEST_KEY_QUEUE       EQU $F010   ; 64 bytes — Fuse-debugger-injected
                                ; (2026-08-23, see file header's own
                                ; "ROM budget" note); was a compile-time
                                ; DB block living directly in the ROM
                                ; image, moved to RAM for the same
                                ; reason tools/fuse_suite_inject.py's
                                ; own header explains at length. 64
                                ; bytes is generous headroom over the
                                ; 34 this test case actually uses.
