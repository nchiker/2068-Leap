# EXROM Calculator Review

Status: hardened on `develop/v2`, 2026-08-28. The calculator remains a focused
internal arithmetic service rather than a complete port of every original ROM
literal, but its supported interface now has explicit failure behavior.

## Completed work

- Simple literals `$42-$7F` are rejected before `CALC_TABLE` lookup.
- Unary and binary operand depths are checked centrally before pointer math.
- Literal-stream failures skip to END-CALC, reset the calculator stack, and
  return through the normal paging-safe HOME trampoline.
- Division by zero, stack overflow, invalid literals, and unavailable
  operations no longer freeze the machine. HOME records either `DIVISION BY
  ZERO`, `NUMERIC OVERFLOW`, or `CALCULATOR ERROR` through the existing BASIC
  pending-error channel.
- Direct push/conversion entries return carry set on failure. Their HOME
  wrappers record the same BASIC errors.
- Add, multiply, and divide detect exponent overflow. Exponent underflow is
  defined as signed zero, matching the engine's existing cancellation policy.
- `CALC_FP_TO_INT` now saturates consistently to `$7FFF` or `$8000`, sets
  `CALC_TRUNC_FLAG`, records numeric overflow, and returns carry set. Stack
  underflow returns zero with carry and a calculator error.
- The six dedicated calculator smoke ROMs use a minimal HOME harness again.
  They assemble within 16K and are part of `make check`/`make test`; the four
  arithmetic/stack successes and both recoverable error paths run in Fuse.
- `tools/z80sim/test_calc_dispatcher.py` is part of `make check` and covers
  dispatch, stack operations, arithmetic, invalid literals, underflow,
  division by zero, signed conversion saturation, and exponent boundaries.

## Public contract

The fixed stack contains eight five-byte values. Every literal stream must end
with `$38` (END-CALC); the bytecode has no length field, so a malformed stream
that omits its terminator cannot be recovered safely. Streams are still
ROM-authored and are not a cartridge ABI.

Supported literals are exchange `$01`, delete `$02`, subtract `$03`, multiply
`$04`, divide `$05`, add `$0F`, duplicate `$31`, and end-calculation `$38`.
Other in-range literals return `CALC_ERR_UNIMPLEMENTED`; they do not emulate
the full original Sinclair calculator.

Arithmetic truncates rather than fully rounding. Addition discards an operand
when exponent separation is at least 32, and extreme cancellation or exponent
underflow becomes zero. Those are deliberate precision limits for the current
16-bit-derived BASIC inputs.

## Error codes

`CALC_ERROR_CODE` aliases the original calculator diagnostic byte, preserving
every subsequent sysvar address:

| Code | Meaning |
|---:|---|
| 0 | No error |
| 1 | Invalid literal |
| 2 | Stack underflow |
| 3 | Stack overflow |
| 4 | Division by zero |
| 5 | Numeric overflow |
| 6 | Unimplemented literal |

The old `CALC_UNIMPLEMENTED_LITERAL_FLAG` name remains as an ABI-compatible
alias location, but it no longer stores a doubled table index.

## Remaining limitations

- A missing END-CALC terminator is unrecoverable without adding a stream length
  or changing the RST `$28` ABI.
- Most original calculator literals remain intentionally unavailable.
- The precision model is narrower than the original ROM calculator.
- Calculator bytecode is internal. Any future cartridge-facing API needs a
  versioned contract rather than exposing RST `$28` accidentally.

## Known bugs (confirmed, not yet fixed) — found 2026-09-13

Both found live under ZEsarUX while verifying an unrelated size-reduction
refactor of `CALC_OP_MUL`/`CALC_OP_DIV` (`rom/exrom_calc.asm`,
factored their inlined accumulate/shift/compare/subtract loops into shared
`CALC_ADD8`/`CALC_SHL8`/`CALC_CMP4`/`CALC_SUB4` primitives).

**Update (2026-09-13, root-caused):** both findings below turned out to be
about `basic/basic.asm`'s expression evaluator, not the calculator engine at
all — `CALC_OP_MUL`/`CALC_OP_DIV` themselves were never even reached for
either case, confirmed by temporarily logging `CALC_UNP_A`/`CALC_UNP_B` to
idle scratch RAM inside `CALC_OP_MUL` and reading it back via ZRCP after
`PRINT 12345*6789`: all zero bytes, meaning that routine's own unpack step
never ran. One of the two is a real, confirmed, currently-unfixed bug; the
other turned out not to be a bug at all. See `BASIC_EVAL_TERM`
(`basic/basic.asm:2438`) for both operators' real implementation.

