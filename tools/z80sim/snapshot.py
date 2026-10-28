"""Versioned, JSON-serializable states for bounded z80sim replay."""
import json

from sim import Z80Sim


FORMAT = "z80sim-state"
VERSION = 1
FLAG_NAMES = ("S", "Z", "H", "PV", "N", "C")
REG8_NAMES = ("A", "B", "C", "D", "E", "H", "L")
REG16_NAMES = ("IX", "IY", "SP")
ALT_REG_NAMES = ("B", "C", "D", "E", "H", "L")   # BC', DE', HL'


def _valid_int(value, minimum, maximum, what):
    if isinstance(value, bool) or not isinstance(value, int) or not minimum <= value <= maximum:
        raise ValueError(f"{what} must be an integer from {minimum} through {maximum}")
    return value


def _encode_stack_value(value):
    if isinstance(value, int) and not isinstance(value, bool):
        return {"kind": "int", "value": _valid_int(value, 0, 0xFFFF, "stack integer")}
    if isinstance(value, tuple) and len(value) == 2:
        tag, payload = value
        if tag == "RETIDX":
            return {"kind": "RETIDX", "value": _valid_int(payload, 0, 0x7FFFFFFF, "return index")}
        if tag == "HALT" and payload is None:
            return {"kind": "HALT"}
    raise ValueError(f"unsupported logical stack value in snapshot: {value!r}")


def _decode_stack_value(value):
    if not isinstance(value, dict):
        raise ValueError("stack entries must be objects")
    kind = value.get("kind")
    if kind == "int":
        return _valid_int(value.get("value"), 0, 0xFFFF, "stack integer")
    if kind == "RETIDX":
        return ("RETIDX", _valid_int(value.get("value"), 0, 0x7FFFFFFF, "return index"))
    if kind == "HALT":
        return ("HALT", None)
    raise ValueError(f"unsupported stack entry kind: {kind!r}")


def _normalize_ranges(memory_ranges):
    ranges = []
    for item in memory_ranges:
        if isinstance(item, dict):
            start, length = item.get("start"), item.get("length")
        else:
            try:
                start, length = item
            except (TypeError, ValueError):
                raise ValueError("memory ranges must be (start, length) pairs") from None
        _valid_int(start, 0, 0xFFFF, "memory range start")
        _valid_int(length, 1, 0x10000, "memory range length")
        if start + length > 0x10000:
            raise ValueError("memory ranges may not wrap past address 0xFFFF")
        ranges.append((start, length))
    ranges.sort()
    for previous, current in zip(ranges, ranges[1:]):
        if previous[0] + previous[1] > current[0]:
            raise ValueError("memory ranges may not overlap")
    return ranges


def capture_state(sim, entry_scope, entry_label, memory_ranges):
    """Return a JSON-safe snapshot. entry_label may be None for a global."""
    if not isinstance(entry_scope, str) or (entry_label is not None and not isinstance(entry_label, str)):
        raise ValueError("entry scope must be a string and label must be a string or null")
    ranges = _normalize_ranges(memory_ranges)
    cpu = {
        "regs": dict(sim.regs),
        "flags": {name: int(sim.flags[name]) for name in FLAG_NAMES},
        "alt_a": int(sim.alt_a),
        "alt_flags": {name: int(sim.alt_flags[name]) for name in FLAG_NAMES},
        "alt_regs": {name: int(sim.alt_regs[name]) for name in ALT_REG_NAMES},
        "alt_tuple_regs16": {
            name: _encode_stack_value(value)
            for name, value in sim.alt_tuple_regs16.items()
        },
        "stack": [_encode_stack_value(value) for value in sim.stack_list],
        "tuple_regs16": {
            name: _encode_stack_value(value)
            for name, value in sim.tuple_regs16.items()
        },
        "io_writes": [[int(port), int(value)] for port, value in sim.io_writes],
        "options": {"allow_rom_writes": bool(getattr(sim, "allow_rom_writes", False))},
    }
    return {
        "format": FORMAT,
        "version": VERSION,
        "entry": {"scope": entry_scope, "label": entry_label},
        "cpu": cpu,
        "memory": [
            {"start": start, "data": bytes(sim.mem[start:start + length]).hex()}
            for start, length in ranges
        ],
    }


