#!/usr/bin/env python3
"""Synthesise EAR-line streams for the production tape receiver (test tooling).

The R10.9 Phase 1 production-ROM tests feed the REAL `STORAGE_LOAD` /
`STORAGE_RECEIVE_BLOCK` code an EAR signal through ZEsarUX's "real tape"
input (`realtape-open`, raw 8-bit unsigned samples at 15,600 Hz), so a tape
fault (dropout, bad flag, bad checksum, truncated block) exercises the same
code path that physical cassette audio would -- only the analogue path
(recorder, cable, line level, noise, wow/flutter) is not modelled.

The block framing and pulse widths are the project's own (they come from
`tools/make_extension_tzx.py`, which is itself the Fuse-validated stock
framing): flag byte, payload, XOR checksum; pilot, two sync pulses, then
two equal half-pulses per bit.  Pulse widths are expressed in T-states and
point-sampled at the RWA rate, so a stream carries up to +-1 sample
(226 T) of edge jitter; the receiver tolerates that.

Library use:

    t = Tape()
    t.block(framed(0x00, header))                 # header block
    t.block(framed(0xFF, data), dropout=(10, 6))  # 6 bytes with no edges
    t.write_rwa(path, lead_tstates=6_000_000)
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import make_extension_tzx as M  # noqa: E402  (pulse constants and framing)

CPU_HZ = 3_528_000          # TS2068 CPU clock
RWA_HZ = 15_600             # ZEsarUX raw tape rate (FRECUENCIA_SONIDO_RWA_FILES)
SAMPLE_T = 80               # one make_extension_tzx "sample" in T-states
HEADER_PAYLOAD_LEN = 17

framed = M.framed


def _abi():
    import v2_abi
    return v2_abi.load()


def header_payload(htype, name, length, autostart=0x8000, proglen=None):
    """The 17-byte header payload (type, 10-char name, length, autostart, proglen)."""
    nm = name.encode("ascii") if isinstance(name, str) else bytes(name)
    nm = nm[:10].ljust(10, b" ")
    return (bytes([htype]) + nm + length.to_bytes(2, "little")
            + autostart.to_bytes(2, "little")
            + (length if proglen is None else proglen).to_bytes(2, "little"))


class Tape:
    """A list of (level, T-states) runs with a running level."""

    def __init__(self):
        self.runs = []
        self.level = 0

    def _run(self, tstates):
        self.runs.append((self.level, tstates))
        self.level ^= 1

    def flat(self, tstates):
        """No edges for `tstates` (silence / dropout); level is unchanged afterwards."""
        self.runs.append((self.level, tstates))

    def block(self, data, dropout=None, truncate_after=None, pilot_pulses=None):
        """Emit one framed block (flag..checksum bytes already in `data`).

        dropout=(first, count): bytes first..first+count-1 (index 0 = flag byte) are
            replaced by a flat, edge-free stretch of the same duration.
        truncate_after=n: only the first n bytes are sent; the tape then goes silent.
        """
        self.flat(M.SILENCE_SAMPLES * SAMPLE_T)
        for _ in range(M.PILOT_PULSES if pilot_pulses is None else pilot_pulses):
            self._run(M.PILOT_SAMPLES * SAMPLE_T)
        for w in M.SYNC_SAMPLES:
            self._run(w * SAMPLE_T)
        for idx, value in enumerate(data):
            if truncate_after is not None and idx >= truncate_after:
                self.flat(M.SILENCE_SAMPLES * SAMPLE_T)
                return
            cost = 0
            runs = []
            for shift in range(7, -1, -1):
                w = (M.ONE_SAMPLES if value & (1 << shift) else M.ZERO_SAMPLES) * SAMPLE_T
                runs += [w, w]
                cost += 2 * w
            if dropout and dropout[0] <= idx < dropout[0] + dropout[1]:
                self.flat(cost)
            else:
                for w in runs:
                    self._run(w)
        self._run(M.ZERO_SAMPLES * SAMPLE_T)

    def silence(self, seconds):
        self.flat(int(seconds * CPU_HZ))

    def to_rwa(self, lead_tstates=0, tail_seconds=1.0):
        """Point-sample the run list at RWA_HZ.  Level 1 -> $C8, level 0 -> $38, idle $80."""
        out = bytearray()
        per = CPU_HZ / RWA_HZ

        def emit_until(level_byte, end_t):
            n_target = int(end_t / per)
            if n_target > len(out):
                out.extend(bytes([level_byte]) * (n_target - len(out)))

        emit_until(0x80, lead_tstates)
        t = lead_tstates
        for level, dt in self.runs:
            t += dt
            emit_until(0xC8 if level else 0x38, t)
        emit_until(0x80, t + int(tail_seconds * CPU_HZ))
        return bytes(out)

    def write_rwa(self, path, lead_tstates=0, tail_seconds=1.0):
        with open(path, "wb") as f:
            f.write(self.to_rwa(lead_tstates, tail_seconds))
        return path


def program_tape(name, source, *, htype=0, autostart=None, data_flag=0xFF,
                 bad_checksum=False, dropout=None, truncate_after=None,
                 header_length=None):
    """Header + data blocks for `source` bytes as the production LOAD expects them."""
    ln = len(source) if header_length is None else header_length
    if autostart is None:
        autostart = _abi().fmt_word          # the current V2 program-format word
    t = Tape()
    t.block(framed(0x00, header_payload(htype, name, ln, autostart)))
    data = bytearray(framed(data_flag, source))
    if bad_checksum:
        data[-1] ^= 0x01
    t.block(bytes(data), dropout=dropout, truncate_after=truncate_after)
    return t


def source_records(lines):
    """Program text in the V2 line-store record format: [len:2][text][CR]."""
    return b"".join((len(s) + 1).to_bytes(2, "little") + s.encode() + b"\r" for s in lines)
