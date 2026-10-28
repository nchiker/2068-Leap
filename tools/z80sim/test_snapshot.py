#!/usr/bin/env python3
"""State snapshot, symbol annotation, and bounded replay tests."""
import json
import contextlib
import io
import tempfile
import unittest
from pathlib import Path

from sim import Program, Z80Sim
from snapshot import capture_state, restore_state
from replay_snapshot import main as replay_main
from extract_routine import extract


class SnapshotTests(unittest.TestCase):
    def test_round_trip_registers_flags_stack_overlays_and_memory(self):
        sim = Z80Sim()
        sim.regs.update({'A': 0x42, 'IX': 0x8123, 'SP': 0xFF00})
        sim.flags.update({'S': 1, 'Z': 1, 'H': 1, 'PV': 0, 'N': 1, 'C': 1})
        sim.alt_a = 0x99
        sim.alt_flags.update({'S': 0, 'Z': 1, 'H': 0, 'PV': 1, 'N': 0, 'C': 1})
        sim.stack_list = [('HALT', None), ('RETIDX', 17), 0xBEEF]
        sim.tuple_regs16['HL'] = ('RETIDX', 23)
        sim.alt_regs.update({'B': 1, 'C': 2, 'D': 3, 'E': 4, 'H': 5, 'L': 6})
        sim.alt_tuple_regs16['BC'] = ('RETIDX', 9)
        sim.io_writes = [(0xFE, 0xAA)]
        sim.allow_rom_writes = True
        sim.mem[0x8000:0x8003] = b'abc'

        captured = capture_state(sim, 'ROUTINE', '.entry', [(0x8000, 3)])
        restored, entry, ranges = restore_state(captured)

        self.assertEqual(entry, ('ROUTINE', '.entry'))
        self.assertEqual(ranges, [(0x8000, 3)])
        self.assertEqual(restored.regs, sim.regs)
        self.assertEqual(restored.flags, sim.flags)
        self.assertEqual(restored.alt_a, sim.alt_a)
        self.assertEqual(restored.alt_flags, sim.alt_flags)
        self.assertEqual(restored.stack_list, sim.stack_list)
        self.assertEqual(restored.tuple_regs16, sim.tuple_regs16)
        self.assertEqual(restored.alt_regs, sim.alt_regs)
        self.assertEqual(restored.alt_tuple_regs16, sim.alt_tuple_regs16)
        older = json.loads(json.dumps(captured))      # a snapshot from before BC'/DE'/HL'
        del older['cpu']['alt_regs'], older['cpu']['alt_tuple_regs16']
        self.assertEqual(restore_state(older)[0].alt_regs, {r: 0 for r in 'BCDEHL'})
        self.assertEqual(restored.io_writes, sim.io_writes)
        self.assertTrue(restored.allow_rom_writes)
        self.assertEqual(restored.mem[0x8000:0x8003], b'abc')

    def test_rejects_unknown_versions_overlapping_ranges_and_invalid_hex(self):
        sim = Z80Sim()
        basic = capture_state(sim, 'ENTRY', None, [(0x8000, 2)])
        bad_version = dict(basic, version=99)
        with self.assertRaisesRegex(ValueError, 'unsupported snapshot version'):
            restore_state(bad_version)

        with self.assertRaisesRegex(ValueError, 'overlap'):
            capture_state(sim, 'ENTRY', None, [(0x8000, 4), (0x8002, 3)])

        bad_hex = json.loads(json.dumps(basic))
        bad_hex['memory'][0]['data'] = 'xz'
        with self.assertRaisesRegex(ValueError, 'invalid hex'):
            restore_state(bad_hex)

    def test_replay_emits_source_lines_symbol_addresses_and_freshness_status(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            asm = root / 'routine.asm'
            extracted = root / 'extracted.asm'
            symbols = root / 'routine.sym'
            listing = root / 'routine.lst'
            state_path = root / 'input.json'
            result_path = root / 'result.json'
            asm.write_text('ENTRY:\n    ld a, 5\n    ret\nNEXT:\n', encoding='utf-8')
            extracted.write_text('\n'.join(extract(
                str(asm), 'ENTRY', with_locations=True)) + '\n', encoding='utf-8')
            symbols.write_text('ENTRY: EQU 0x00008000\n', encoding='utf-8')
            listing.write_text(
                '# file opened: routine.asm\n'
                '    2 8000 3E 05         ld a, 5\n'
                '# file opened: included.inc\n'
                '    1 9000 00            nop\n'
                '# file closed: included.inc\n'
                '    3 8002 C9            ret\n'
                '# file closed: routine.asm\n'
                '    2 9000 3E 05         ld a, 5\n',
                encoding='utf-8')

            sim = Z80Sim()
            sim.push(('HALT', None))
            state_path.write_text(json.dumps(capture_state(
                sim, 'ENTRY', None, [(0x8000, 1)])), encoding='utf-8')

            with contextlib.redirect_stdout(io.StringIO()):
                status = replay_main([
                    str(extracted), str(state_path), '--symbols', str(symbols),
                    '--listing', str(listing),
                    '--output', str(result_path),
                ])
            result = json.loads(result_path.read_text(encoding='utf-8'))

        self.assertEqual(status, 0)
        self.assertEqual(result['outcome'], 'returned')
        self.assertEqual(result['final_state']['cpu']['regs']['A'], 5)
        self.assertEqual(result['trace'][0]['source']['source']['line'], 2)
        self.assertEqual(Path(result['trace'][0]['source']['source']['path']).name, 'routine.asm')
        self.assertEqual(result['trace'][0]['source']['label_address'], 0x8000)
        self.assertEqual(result['trace'][0]['source']['assembled_address'], 0x8000)
        self.assertEqual(result['symbols']['matched_labels'], 1)
        self.assertIn('unverified', result['symbols']['freshness'])
        self.assertEqual(result['listing']['mapped_lines'], 2)
        self.assertEqual(result['source']['origin_files'][0]['status'], 'available')

    def test_listing_accepts_sjasmplus_include_nesting_markers(self):
        # sjasmplus writes "59+ 0CDB ..." for lines of an included file ('+' per nesting level).
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            asm = root / 'routine.asm'
            listing = root / 'routine.lst'
            asm.write_text('ENTRY:\n    ld a, 5\n    ret\n', encoding='utf-8')
            listing.write_text(
                '# file opened: top.asm\n'
                '# file opened: routine.asm\n'
                '   2+ 8000 3E 05         ld a, 5\n'
                '   3+ 8002 C9            ret\n'
                '# file closed: routine.asm\n'
                '# file closed: top.asm\n',
                encoding='utf-8')
            program = Program()
            program.load_file(str(asm))
            info = program.load_listing(str(listing))
        self.assertEqual(info['mapped_lines'], 2)

    def test_replay_stops_at_the_requested_step_limit(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            asm = root / 'loop.asm'
            state_path = root / 'input.json'
            result_path = root / 'result.json'
            asm.write_text('ENTRY:\n.loop:\n    jr .loop\n', encoding='utf-8')
            state_path.write_text(json.dumps(capture_state(
                Z80Sim(), 'ENTRY', '.loop', [])), encoding='utf-8')

            with contextlib.redirect_stdout(io.StringIO()):
                status = replay_main([
                    str(asm), str(state_path), '--max-steps', '12',
                    '--output', str(result_path),
                ])
            result = json.loads(result_path.read_text(encoding='utf-8'))

        self.assertEqual(status, 2)
        self.assertEqual(result['outcome'], 'step_limit')
        self.assertEqual(result['steps'], 12)
        self.assertFalse(result['trace_truncated'])
        self.assertIn('unavailable', result['symbols']['status'])
        self.assertIn('unavailable', result['listing']['status'])


if __name__ == '__main__':
    unittest.main()
