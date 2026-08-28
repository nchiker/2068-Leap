# EXROM Calculator Review

Status: reviewed on `develop/v2` on 2026-08-28. This review changes no
calculator behavior. It records the supported scope, validation evidence, and
hardening work needed before treating the engine as a general-purpose
replacement for the original TS2068/Spectrum calculator.

## Conclusion

The calculator is suitable for its current ROM-owned call sites and the small
implemented operation set. Its paging entry/exit path, literal dispatcher,
fixed eight-value stack, conversions, and implemented arithmetic have focused
tests. It is not yet safe as an open-ended calculator API: malformed streams,
bad stack depth, exceptional arithmetic, and most original calculator
literals do not produce recoverable BASIC errors.

No size reduction is recommended until those contracts are settled. The
2,123-byte module is the largest EXROM subsystem, but optimizing it now would
make the more important correctness work harder to review.

## Findings

### High: invalid operation streams are not bounded

The ordinary-literal path doubles any byte below `$80` and indexes the
132-byte `CALC_TABLE`. Literals `$00-$41` remain within the table; `$42-$7F`
read a word beyond it and jump to whatever address those bytes form. Current
literal streams are ROM-authored, so this is contained today. Any future
machine-code or cartridge-facing entry must reject that range before table
lookup.

### High: stack underflow is a caller contract, not an enforced invariant

Unary, binary, delete, exchange, and conversion paths assume enough operands.
With `CALC_SP` at zero (or one for a binary operation), decrement/wraparound
can derive pointers outside `CALC_STACK`. The eight-slot overflow case is
checked in push/duplicate paths, but it intentionally enters a diagnostic
infinite loop. Add centralized depth checks before exposing the engine beyond
trusted ROM literal sequences.

### High: exceptional operations hang instead of returning BASIC errors

Division by zero, stack overflow, and every unimplemented literal use an
intentional `jr`-to-self diagnostic loop. That is useful during bring-up but
freezes an end-user program. Route these cases through a paging-safe HOME error
trampoline before broader calculator use.

### Medium: exponent range is not saturated or reported

Add normalization, multiplication, and division update the exponent with
eight-bit arithmetic. General inputs can wrap on overflow or collapse to zero
on underflow rather than reporting numeric overflow. Existing BASIC paths use
much narrower, controlled operands, but the arithmetic routines do not enforce
that limitation themselves.

### Medium: conversion overflow has an inconsistent result contract

`CALC_FP_TO_INT` correctly sets `CALC_TRUNC_FLAG`, but the documented
“best-effort” `HL` result is not uniform: values with unbiased exponent 17 or
greater take the no-shift overflow path and return zero, while other overflow
paths can retain a wrapped value. Callers must treat the flag as authoritative;
the return-value wording should not promise a meaningful overflow result.

### Medium: dedicated smoke-ROM fixtures have drifted

The six `rom/test_calc_smoke_*.asm` fixtures no longer assemble against V2.
They still reference the removed `SOUND_BEEP` symbol through their included
HOME build, and their fixed 16K padding now reports a negative block length.
Past emulator/hardware results remain useful history, but these fixtures are
not a runnable present-day regression gate until their harness is rebased.

### Low: precision is deliberately narrower than a full ROM calculator

Arithmetic truncates rather than fully rounding, addition discards an operand
when exponent separation is at least 32, and extreme cancellation may clamp to
zero. These choices are documented and adequate for current 16-bit-derived
inputs, but should be made part of the public numeric contract if retained.

### Scope: most original calculator literals remain unimplemented

Only exchange, delete, subtract, multiply, divide, add, duplicate, and
end-calculation have handlers. The other table entries deliberately dispatch
to the diagnostic hang. This is a focused arithmetic service, not yet a full
port of the original calculator bytecode.

## Validation evidence

- Production HOME and EXROM images assemble under `sjasmplus`.
- `tools/z80sim/test_calc_dispatcher.py` passes dispatcher, stack-operation,
  conversion, arithmetic, and exceptional-path checks at instruction level.
- Dedicated smoke ROM sources exist for add/subtract/multiply, division,
  exchange/delete, duplicate overflow, end-calculation, and unimplemented
  literal behavior, but the current fixtures fail to assemble as described
  above and therefore do not count as current passing evidence.
- The complete automated BASIC suite exercises the calculator through its
  current integrated call sites.

## Recommended order

1. Rebase the dedicated calculator smoke-ROM harness and add it to an
   automated target.
2. Add one paging-safe calculator-error exit and replace diagnostic hangs in
   user-reachable paths.
3. Validate literal range and operand depth centrally in the dispatcher.
4. Add exponent overflow/underflow tests and choose compatible error behavior.
5. Clarify `CALC_FP_TO_INT` overflow output and test both signs and boundaries.
6. Only then reconsider table compression or shared arithmetic tails for ROM
   recovery; keep the current readable implementation while correctness is
   still evolving.