def restore_state(snapshot, sim=None):
    """Validate and load a snapshot, returning (sim, entry, memory_ranges)."""
    if not isinstance(snapshot, dict) or snapshot.get("format") != FORMAT:
        raise ValueError(f"not a {FORMAT!r} snapshot")
    if snapshot.get("version") != VERSION:
        raise ValueError(f"unsupported snapshot version: {snapshot.get('version')!r}")
    entry = snapshot.get("entry")
    if not isinstance(entry, dict):
        raise ValueError("snapshot entry must be an object")
    scope, label = entry.get("scope"), entry.get("label")
    if not isinstance(scope, str) or (label is not None and not isinstance(label, str)):
        raise ValueError("entry scope must be a string and label must be a string or null")

    cpu = snapshot.get("cpu")
    if not isinstance(cpu, dict):
        raise ValueError("snapshot cpu must be an object")
    target_sim = sim
    sim = Z80Sim()
    regs = cpu.get("regs")
    if not isinstance(regs, dict) or set(regs) != set(sim.regs):
        raise ValueError("snapshot registers do not match the simulator register set")
    for name in REG8_NAMES:
        _valid_int(regs[name], 0, 0xFF, f"register {name}")
    for name in REG16_NAMES:
        _valid_int(regs[name], 0, 0xFFFF, f"register {name}")
    for name in ("B", "C", "D", "E", "H", "L"):
        _valid_int(regs[name], 0, 0xFF, f"register {name}")
    sim.regs.update(regs)

    for key in ("flags", "alt_flags"):
        flags = cpu.get(key)
        if not isinstance(flags, dict) or set(flags) != set(FLAG_NAMES):
            raise ValueError(f"snapshot {key} must contain exactly {', '.join(FLAG_NAMES)}")
        for name, value in flags.items():
            sim_flags = sim.flags if key == "flags" else sim.alt_flags
            sim_flags[name] = _valid_int(value, 0, 1, f"{key}.{name}")
    sim.alt_a = _valid_int(cpu.get("alt_a"), 0, 0xFF, "alternate A")
    alt_regs = cpu.get("alt_regs", {name: 0 for name in ALT_REG_NAMES})   # optional: older snapshots
    if not isinstance(alt_regs, dict) or set(alt_regs) != set(ALT_REG_NAMES):
        raise ValueError("snapshot alt_regs must contain exactly " + ", ".join(ALT_REG_NAMES))
    for name, value in alt_regs.items():
        sim.alt_regs[name] = _valid_int(value, 0, 0xFF, f"alternate {name}")
    alt_overlays = cpu.get("alt_tuple_regs16", {})
    if not isinstance(alt_overlays, dict) or not set(alt_overlays) <= {"BC", "DE", "HL"}:
        raise ValueError("snapshot alt_tuple_regs16 contains an invalid register")
    sim.alt_tuple_regs16 = {name: _decode_stack_value(value) for name, value in alt_overlays.items()}

    stack = cpu.get("stack")
    if not isinstance(stack, list):
        raise ValueError("snapshot stack must be a list")
    sim.stack_list = [_decode_stack_value(value) for value in stack]
    overlays = cpu.get("tuple_regs16")
    if not isinstance(overlays, dict) or not set(overlays) <= {"BC", "DE", "HL", "IX", "IY", "SP"}:
        raise ValueError("snapshot tuple_regs16 contains an invalid register")
    sim.tuple_regs16 = {name: _decode_stack_value(value) for name, value in overlays.items()}
    options = cpu.get("options", {})
    if not isinstance(options, dict) or not isinstance(options.get("allow_rom_writes", False), bool):
        raise ValueError("snapshot allow_rom_writes option must be boolean")
    sim.allow_rom_writes = options.get("allow_rom_writes", False)
    writes = cpu.get("io_writes")
    if not isinstance(writes, list):
        raise ValueError("snapshot io_writes must be a list")
    sim.io_writes = []
    for write in writes:
        if not isinstance(write, list) or len(write) != 2:
            raise ValueError("each io_writes entry must be a [port, value] pair")
        sim.io_writes.append((_valid_int(write[0], 0, 0xFF, "port"),
                              _valid_int(write[1], 0, 0xFF, "port value")))

    memory = snapshot.get("memory")
    if not isinstance(memory, list):
        raise ValueError("snapshot memory must be a list")
    ranges = []
    memory_blocks = []
    for block in memory:
        if not isinstance(block, dict):
            raise ValueError("memory blocks must be objects")
        start = _valid_int(block.get("start"), 0, 0xFFFF, "memory block start")
        data = block.get("data")
        if not isinstance(data, str) or len(data) % 2:
            raise ValueError("memory block data must be an even-length hex string")
        try:
            raw = bytes.fromhex(data)
        except ValueError:
            raise ValueError("memory block data contains invalid hex") from None
        if not raw or start + len(raw) > 0x10000:
            raise ValueError("memory block is empty or wraps past address 0xFFFF")
        ranges.append((start, len(raw)))
        memory_blocks.append((start, raw))
    ranges = _normalize_ranges(ranges)
    for start, raw in memory_blocks:
        sim.mem[start:start + len(raw)] = raw
    if target_sim is not None:
        target_sim.regs = sim.regs
        target_sim.flags = sim.flags
        target_sim.alt_a = sim.alt_a
        target_sim.alt_flags = sim.alt_flags
        target_sim.alt_regs = sim.alt_regs
        target_sim.alt_tuple_regs16 = sim.alt_tuple_regs16
        target_sim.stack_list = sim.stack_list
        target_sim.tuple_regs16 = sim.tuple_regs16
        target_sim.io_writes = sim.io_writes
        target_sim.mem[:] = sim.mem
        target_sim.allow_rom_writes = sim.allow_rom_writes
        sim = target_sim
    return sim, (scope, label), ranges


def save_snapshot(path, sim, entry_scope, entry_label, memory_ranges):
    snapshot = capture_state(sim, entry_scope, entry_label, memory_ranges)
    with open(path, "w", encoding="utf-8") as output:
        json.dump(snapshot, output, indent=2)
        output.write("\n")


def load_snapshot(path, sim=None):
    with open(path, encoding="utf-8") as source:
        snapshot = json.load(source)
    return restore_state(snapshot, sim)
