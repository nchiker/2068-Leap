; V2-native LPRINT/LLIST package. LLIST prints authoritative source.
    INCLUDE "include/hardware.inc"
    INCLUDE "include/sysvars.inc"
    INCLUDE "build/v2_crossbank.inc"
    DEFINE V2_PRODUCTION
    DEVICE NOSLOT64K
    ORG EXTENSION_MODULE_BASE
    jp PRT_INSTALL
    INCLUDE "rom/printer_raster.asm"
    INCLUDE "rom/ext_printer_module.asm"
V2_PACKAGE_PRINTER_END:
    ASSERT $ <= EXTENSION_MODULE_LIMIT
    SAVEBIN "build/v2_package_printer.bin", EXTENSION_MODULE_BASE, V2_PACKAGE_PRINTER_END-EXTENSION_MODULE_BASE
