# R8.9 integrated RAM ledger — relocation checkpoint

Status: RAM placement selected and standalone relocation checked; production
integration is not yet built. Addresses below are the assembled source values
after relocation. Capacities marked *reserved* are layout decisions, not yet
enforced by the production dispatcher or compiler.

## Evidence and constraints

- `PROG_AREA_START=$8455` and `PROG_AREA_MAX=$C000` are assembled in
  `build/test_basic.sym`. `MEM_LINE_STORE` checks `VARS_START`; `MEM_INIT`
  initializes that pointer to `$C000`. A V2 boot path must lower it to the
  source boundary below before accepting a line. Source lines are `[length:2]
  [text][CR]`; the headers make the staged colon-joined source no longer than
  the stored program plus one byte.
- The former first V2 allocation was `FLOATTAB_BASE=$8500`, just 171 bytes
  above source start. `PROG_AREA_MAX` cannot rise: chunk 6 is paged to EXROM.
- A source search of production `.asm`/`.inc` allocations found no resident
  RAM allocation in `$98C8-$BFFF`. `$BF3B` in `hardware.inc` is the ULAplus
  I/O port. The sprite module's 11-byte scratch block at `$9800-$980A`
  and the extension registry and call scratch were included in relocation.
  Test-only scratch addresses such as `$9800` are not production claims.
- Sizes below follow current source constants and assembled symbols. They
  are declared maxima or reservations, not measured peak use, unless noted.

## Selected chunk-4/5 placement

| Range | Bytes | Class | Lifetime and status |
|---|---:|---|---|
| `$8000-$8454` | 1,109 | A/I/M: kernel sysvars, editor, tape and calculator scratch, graphics metadata | Resident; assembler-computed `sysvars.inc` block. |
| `$8455-$9454` | 4,096 | B: authoritative line store | Durable until NEW/LOAD; **reserved, ceiling not yet wired**. Includes 2-byte record headers and CR bytes. |
| `$9455-$A454` | 4,096 | G: colon-joined source staging | Compile only; **reserved, assembler routine not yet written**. Source remains live while compiling. |
| `$A455-$B3FF` | 4,011 | C: VM bytecode | Compile, RUN and optional decompile; **base relocated, end check not yet implemented**. Current `EMIT_BYTE` has no bounds check. |
| `$B400-$BFFF` | 3,072 | A/D/E/F/G/H/J/L/M: fixed V2 workspace | Resident allocation envelope, including deliberate gaps. Details below. |

The 4,096-byte line-store reservation provides 3,925 bytes more than the
previous unsafe 171-byte overlap point. That is a reserved architectural
capacity, not a tested product capacity yet. If source is limited to 4,096
stored bytes, the 4,096-byte staging buffer is sufficient because every
record contributes two header bytes that are not copied, each CR becomes one
colon, and one trailing NUL is added. `VARS_START=$9455` must be set on boot,
NEW and successful LOAD. SAVE/LOAD must use this same limit.

## V2 fixed allocation detail

