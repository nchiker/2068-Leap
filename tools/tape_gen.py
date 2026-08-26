#!/usr/bin/env python3
"""
tools/tape_gen.py — generates a synthetic tape file matching this
project's own from-scratch SAVE/LOAD block protocol (kernel/storage/
storage.asm), for automated LOAD-side regression testing via real Fuse
tape emulation (`fuse --tape <file>`).

WHY: this protocol is NOT the standard Sinclair tape format — it uses
standard ZX pulse widths at the low level (pilot/sync/bit0/bit1) but a
custom higher-level framing (many small 128-byte blocks, each sent
TWICE for redundancy, each individually checksummed and preceded by
its own short pilot) — see kernel/storage/storage.asm's own header for
the full design. Generic .TAP tooling produces the wrong wire format
for this ROM; this script builds the real thing directly, verified
against a genuine round-trip: found and root-caused a real user-hit
"LOAD FAILED" this way (2026-08-23) — turned out to be a stale tape
(accumulated old blocks never cleared between recordings), NOT a
protocol bug, confirmed by decoding a real Fuse-recorded TZX Direct
Recording byte-for-byte against this exact protocol spec.

Format produced: TZX v1.20, one "Direct Recording" block (ID 0x15) —
a literal sample-level pulse train, no reinterpretation needed by
Fuse. Chosen because it's the simplest format that can encode this
project's own arbitrary custom framing exactly (unlike ID 0x10
"Standard Speed Data", which assumes the classic Sinclair block
shape). Samples are 1 bit each (0=low/1=high), packed MSB-first,
8/byte, at a fixed T-states-per-sample rate — 80T/sample matches what
a real Fuse recording of this ROM's own SAVE output actually used
(confirmed by decoding one), comfortably fine-grained against every
real pulse width below (minimum ~667T sync pulse = ~8.3 samples).

Protocol constants below are copied from kernel/storage/storage.asm's
own EQUs (STORAGE_B_PILOT etc. give the *iteration count*, not the
T-state width directly — the comments there give the resulting target
T-states, which is what's used here; this script deliberately uses the
clean textbook target widths, not real hardware jitter, for a fully
deterministic regression test).

Usage:
    python3 tools/tape_gen.py <output.tzx> <filename> <data_bytes_hex>

Example (this project's own regression test, tests/storage_load1 —
see rom/test_storage_load_auto.asm):
    python3 tools/tape_gen.py /tmp/test.tzx TEST 48454c4c4f
    (filename "TEST", data = b"HELLO")
"""

import sys

# ---- protocol constants (kernel/storage/storage.asm) ----
# SCALED 1.5x (2026-08-23): a first real-Fuse-playback test at the
# exact textbook target widths measured systematically SHORT on the
# receive side (pilot read as ~30-31 WAIT_EDGE iterations against a
# 39-iteration threshold, reproducible across two independent attempts
# at two different sample-rate resolutions — ruling out a quantization
# artifact). STORAGE_PILOT_THRESHOLD/STORAGE_BIT_THRESHOLD were tuned
# against real, slightly-elongated analog cassette signal (rise time,
# EAR-line filtering), not a mathematically pure square wave — a
# genuinely faithful digital pulse train can legitimately fall short
# of a threshold calibrated that way. Scaling every width up
# uniformly preserves every ratio the protocol actually depends on
# (bit0:bit1, pilot vs sync vs data) while clearing the threshold with
# real margin.
_SCALE = 1.5
T_PILOT = round(2168 * _SCALE)
T_SYNC1 = round(667 * _SCALE)
T_SYNC2 = round(735 * _SCALE)
T_BIT0 = round(855 * _SCALE)
T_BIT1 = round(1710 * _SCALE)
BLOCK_PILOT_COUNT = 200   # pilot pulses (=toggles) per block, not cycles
BLOCK_SIZE = 128          # every data block is always exactly this many
                          # bytes on the wire, last block padded
HEADER_ID = 0
HEADER_FILENAME_LEN = 10

T_PER_SAMPLE = 80         # matches a real Fuse recording of this ROM's
                          # own SAVE output. A finer 1T/sample test
                          # (2026-08-23) produced the SAME short-reading
                          # result as 80T/sample, ruling out sample-rate
                          # quantization as the cause (see _SCALE above)
                          # — back to 80 for a smaller/faster file.