- **CONFIRMED BUG: `*` silently wraps on overflow, no error, no float
  promotion.** `BASIC_EVAL_TERM`'s `.do_mul` (`basic/basic.asm:2454`) calls
  `kernel/math/math.asm`'s `MATH_MULTIPLY16` directly for every numeric `*` —
  a 16-bit signed multiply whose own documented contract is "product
  (signed, **truncated to 16 bits**)", with no overflow check at the call
  site. `PRINT 12345*6789` reaches exactly this path (the calculator engine
  is never invoked for `*` at all — confirmed by the all-zero debug scratch
  above) and prints `-10339`. This is not a corner case: `83810205 mod 65536`
  interpreted as signed 16-bit is exactly `-10339` (confirmed via a direct
  Python check), so this affects *any* multiplication whose true product
  exceeds &plusmn;32767 &mdash; a genuinely common range for a BASIC (`200*200`
  already overflows). `2*3` and `7*8` multiply correctly only because their
  products happen to fit in 16 bits.

  Not yet fixed — this touches the single hottest code path in the whole
  language (every `*` in every program) and deserves the same care as any
  other calculator-engine change. Two candidate fixes, neither implemented:
  1. **Detect overflow, raise `NUMERIC OVERFLOW`** (matches this project's
     own existing pattern for `CALC_OP_MUL`/`CALC_OP_DIV`'s exponent
     overflow). Minimal, safe, but "silently wrong" becomes "loudly
     rejected" rather than "correctly computed" for the overflow case.
     Detection approach: since neither `MATH_UMUL16` nor `MATH_MULTIPLY16`
     expose a widened result or an overflow flag, the cheapest check reusing
     already-verified primitives is a divide-back: after `product =
     MATH_MULTIPLY16(a,b)`, if `a != 0` and `MATH_DIVIDE16(product,a) != b`,
     truncation occurred. This is a standard, generally-reliable technique
     for two's-complement multiply-overflow detection, but has one known
     pathological edge case (`a=-1, b=-32768` — the one dividend with no
     positive two's-complement counterpart) worth explicitly testing in the
     Python model before trusting it, not just asserting it's fine.
  2. **Auto-promote to the float engine and let the result be a real
     float**, matching genuine Sinclair BASIC's own transparent int/float
     mixing. More correct, but a real language-semantics change (the
     evaluator's whole "DE holds a 16-bit int result" convention would need
     to accommodate a float result for every arithmetic operator down the
     chain, not just `*`) — a design decision, not just a bug fix.

  Whichever approach: Python-verify against many cases (including known
  edge cases: `-32768*-1`, `-1*-32768`, the exact `12345*6789` case above,
  and ordinary in-range values that must NOT be flagged) before writing any
  Z80, matching this project's own established discipline for calculator
  changes.

- **NOT a bug: `/` is deliberately integer division, not float division.**
  `BASIC_EVAL_TERM`'s `.divide_ok` (`basic/basic.asm:2492`) converts both
  operands to float, calls the real `CALC_OP_DIV`, then immediately converts
  the result back to a truncated integer via `CALC_FP_TO_INT_HOME` — its own
  comment says so explicitly ("truncated-toward-zero quotient") and clears
  `FUNC_RESULT_IS_FLOAT` right after, the same as `+`/`-`/`*` do. `PRINT
  10/4` showing `2` (not `2.5`) is this BASIC's intentional, documented `/`
  semantics (matching C's integer division, not Python's `/`), not a
  formatting gap or an arithmetic error. The previous entry here speculating
  this "looks like a number-to-string formatting limitation... not confirmed
  either way" was investigated and found to be simply wrong — retracted.

## Known gap, deliberately not fixed yet: `CALC_PACK` truncates instead of rounding

The same cross-project research pass that motivated the `CALC_ADD8`/
`CALC_SHL8`/`CALC_CMP4`/`CALC_SUB4` refactor above also found that `CALC_PACK`
does a straight, unconditional truncating copy with no rounding — `CALC_OP_MUL`
explicitly keeps only the top 32 bits of its 64-bit product and silently
discards the low 32 bits. structured-basic-poc's own pack routine
(`N_PUBLISH`, `rom/numeric32.asm`) carries 2 guard bytes through every
operation and rounds-to-nearest-even at pack time instead.

Unlike the `CALC_ADD8`/etc. refactor (a pure, behavior-preserving
restructuring, verified by direct A/B comparison against the original code),
adding rounding here is a genuine **precision-changing** modification to the
core float engine's actual output values, not a refactor — every existing
result's low-order digit could shift. This needs the same Python-first
verification this project's own `CALC_OP_MUL`/`CALC_OP_DIV` headers already
document as the standard for changes to this engine (simulate the rounding
logic against many cases before writing any Z80), which is real, separate
work from the size-reduction pass above. Deliberately deferred rather than
rushed alongside the bug findings above — worth doing as its own dedicated
pass.

**Scope, clarified while investigating the two bug reports above:**
`CALC_OP_MUL`/`CALC_OP_DIV` (and therefore this truncation gap) are **not**
reachable from ordinary BASIC `*`/`/` at all — both operators use
`kernel/math/math.asm`'s 16-bit integer routines instead (see the bug entry
above). Grepping every `rst $28` call site in `basic/basic.asm` for a
multiply literal (`$04`) shows the calculator engine's multiply/divide are
only ever invoked from `BASIC_SQR_FLOAT`/`BASIC_SIN_FLOAT`/`BASIC_RAD_FLOAT`/
`BASIC_DEG_FLOAT`'s own internal computation (Newton's-method square root,
Taylor-series sine, degree/radian conversion) — this truncation gap affects
the precision of `SQR`/`SIN`/`COS`/`RAD`/`DEG` specifically, not general
arithmetic. Still worth fixing on its own merits, but lower urgency and
narrower blast radius than initially scoped.

With the safety contracts established, sparse dispatch-table compression is a
reasonable size optimization provided all simulator, smoke, editor, and BASIC
regressions remain green.