| Allocation | Current range / maximum bytes | Class and lifetime |
|---|---|---|
| `FLOATTAB_BASE` | `$B400-$B459`, 18 × 5 = 90 | D/F: 16 numeric slots plus 2 floating temporaries; RUN. |
| `ARRTAB_BASE` | `$B460-$B4DF`, 4 × 16 × 2 = 128 | E: four integer arrays, 16 elements each; RUN. |
| `STRTAB_BASE` | `$B500-$B5BF`, (4 named + 2 temporary) × 32 = 192 | F: 31 content bytes per string; RUN. |
| VM state and operand stack | `$B600-$B6E3` envelope; `$B604-$B67F` = 124 stack bytes | J/M: at most 41 complete 3-byte operand records; RUN. |
| VM call stack | `$B694-$B69F`, 12 | J: six return addresses; RUN. |
| `SYMTAB_BASE` | `$B700-$B72F`, 16 × 3 = 48 | D: numeric variable tag/value records; RUN. |
| `CSYMTAB_BASE` | `$B800-$B88F`, 16 × 9 = 144 | G: numeric names; compile, retained for decompile. |
| `ARRSYMTAB_BASE` | `$B890-$B8B7`, 4 × 10 = 40 | G: array names and sizes; compile, retained for decompile. |
| `LABELTAB_BASE` | `$B900-$B957`, 8 × 11 = 88 | G: label definitions; compile, retained for decompile. |
| `FIXUPTAB_BASE` | `$B960-$B9B7`, 8 × 11 = 88 | G: unresolved branch targets; compile only. |
| `SRC_PTR` and parser scratch | `$BA00-$BA5B` envelope, 92 | G: pointer, token, expression and statement scratch; compile only. |
| `STRSYMTAB_BASE` | `$BA60-$BA83`, 4 × 9 = 36 | G: string names; compile, retained for decompile. |
| Decompiler fragments | `$BB00-$BBFF`, 8 × 32 = 256 | H: expression stack; decompile only. |
| `DECOMP_OUT_BUF` | `$BC00-$BD8F`, 400 | H: default complete output; callback can consume one line at a time. Current writes have no 400-byte guard. Decompile only. |
| Decompiler state and scratch | `$BD90-$BE6F` envelope | H/M: argument pointers, labels, marker table, combination buffer and counters; decompile only. |
| Extension call/register scratch | `$BED8-$BEEF` envelope | L/M: extension ABI and registration lookup; registration/VM calls. |
| `EXT2_TABLE` | `$BF00-$BFA7`, 12 × 14 = 168 | L: registered names, entry pointers and generations; persists across compile/RUN/editor. |
| Extension argtype scratch | `$BFA8`, 1 | L/M: registration only. |
| Sprite package scratch | `$BFB0-$BFBA`, 11 | L/M: sprite package invocation only. |

Compiler scratch and decompiler scratch do not need to coexist in use, but
the compiler symbol tables must survive compilation for decompiler names.
The source store, staged source, emitted bytecode and extension registry are
all live during compilation. Bytecode and runtime tables are live together
during RUN. The editor line buffer is live while source is edited; it is in
chunk 7. No lifetime overlay is claimed in this first placement. The fixed
workspace envelope contains deliberate gaps, leaving room for a later,
measured overlay if needed.

## Remaining memory and paging

| Range | Bytes | Class and lifetime |
|---|---:|---|
| `$4000-$7FFF` | 16,384 | N: video RAM pool; standard bitmap/attributes and alternate Timex display modes. |
| `$C000-$D7FF` | 6,144 | M/N: FILL visited bitmap in HOME RAM; chunk 6 becomes EXROM while paged, so no V2 persistent data belongs here. |
| `$D800-$E7FF` | 4,096 | M: FILL coordinate stack, transient. |
| `$E800-$F0FF` | 2,304 | L/N: eight sprite image and background slots, persistent. |
| `$F100-$F17F` | 128 | A: existing label table, persistent. |
| `$F180-$F227` | 168 | N: UDG patterns, persistent. |
| `$F228-$F2A7` | 128 | I: editor input/LOAD-name buffer. |
| `$F2A8-$F327` | 128 | I/M: detokenizer/display buffer; reusable plain-text copy. |
| `$F328-$F3D2` | 171 | A/M: legacy string scratch, DEF FN state, extension service ABI; some V1-only ownership pending R9. |
| `$F400-$F7FF` | 1,024 | L: existing loadable package window. |
| `$F800-$FEFF` | 1,792 | K: clear machine-stack headroom below initial `SP=$FF00`. Existing nested-expression canary observed 126 bytes at an earlier checkpoint. |
| `$FF00-$FFFF` | 256 | N: above initial SP; not counted as stack growth headroom. |

