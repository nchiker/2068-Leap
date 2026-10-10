; rom/test_v2_graphics_module_ram.asm — assembles the real production
; GRAPHICS package (rom/ext_v2_graphics_module.asm) at a genuine RAM
; address, mirroring rom/v2_package_graphics.asm's own real placement
; (ORG EXTENSION_MODULE_BASE = $F400, inside loadable-package RAM).
;
; WHY THIS EXISTS: rom/test_v2_graphics_pixel.asm (the pixel-level
; validation test this file supports) cannot simply INCLUDE rom/ext_v2_
; graphics_module.asm inline the way other v2 test harnesses include their
; extension modules, because that module declares its own scratch state
; (GFX_G_XMIN etc.) as plain DB cells with no fixed address — correct for
; its real deployment (genuine RAM via rom/v2_package_graphics.asm), but
; if included directly into the shared test harness's HOME image, those
; same cells land somewhere in $0000-$3FFF, which is real, non-writable
; ROM on this project's own TS2068 memory model (V2_HOME_IMAGE_END=$4000).
; A write to such a cell silently fails, read back as 0 forever — this
; was found and root-caused during the R10.7 GRAPHICS pixel-level
; validation session (docs/v2/R10_7_CAPACITY_ARCHITECTURE_AUDIT.md's
; graphics-validation section has the full diagnosis) as a test-harness
; construction defect, not a GRAPHICS or VM defect.
;
; Fix: assemble the real module here, separately, at a genuine RAM address
; ($9000 — confirmed clear of CURRENT_INK/PAPER/OVER at $81CF-$81D3, the
; K-TAB program-text region at PROG_AREA_START=$8455 for this test's own
; tiny source lines, and V2_SOURCE_STAGE=$9455), producing a relocatable
; byte blob that tools/run_v2_graphics_pixel_test.sh then injects into a
; running ts2068-debug session via `mem-write` before the test's own
; TEST_CUSTOM_MAIN calls it — the same "load a package into RAM, then
; call it" shape the real production LOAD mechanism uses.
;
; The eight EQUs below are cross-bank constants (this module calls into
; EXT2_REGISTER/GFX_WRITE_PIXEL/VM_COMPUTE_PRINT_ATTR/VM_CLAMP_Y191, which
; live in the HOME test image assembled separately) extracted from that
; build's own .sym file — the exact role build/v2_crossbank.inc plays for
; the real package build (rom/v2_package_graphics.asm). tools/run_v2_
; graphics_pixel_test.sh regenerates this file's EQU block automatically
; from a fresh build before every run, so it can never silently drift.
;
    INCLUDE "build/smoke/graphics-pixel/crossbank.inc"
    DEVICE NOSLOT64K
    ORG $9000
    INCLUDE "rom/ext_v2_graphics_module.asm"
GRAPHICS_MODULE_RAM_END:
    SAVEBIN "build/smoke/graphics-pixel/module_ram.bin", $9000, GRAPHICS_MODULE_RAM_END-$9000
