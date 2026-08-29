# EightyOne Setup

These instructions were confirmed by an EightyOne user with the released
Windows version 1.41.

## Build the emulator images

Run:

```sh
make build
```

This produces two files for EightyOne:

- `build/test_basic.bin` — the 16K Home ROM image.
- `build/exrom.dck` — the 8K EXROM packaged as an EightyOne Timex cartridge.

EightyOne v1.41 does not load the raw `build/exrom.bin` as a cartridge. Its
`.dck` file is the raw EXROM preceded by these nine bytes:

```text
FE 00 00 00 00 00 00 02 00
```

The build creates this deterministically with
`tools/make_eightyone_dck.sh`. It rejects an input that is not exactly 8192
bytes and verifies that the resulting cartridge is 8201 bytes.

## Configure EightyOne 1.41

Open the hardware configuration and make these selections:

1. Select the **Timex** tab and the **TS2068** machine.
2. Under **Advanced Settings**, set **ROM File** to
   `build/test_basic.bin`.
3. Leave **Protect ROM from Writes** enabled.
4. Under **Interfaces**, set **ROM Cartridge** to **Timex** and select
   `build/exrom.dck` as the cartridge file.
5. Apply the settings and perform a hard reset.

Do not select `exrom.bin` in the ROM Cartridge field; use `exrom.dck`.

## Power-on RAM setting

Current V1 and V2 builds initialize the complete ROM-owned `$8000-$BFFF`
RAM region at cold start. They should therefore boot consistently whether
EightyOne initializes RAM to zero or randomizes it. Randomized RAM is the
more useful compatibility test because it exposes accidental reads of
uninitialized state.

## Original field note

The contributor-supplied Word document and screenshots are retained at
`patches/EightyOne/ChangesAndSetup.docx`. This page is the maintained,
searchable version of those instructions.