The generic V1 dynamic arrays and scalar pool were formerly free to grow
within `$8455-$BFFF`. V2 uses its fixed `SYMTAB`/`ARRTAB`/`STRTAB` instead;
the V1 dynamic pool must be dormant in the V2 production path. Its historic
`VARS_START` semantics remain in `kernel/memory` and must be used as the
line-store ceiling. Storage/tape workspaces are in the `$8000-$8454`
sysvars block, and the editor and LOAD-name buffers are in chunk 7.

## Validation and open production gates

The 14 currently buildable V2 standalone sources assembled after relocation.
Real ZEsarUX returned green for 13 unchanged fixtures. The milestone-01 VM
fixture returned red both before and after relocation: its hand-written
FOR_INIT had two values although the current VM pops three, including STEP.
Adding a STEP=1 opcode to the fixture, while keeping the expected sum of 15,
made its hardware result green. Thus 14/14 are green with one baseline
fixture correction; the prior handoff's 14/14 checkpoint claim was stale.
The relocation changed 207 `equ` values across VM, compiler, decompiler,
extension registry and sprite package sources. Source inspection and the
hardware runs exposed no executable hidden literal-address dependency; the
milestone-01 failure was reproduced against the untouched checkpoint.

Production source, bytecode and decompiler bounds are not enforced yet.
The actual production ROM still boots V1, so none of the reserved product
capacities or interactive paths above has a production hardware verdict.

## ROM integration gate discovered after relocation

Fresh `make budget` on the current production targets reports HOME 15,830
and EXROM 8,083 bytes, totaling **23,913 / 24,576**, with 663 free (554
HOME, 109 EXROM). This differs from the older handoff's 24,294-byte
figure; the fresh assembled production listing is authoritative for these
targets. The fresh standalone V2 listing measures VM core 4,391 bytes,
compiler 5,128 bytes and decompiler 4,716 bytes, totaling **14,235** V2
core bytes. These module sizes stayed identical across the RAM-only
relocation. The standalone image's 15,865-byte used end also includes 965
test-driver bytes, 467 math bytes and 198 format bytes; it is not all V2
core.

Adding the three V2 modules to the existing production image would need
at least 38,148 bytes before a production dispatcher, registry or other
glue: 13,572 beyond the 24KB ceiling. Even omitting the entire 11,457-byte
`basic/basic.asm` block leaves a 26,691-byte lower bound with all three V2
modules, 2,115 bytes over budget before restoring its reusable editor
parts or writing a dispatcher. The block contains reusable editor code, so
that subtraction is deliberately an *optimistic bound*, not a migration
plan. The checker EXROM file is mixed-purpose and cannot be removed whole.

The current HOME listing expands `basic/editor_integration.asm` at six
sites. Five emitting sites contribute 19 + 73 + 318 + 35 + 1,455 =
**1,900 bytes** of mature editor code inside the 11,457-byte `basic.asm`
block. Keeping those bytes while removing the remaining 9,557 raises the
full-VM/compiler/decompiler lower bound to **28,591 bytes**, 4,015 over
the ROM ceiling before a dispatcher. Excluding the 4,716-byte decompiler
from that *resident* calculation reduces the lower bound to 23,875,
leaving only 701 bytes before a dispatcher, extension registry and any
required editor helper extraction. This is capacity analysis, not a
decision to drop the decompiler; its standalone capability and tests
remain part of V2.

Therefore the handoff's suggestion that R8.9 could simply add a V2 boot
path while leaving V1 physically compiled is disproved by current assembled
sizes. A real 24KB production image needs an explicit earlier ROM-content
decision and measured placement/omission work. The RAM placement above can
support that image, but does not solve this separate ROM gate.

## Semantic and persistence status at this checkpoint

The four audit findings are unchanged in code. FLOAT operand/type-boundary
handling, nested FOR/NEXT and recursion-safe PROC parameters remain pending.
The DIM decompiler round-trip defect also remains present. Authoritative
source LIST/edit and source SAVE/LOAD would reduce its impact on ordinary
interactive editing, but that production path has not yet been implemented
or validated. The decompiler's standalone tests and bytecode debugging role
remain valid. No claim of a DIM fix follows from the source-primary layout.
