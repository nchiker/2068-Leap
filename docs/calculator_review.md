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

With the safety contracts established, sparse dispatch-table compression is a
reasonable size optimization provided all simulator, smoke, editor, and BASIC
regressions remain green.
