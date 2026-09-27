; V2-native sprite loadable package at the RAM ABI address.
    INCLUDE "include/hardware.inc"
    INCLUDE "include/sysvars.inc"
    INCLUDE "build/v2_crossbank.inc"
    DEVICE NOSLOT64K
    ORG EXTENSION_MODULE_BASE
    jp SPR_INSTALL
    INCLUDE "rom/ext_sprite_module.asm"
V2_PACKAGE_SPRITE_END:
    ASSERT $ <= EXTENSION_MODULE_LIMIT
    SAVEBIN "build/v2_package_sprite.bin", EXTENSION_MODULE_BASE, V2_PACKAGE_SPRITE_END-EXTENSION_MODULE_BASE
