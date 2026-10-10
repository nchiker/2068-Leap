; V2-native GRAPHICS (CPLOT/BLOCK/FRAME/INVERT) loadable package at the RAM ABI address.
    INCLUDE "include/hardware.inc"
    INCLUDE "include/v2_package_abi.inc"   ; R10.9: the ONLY HOME interface a package may use
    PKG_SVC_LIST
    PKG_CONST_LIST
    PKG_PIN_LIST
    DEVICE NOSLOT64K
    ORG EXTENSION_MODULE_BASE
    jp GRAPHICS_INSTALL
    INCLUDE "rom/ext_v2_graphics_module.asm"
V2_PACKAGE_GRAPHICS_END:
    ASSERT $ <= EXTENSION_MODULE_LIMIT
    SAVEBIN "build/v2_package_graphics.bin", EXTENSION_MODULE_BASE, V2_PACKAGE_GRAPHICS_END-EXTENSION_MODULE_BASE
