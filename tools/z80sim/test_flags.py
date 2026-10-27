#!/usr/bin/env python3
"""Focused flag-semantics regression tests for the z80sim instruction subset."""
import unittest

from sim import Interp, Program, Z80Sim


class FlagSemanticsTests(unittest.TestCase):
    def setUp(self):
        self.sim = Z80Sim()
        self.interp = Interp(Program(), self.sim)

    def run_op(self, mnemonic, operands):
        return self.interp.exec_instr('TEST', mnemonic, operands)

    def test_add_sets_sign_zero_half_carry_overflow_and_carry(self):
        self.sim.regs['A'] = 0x7F
        self.run_op('add', 'a,1')
        self.assertEqual(self.sim.regs['A'], 0x80)
        self.assertEqual(self.sim.flags, {
            'Z': 0, 'C': 0, 'S': 1, 'PV': 1, 'H': 1, 'N': 0,
        })

        self.sim.regs['A'] = 0xFF
        self.run_op('add', 'a,1')
        self.assertEqual(self.sim.regs['A'], 0)
        self.assertEqual(self.sim.flags, {
            'Z': 1, 'C': 1, 'S': 0, 'PV': 0, 'H': 1, 'N': 0,
        })

    def test_add_sub_flag_helpers_cover_all_byte_inputs_and_carry_states(self):
        # Compare the implementation against signed-range, nibble-range,
        # and byte-range definitions for every input combination.
        for left in range(256):
            for right in range(256):
                for carry in (0, 1):
                    total = left + right + carry
                    result = total & 0xFF
                    self.sim.add8_flags(left, right, carry)
                    self.assertEqual(self.sim.flags['S'], result >> 7)
                    self.assertEqual(self.sim.flags['Z'], int(result == 0))
                    signed_total = (left if left < 128 else left - 256)
                    signed_total += right if right < 128 else right - 256
                    signed_total += carry
                    self.assertEqual(self.sim.flags['PV'], int(not -128 <= signed_total <= 127))
                    self.assertEqual(self.sim.flags['H'], int((left & 15) + (right & 15) + carry > 15))
                    self.assertEqual(self.sim.flags['C'], int(total > 255))
                    self.assertEqual(self.sim.flags['N'], 0)

                    difference = left - right - carry
                    result = difference & 0xFF
                    self.sim.sub8_flags(left, right, carry)
                    self.assertEqual(self.sim.flags['S'], result >> 7)
                    self.assertEqual(self.sim.flags['Z'], int(result == 0))
                    signed_difference = (left if left < 128 else left - 256)
                    signed_difference -= right if right < 128 else right - 256
                    signed_difference -= carry
                    self.assertEqual(self.sim.flags['PV'], int(not -128 <= signed_difference <= 127))
                    self.assertEqual(self.sim.flags['H'], int((left & 15) < (right & 15) + carry))
                    self.assertEqual(self.sim.flags['C'], int(difference < 0))
                    self.assertEqual(self.sim.flags['N'], 1)

    def test_adc_and_sbc_include_carry_in(self):
        self.sim.regs['A'] = 0x7F
        self.sim.flags['C'] = 1
        self.run_op('adc', 'a,0')
        self.assertEqual(self.sim.regs['A'], 0x80)
        self.assertEqual((self.sim.flags['S'], self.sim.flags['PV'], self.sim.flags['H'], self.sim.flags['C']), (1, 1, 1, 0))

        self.sim.regs['A'] = 0
        self.sim.flags['C'] = 1
        self.run_op('sbc', 'a,0')
        self.assertEqual(self.sim.regs['A'], 0xFF)
        self.assertEqual((self.sim.flags['S'], self.sim.flags['PV'], self.sim.flags['H'], self.sim.flags['N'], self.sim.flags['C']), (1, 0, 1, 1, 1))

    def test_sub_and_cp_overflow_and_cp_preserves_accumulator(self):
        self.sim.regs['A'] = 0x80
        self.run_op('sub', '1')
        self.assertEqual(self.sim.regs['A'], 0x7F)
        self.assertEqual((self.sim.flags['PV'], self.sim.flags['H'], self.sim.flags['N'], self.sim.flags['C']), (1, 1, 1, 0))

        self.sim.regs['A'] = 0x80
        self.run_op('cp', '1')
        self.assertEqual(self.sim.regs['A'], 0x80)
        self.assertEqual((self.sim.flags['PV'], self.sim.flags['H'], self.sim.flags['N'], self.sim.flags['C']), (1, 1, 1, 0))

    def test_logical_ops_compute_parity_and_documented_flags(self):
        self.sim.regs['A'] = 0x03
        self.run_op('xor', '3')
        self.assertEqual(self.sim.regs['A'], 0)
        self.assertEqual((self.sim.flags['Z'], self.sim.flags['PV'], self.sim.flags['H'], self.sim.flags['N'], self.sim.flags['C']), (1, 1, 0, 0, 0))

        self.sim.regs['A'] = 0xF0
        self.run_op('and', '15')
        self.assertEqual((self.sim.regs['A'], self.sim.flags['Z'], self.sim.flags['PV'], self.sim.flags['H'], self.sim.flags['N'], self.sim.flags['C']), (0, 1, 1, 1, 0, 0))

    def test_inc_dec_set_flags_but_preserve_carry(self):
        self.sim.regs['A'] = 0x7F
        self.sim.flags['C'] = 1
        self.run_op('inc', 'a')
        self.assertEqual(self.sim.regs['A'], 0x80)
        self.assertEqual((self.sim.flags['S'], self.sim.flags['PV'], self.sim.flags['H'], self.sim.flags['N'], self.sim.flags['C']), (1, 1, 1, 0, 1))

        self.sim.regs['A'] = 0x80
        self.run_op('dec', 'a')
        self.assertEqual(self.sim.regs['A'], 0x7F)
        self.assertEqual((self.sim.flags['PV'], self.sim.flags['H'], self.sim.flags['N'], self.sim.flags['C']), (1, 1, 1, 1))

    def test_bit_sets_z_pv_h_and_preserves_carry(self):
        self.sim.regs['A'] = 0x80
        self.sim.flags['C'] = 1
        self.run_op('bit', '7,a')
        self.assertEqual((self.sim.flags['S'], self.sim.flags['Z'], self.sim.flags['PV'], self.sim.flags['H'], self.sim.flags['N'], self.sim.flags['C']), (1, 0, 0, 1, 0, 1))

        self.run_op('bit', '0,a')
        self.assertEqual((self.sim.flags['S'], self.sim.flags['Z'], self.sim.flags['PV'], self.sim.flags['C']), (0, 1, 1, 1))

    def test_16_bit_arithmetic_and_flag_preservation(self):
        self.sim.set16('H', 'L', 0x0FFF)
        self.sim.set16('B', 'C', 1)
        self.sim.flags.update({'S': 1, 'Z': 1, 'PV': 1, 'C': 1})
        self.run_op('add', 'hl,bc')
        self.assertEqual(self.sim.get16('H', 'L'), 0x1000)
        self.assertEqual((self.sim.flags['S'], self.sim.flags['Z'], self.sim.flags['PV'], self.sim.flags['H'], self.sim.flags['N'], self.sim.flags['C']), (1, 1, 1, 1, 0, 0))

        self.sim.set16('H', 'L', 0x1000)
        self.sim.set16('B', 'C', 0x0FFF)
        self.sim.flags['C'] = 1
        self.run_op('sbc', 'hl,bc')
        self.assertEqual(self.sim.get16('H', 'L'), 0)
        self.assertEqual((self.sim.flags['Z'], self.sim.flags['H'], self.sim.flags['PV'], self.sim.flags['N'], self.sim.flags['C']), (1, 1, 0, 1, 0))

    def test_rotate_shift_scf_and_af_round_trip(self):
        self.sim.regs['A'] = 0x80
        self.sim.flags.update({'S': 1, 'Z': 1, 'PV': 1, 'H': 1, 'N': 1})
        self.run_op('rlca', '')
        self.assertEqual((self.sim.regs['A'], self.sim.flags['S'], self.sim.flags['Z'], self.sim.flags['PV'], self.sim.flags['C'], self.sim.flags['H'], self.sim.flags['N']), (1, 1, 1, 1, 1, 0, 0))
        self.run_op('scf', '')
        self.assertEqual((self.sim.flags['H'], self.sim.flags['N'], self.sim.flags['C']), (0, 0, 1))

        self.sim.flags.update({'S': 1, 'Z': 1, 'H': 1, 'PV': 1, 'N': 1, 'C': 1})
        packed = self.interp.flags_byte()
        self.sim.flags.update({key: 0 for key in self.sim.flags})
        self.interp.set_flags_byte(packed)
        self.assertEqual(self.interp.flags_byte(), packed)

    def test_exx_swaps_bc_de_hl_keeps_af_and_moves_overlays(self):
        self.sim.regs.update({'A': 0x11, 'B': 1, 'C': 2, 'D': 3, 'E': 4, 'H': 5, 'L': 6})
        self.sim.flags.update({'C': 1, 'Z': 1})
        self.sim.tuple_regs16['DE'] = ('RETIDX', 7)
        self.run_op('exx', '')
        self.assertEqual([self.sim.regs[r] for r in 'BCDEHL'], [0] * 6)
        self.assertEqual([self.sim.alt_regs[r] for r in 'BCDEHL'], [1, 2, 3, 4, 5, 6])
        self.assertEqual((self.sim.regs['A'], self.sim.flags['C'], self.sim.flags['Z']), (0x11, 1, 1))
        self.assertEqual((self.sim.tuple_regs16, self.sim.alt_tuple_regs16), ({}, {'DE': ('RETIDX', 7)}))
        self.sim.regs.update({'H': 0x12, 'L': 0x34})
        self.run_op('exx', '')
        self.assertEqual([self.sim.regs[r] for r in 'BCDEHL'], [1, 2, 3, 4, 5, 6])
        self.assertEqual((self.sim.alt_regs['H'], self.sim.alt_regs['L']), (0x12, 0x34))
        self.assertEqual(self.sim.tuple_regs16, {'DE': ('RETIDX', 7)})

    def test_adc_hl_and_ccf(self):
        self.sim.regs.update({'H': 0x7F, 'L': 0xFF, 'B': 0x00, 'C': 0x00})
        self.sim.flags['C'] = 1
        self.run_op('adc', 'hl,bc')                     # 7FFF + 0 + 1: signed overflow, half carry
        self.assertEqual((self.interp.get_reg16('HL'), self.sim.flags['S'], self.sim.flags['Z'], self.sim.flags['H'],
                          self.sim.flags['PV'], self.sim.flags['N'], self.sim.flags['C']), (0x8000, 1, 0, 1, 1, 0, 0))
        self.sim.regs.update({'B': 0x80, 'C': 0x00})
        self.run_op('adc', 'hl,bc')                     # 8000 + 8000: carry out, zero, overflow
        self.assertEqual((self.interp.get_reg16('HL'), self.sim.flags['Z'], self.sim.flags['PV'], self.sim.flags['C']),
                         (0x0000, 1, 1, 1))
        self.sim.regs.update({'H': 0x12, 'L': 0x34})
        self.sim.flags['C'] = 0
        self.run_op('adc', 'hl,hl')
        self.assertEqual((self.interp.get_reg16('HL'), self.sim.flags['C']), (0x2468, 0))
        self.sim.flags.update({'S': 1, 'Z': 1, 'PV': 1, 'N': 1, 'C': 1, 'H': 0})
        self.run_op('ccf', '')
        self.assertEqual((self.sim.flags['S'], self.sim.flags['Z'], self.sim.flags['PV'], self.sim.flags['N'],
                          self.sim.flags['H'], self.sim.flags['C']), (1, 1, 1, 0, 1, 0))
        self.run_op('ccf', '')
        self.assertEqual((self.sim.flags['H'], self.sim.flags['C']), (0, 1))

    def test_shifts_and_rotates_work_on_hl_memory(self):
        self.sim.regs.update({'H': 0x80, 'L': 0x00})
        self.sim.mem[0x8000] = 0x81
        self.sim.flags['C'] = 0
        self.run_op('rr', '(HL)')
        self.assertEqual((self.sim.mem[0x8000], self.sim.flags['C']), (0x40, 1))
        self.run_op('rl', '(HL)')
        self.assertEqual((self.sim.mem[0x8000], self.sim.flags['C']), (0x81, 0))
        self.run_op('srl', '(HL)')
        self.assertEqual((self.sim.mem[0x8000], self.sim.flags['C']), (0x40, 1))
        self.run_op('sla', '(HL)')
        self.assertEqual((self.sim.mem[0x8000], self.sim.flags['C']), (0x80, 0))

    def test_ldir_preserves_sz_c_and_clears_hn_pv_on_completion(self):
        self.sim.set16('H', 'L', 0x8000)
        self.sim.set16('D', 'E', 0x9000)
        self.sim.set16('B', 'C', 2)
        self.sim.wb(0x8000, 0x12)
        self.sim.wb(0x8001, 0x34)
        self.sim.flags.update({'S': 1, 'Z': 1, 'C': 1, 'PV': 1, 'H': 1, 'N': 1})
        self.run_op('ldir', '')
        self.assertEqual((self.sim.rb(0x9000), self.sim.rb(0x9001)), (0x12, 0x34))
        self.assertEqual(self.sim.get16('B', 'C'), 0)
        self.assertEqual((self.sim.flags['S'], self.sim.flags['Z'], self.sim.flags['C'], self.sim.flags['PV'], self.sim.flags['H'], self.sim.flags['N']), (1, 1, 1, 0, 0, 0))

    def test_parity_conditions_follow_pv(self):
        self.sim.flags['PV'] = 1
        self.assertTrue(self.interp.check_cond('pe'))
        self.assertFalse(self.interp.check_cond('po'))
        self.sim.flags['PV'] = 0
        self.assertTrue(self.interp.check_cond('po'))
        self.assertFalse(self.interp.check_cond('pe'))

    def test_jr_rejects_conditions_not_in_its_z80_form(self):
        with self.assertRaisesRegex(ValueError, 'unsupported JR condition'):
            self.run_op('jr', 'pe,DEST')


if __name__ == '__main__':
    unittest.main()
