; V2-native GRAPHICS (CPLOT/BLOCK/FRAME/INVERT) loadable package at the RAM ABI address.
    INCLUDE "include/hardware.inc"
    DEFINE V2_COMPACT_SYSVARS   ; R10.7 P5: drop V1-only sysvars (see include/sysvars.inc)
    INCLUDE "include/sysvars.inc"
    INCLUDE "build/v2_crossbank.inc"
    DEVICE NOSLOT64K
    ORG EXTENSION_MODULE_BASE
    jp GRAPHICS_INSTALL
    INCLUDE "rom/ext_v2_graphics_module.asm"
V2_PACKAGE_GRAPHICS_END:
    ASSERT $ <= EXTENSION_MODULE_LIMIT
    SAVEBIN "build/v2_package_graphics.bin", EXTENSION_MODULE_BASE, V2_PACKAGE_GRAPHICS_END-EXTENSION_MODULE_BASE
