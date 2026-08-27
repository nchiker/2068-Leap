; Packages the independently built 16 KB Home ROM and 8 KB EXROM into the
; contiguous 24 KB custom-ROM format expected by ZEsarUX's TS2068 model.
    DEVICE NOSLOT64K
    ORG $0000
    INCBIN "build/test_basic.bin"
    INCBIN "build/exrom.bin"
    SAVEBIN "build/ts2068rom_zesarux.bin", $0000, $6000
