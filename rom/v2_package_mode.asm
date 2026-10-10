; V2-native MODE/ULAPLUS/PALETTE loadable package at the RAM ABI address.
    INCLUDE "include/hardware.inc"
    INCLUDE "include/v2_package_abi.inc"   ; R10.9: the ONLY HOME interface a package may use
    PKG_SVC_LIST
    PKG_CONST_LIST
    PKG_PIN_LIST
    DEVICE NOSLOT64K
    ORG EXTENSION_MODULE_BASE
    jp MODE_INSTALL
    INCLUDE "rom/ext_mode_module.asm"
V2_PACKAGE_MODE_END:
    ASSERT $ <= EXTENSION_MODULE_LIMIT
    SAVEBIN "build/v2_package_mode.bin", EXTENSION_MODULE_BASE, V2_PACKAGE_MODE_END-EXTENSION_MODULE_BASE