class PulseBuilder:
    """Accumulates a list of (level, T-states) segments. Level starts
    at 0 and flips on every call to pulse() — matches STORAGE_PULSE's
    own "one call = one toggle" semantics exactly (kernel/storage/
    storage.asm)."""

    def __init__(self):
        self.level = 0
        self.segments = []  # list of (level, tstates)

    def pulse(self, tstates):
        self.segments.append((self.level, tstates))
        self.level ^= 1

    def pilot_tone(self):
        for _ in range(BLOCK_PILOT_COUNT):
            self.pulse(T_PILOT)

    def sync(self):
        self.pulse(T_SYNC1)
        self.pulse(T_SYNC2)

    def send_byte(self, byte):
        for bit in range(8):
            b = (byte >> (7 - bit)) & 1
            width = T_BIT1 if b else T_BIT0
            self.pulse(width)
            self.pulse(width)

    def send_block(self, block_id, payload):
        checksum = block_id
        self.send_byte(block_id)
        for b in payload:
            checksum ^= b
            self.send_byte(b)
        self.send_byte(checksum)

    def leader_silence(self, tstates=4000):
        # a short, deliberately clean lead-in — real recordings carry
        # several seconds of this (however long the user takes to
        # start playback after arming record), but a synthetic tape
        # for automated testing has no such human delay to encode
        if tstates > 0:
            self.segments.append((self.level, tstates))
            # NOTE: does not flip level — this is a level HOLD, not a
            # toggle, matching genuine pre-SAVE silence (EAR line just
            # sitting at whatever it last was, no edges at all)


def build_header_payload(filename, data_len):
    name = filename.encode('ascii')[:HEADER_FILENAME_LEN]
    name = name + b' ' * (HEADER_FILENAME_LEN - len(name))
    return name + bytes([data_len & 0xFF, (data_len >> 8) & 0xFF])


def build_tape_segments(filename, data):
    pb = PulseBuilder()
    pb.leader_silence()

    header_payload = build_header_payload(filename, len(data))

    # header, copy A
    pb.pilot_tone()
    pb.sync()
    pb.send_block(HEADER_ID, header_payload)

    # header, copy B
    pb.pilot_tone()
    pb.sync()
    pb.send_block(HEADER_ID, header_payload)

    block_count = (len(data) + BLOCK_SIZE - 1) // BLOCK_SIZE if data else 0

    for _pass in range(2):  # two full redundant passes, not interleaved
        for block_id in range(1, block_count + 1):
            start = (block_id - 1) * BLOCK_SIZE
            chunk = data[start:start + BLOCK_SIZE]
            payload = chunk + bytes(BLOCK_SIZE - len(chunk))  # zero-pad
            pb.pilot_tone()
            pb.sync()
            pb.send_block(block_id, payload)

    return pb.segments


def segments_to_samples(segments, t_per_sample=T_PER_SAMPLE):
    bits = []
    for level, tstates in segments:
        n = max(1, round(tstates / t_per_sample))
        bits.extend([level] * n)
    return bits


def pack_bits(bits):
    out = bytearray()
    used_bits_in_last = 0
    for i in range(0, len(bits), 8):
        chunk = bits[i:i + 8]
        used_bits_in_last = len(chunk)
        byte = 0
        for j, bit in enumerate(chunk):
            byte |= (bit & 1) << (7 - j)
        out.append(byte)
    # TZX convention: 0 means "all 8 bits used" in the last byte
    if used_bits_in_last == 8:
        used_bits_in_last = 0
    return bytes(out), used_bits_in_last


def write_tzx(path, bits, t_per_sample=T_PER_SAMPLE):
    packed, used_bits = pack_bits(bits)
    length = len(packed)
    out = bytearray()
    out += b'ZXTape!\x1a\x01\x14'          # 10-byte TZX general header
    out.append(0x15)                        # Direct Recording block
    out += t_per_sample.to_bytes(2, 'little')
    out += (0).to_bytes(2, 'little')        # pause after block (ms)
    out.append(used_bits)
    out += length.to_bytes(3, 'little')
    out += packed
    with open(path, 'wb') as f:
        f.write(bytes(out))


def main():
    if len(sys.argv) != 4:
        print(__doc__)
        sys.exit(1)
    out_path, filename, data_hex = sys.argv[1], sys.argv[2], sys.argv[3]
    data = bytes.fromhex(data_hex)
    segments = build_tape_segments(filename, data)
    bits = segments_to_samples(segments)
    write_tzx(out_path, bits)
    total_t = sum(t for _, t in segments)
    print(f"wrote {out_path}: {len(bits)} samples, "
          f"{len(segments)} pulse segments, "
          f"~{total_t/3_580_000:.2f}s of tape at 3.58MHz, "
          f"filename={filename!r} data={data!r}")


if __name__ == '__main__':
    main()
