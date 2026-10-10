; V2-native MODE/ULAPLUS/PALETTE loadable package at the RAM ABI address.
    INCLUDE "include/hardware.inc"
    DEFINE V2_COMPACT_SYSVARS   ; R10.7 P5: drop V1-only sysvars (see include/sysvars.inc)
    INCLUDE "include/sysvars.inc"
    INCLUDE "build/v2_crossbank.inc"
    DEVICE NOSLOT64K
    ORG EXTENSION_MODULE_BASE
    jp MODE_INSTALL
    INCLUDE "rom/ext_mode_module.asm"
V2_PACKAGE_MODE_END:
    ASSERT $ <= EXTENSION_MODULE_LIMIT
    SAVEBIN "build/v2_package_mode.bin", EXTENSION_MODULE_BASE, V2_PACKAGE_MODE_END-EXTENSION_MODULE_BASE
