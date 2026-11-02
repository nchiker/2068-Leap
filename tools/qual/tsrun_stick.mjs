#!/usr/bin/env node
// tools/qual/tsrun_stick.mjs -- STICK on TSRun's emulator core, headless, for what ZEsarUX does not model: TSRun
// models both joystick connectors (A8 strobes joystick 1, A9 joystick 2; contacts active low) and the AY's port A
// direction (an output port reads back its latch, not the pins). From 2068-Forth's tools/tsruntest.mjs.
//
//   node tools/qual/tsrun_stick.mjs [TREE]      (default .; TSRun from $TSRUN, default ~/TSRun)
//
// With the mixer set to $F8 (port A an output, as the boot chime, SOUND and BEEP can leave it) and each joystick's
// contacts set, BUILTIN_FN_STICK is entered after its range check with L = n and run to VM_PUSH_INT; HL must be:
// each stick only its own connector, the directions in bits 0-3, fire as 16, all four at once 0, nothing 0.
// Exit 0 when every case passes. EMULATOR LIMITS: TSRun's Z80, AY and joystick model; no hardware.
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const tree = resolve(process.argv[2] || ".");
const tsrun = process.env.TSRUN || join(homedir(), "TSRun");
const M = await import(pathToFileURL(join(tsrun, "machine.js")).href);
const Z = await import(pathToFileURL(join(tsrun, "z80.js")).href);
const sym = {};
for (const line of readFileSync(join(tree, "build", "test_basic.sym"), "utf8").split("\n")) {
    const x = /^(\S+): EQU 0x([0-9A-Fa-f]+)/.exec(line);
    if (x) sym[x[1]] = parseInt(x[2], 16);
}
const home = readFileSync(join(tree, "build", "test_basic.bin"));
const exrom = readFileSync(join(tree, "build", "exrom.bin"));
const entry = sym["BUILTIN_FN_STICK.bad"] + 3;       // after `jp nc,<range error>`
const push = sym["VM_PUSH_INT"];

// [n, joystick 1 contacts, joystick 2 contacts (active low: bit 7 fire, bits 0-3 directions), expected]
const CASES = [
    [1, 0xFF, 0xFF, 0], [2, 0xFF, 0xFF, 0],
    [1, 0xFE, 0xFF, 1], [2, 0xFE, 0xFF, 0],
    [1, 0x7F, 0xFF, 16],
    [2, 0xFF, 0xF5, 10], [1, 0xFF, 0xF5, 0],
    [2, 0xFF, 0x75, 26],
    [1, 0xF0, 0xFF, 0],
];
let bad = 0;
for (const [n, j1, j2, want] of CASES) {
    const joy = Uint8Array.of(0xFF, 0xFF);
    const m = M.createMachine(new Uint8Array(9).fill(0x1F), joy);
    M.setHomeRom(m, home);
    M.setExRom(m, exrom);
    M.resetMachine(m);
    for (let i = 0; i < 200; i++) M.runFrame(m);
    // di; ld a,7; out ($F5),a; ld a,$F8; out ($F6),a; ld hl,n; jp entry
    const stub = [0xF3, 0x3E, 0x07, 0xD3, 0xF5, 0x3E, 0xF8, 0xD3, 0xF6, 0x21, n, 0x00, 0xC3, entry & 0xFF, entry >> 8];
    stub.forEach((v, i) => m.bus.write(0x4000 + i, v));
    joy[0] = j1; joy[1] = j2;
    m.cpu.pc = 0x4000; m.cpu.halted = false;
    let steps = 0;
    while (m.cpu.pc !== push && steps++ < 200) Z.runZ80(m.cpu, m.bus, 1, m);
    const got = m.cpu.pc === push ? (m.cpu.h << 8) | m.cpu.l : -1;
    const what = `STICK(${n}) with joystick 1 $${j1.toString(16)}, joystick 2 $${j2.toString(16)}`;
    if (got !== want) { bad++; console.log(`tsrun_stick: FAIL ${what}: ${got}, expected ${want}`); }
}
console.log(`tsrun_stick: ${CASES.length - bad}/${CASES.length} cases pass`);
process.exit(bad ? 1 : 0);
