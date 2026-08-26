"""
Source-level Z80 interpreter. Parses the actual project assembly source
directly (no separate assembly step) and executes it against a
simulated register/memory/stack state, resolving this project's own
local-label scoping (dot-prefixed labels scoped to their nearest
preceding global label) for jumps and calls.

Built to settle a real, reproduced bug empirically: STORAGE_LOAD_STAGE
reaches 11 (block copied) but never reaches 4 (load complete), despite
independent Python simulations of every individual routine involved
(.report_load_progress's own loop, .bitmap_all_set, MATH_UDIV16 for
divisor=1, the MATH_MULTIPLY16/DIVIDE16 register handoff) all checking
out correct in isolation. This runs the ACTUAL call chain -- including
STORAGE_REPORT_PROGRESS's hook mechanism into BASIC_DRAW_STATUS_LINE,
called from a deeper stack position than the earlier, known-working
"LOADING 0%" call -- to see what really happens, instruction by
instruction, rather than trusting another isolated simulation.
"""
import re

SYSVARS = {
    'STORAGE_BLOCK_COUNT': 0x60DC,
    'STORAGE_CURRENT_ID': 0x60DD,
    'STORAGE_BLOCK_BITMAP': 0x60DE,
    'STORAGE_OP_STATE': 0x60D7,
    'STORAGE_PROGRESS_PCT': 0x60D8,
    'STORAGE_BLOCKS_LOST': 0x60D9,
    'STORAGE_PROGRESS_HOOK': 0x60DA,
    'STORAGE_LOAD_STAGE': 0x60F4,
    'STATUS_BUF': 0x5FBC,
    'STATUS_WRITE_PTR': 0x5FDC,
    'LAST_STATUS_TEXT': 0x5FDE,  # placeholder address, unused content
    'DELETE_INVALID_FLAG': 0x6000,  # placeholder, not relevant here
    'STORAGE_CMD_INVALID_FLAG': 0x6001,  # placeholder, not relevant here
    'STORAGE_PILOT_LAST_EDGE': 0x60F0,
    'STORAGE_BIT_MIN_SUM': 0x60F2,
    'STORAGE_HEADER_BUF': 0x60C7,
    'STORAGE_HEADER_FILENAME_LEN': 10,
    'STORAGE_BLOCK_SIZE': 128,
    'STORAGE_CONSECUTIVE_FAILS': 0x60F3,
    'STORAGE_LOAD_STAGE': 0x60F4,
    'STORAGE_BLOCK_COUNT': 0x60DC,
    'STORAGE_CURRENT_ID': 0x60DD,
    'EDIT_LINE_BUF': 0x8004,   # FIXED: was 0x5D04, a pre-$8000-migration
                               # address (wrong by the same +$2300 offset
                               # as everything else that moved — see
                               # sysvars.inc's own migration note). Never
                               # caught before because no earlier z80sim
                               # driver actually read/wrote real
                               # EDIT_LINE_BUF content — this session's
                               # word-wrap verification does.
    'DIV_DIVIDEND': 0x5FE2,
    'DIV_QUOT': 0x5FE4,
    'DIV_COUNTER': 0x5FE6,
    'MATH_SIGN': 0x5FE7,
    'MSG_LOADING_PREFIX': 0x7000,   # placeholder data addresses --
    'MSG_PERCENT_SIGN': 0x7010,     # content doesn't matter, only
    'MSG_SAVED': 0x7020,            # that calls to string routines
    'MSG_LOADED': 0x7030,           # using them don't crash
    'MSG_SAVING_PREFIX': 0x7040,
    'MSG_LOADED_ERRORS_PREFIX': 0x7050,
    'MSG_BLOCKS_LOST_SUFFIX': 0x7060,
    'MSG_LOAD_FAILED': 0x7070,
    'MSG_SAVE_FAILED_TOO_LARGE': 0x7080,
    'MSG_DIAG_STAGE_PREFIX': 0x7090,
    'MSG_DIAG_PILOT_PREFIX': 0x70A0,
    'MSG_DIAG_SUM_PREFIX': 0x70B0,
    'MSG_INVALID_RANGE': 0x70C0,
    'MSG_INVALID_FILENAME': 0x70D0,
    # EDITOR_WRAP_CALC / EDITOR_WRAP_OFFSET_TO_ROWCOL verification —
    # current values from include/sysvars.inc as of the word-wrap
    # feature's introduction; see that file if these drift.
    'EDIT_LINE_BUF_LEN': 128,
    'WRAP_MAX_ROWS': 8,
    'EDIT_WRAP_COUNT': 0x94D8,
    'EDIT_WRAP_START': 0x94D9,
    'EDIT_WRAP_LEN': 0x94E1,
    'WRAP_TEXT_PTR': 0x94E9,
    'WRAP_REMAIN': 0x94EB,
    'WRAP_START_OFS': 0x94EC,
    'WRAP_ROW_IDX': 0x94ED,
    # BASIC_PRINT_LINE_HIGHLIGHTED verification — current values from
    # include/sysvars.inc as of the word-wrap feature's introduction.
    'HILITE_KW_LEN': 0x8229,
    'HILITE_COL': 0x822A,
    'HILITE_ROW': 0x822B,
    'HILITE_LINE_BASE': 0x94EE,
    'HILITE_WRAP_ROW': 0x94F0,
    'HILITE_LINE_START_ROW': 0x94F1,
    'HILITE_ROW_START': 0x94F2,
    'HILITE_ROW_LEN': 0x94F3,
    'PENDING_DELETE_POS': 0x83C1,
    'EDIR_UP': 0,
    'EDIR_DOWN': 1,
    'EDIR_LEFT': 2,
    'EDIR_RIGHT': 3,
    'EDIR_HOME': 4,
    'EDIR_END': 5,
    'EDIR_DELETE_LINE': 8,
    'EDIR_INSERT_LINE': 9,
    'EDIR_NEXT_ERROR': 10,
    'EDIR_PREV_ERROR': 11,
    'NAV_TOTAL': 0x82B6,
    'SCROLL_OWN_ROWS': 0x94F6,
    'ROWS_BEFORE_IDX': 0x94F7,
    'ROWS_BEFORE_TOTAL': 0x94F9,
    'ROWS_BEFORE_PTR': 0x94FB,
    'COUNT_TMP': 0x82B8,
    'FIND_REMAINING': 0x82BA,
    'HILITE_PLAIN_MODE': 0x94FD,
    'SCAN_STMT_POS': 0x82EA,
    'GOTO_TARGET': 0x82E8,
    'CUR_EXEC_STMT': 0x82EC,
    'PENDING_ERROR_MSG': 0x82EE,
    'CHECK_ERROR_COUNT': 0x82F4,
    'CHECK_FIRST_ERROR_STMT': 0x82F6,
    'CHECK_ERROR_LIST': 0x82F8,
    'VAR_TABLE': 0x81EA,
    'EXPR_PARSE_PTR': 0x82E0,
    # Structured FOR/NEXT verification — current values from
    # include/sysvars.inc as of the FOR/NEXT feature's introduction.
    'FOR_STACK_MAX': 8,
    'FOR_STACK_ENTRY_LEN': 7,
    'FOR_STACK': 0x9504,
    'FOR_STACK_DEPTH': 0x953C,
    'FOR_TEMP_VAR': 0x953D,
    'FOR_TEMP_START': 0x953E,
    'FOR_TEMP_END': 0x9540,
    'FOR_TEMP_STEP': 0x9542,
    'FOR_SCAN_POS': 0x9544,
    'FOR_SCAN_DEPTH': 0x9546,
    'FOR_ENTRY_PTR': 0x9547,
    'FOR_NEXT_NEWVAL': 0x9549,
    # placeholder data addresses for the new keyword strings -- content
    # doesn't matter to this dict itself; a real driver script pokes
    # the actual "FOR\0"/"NEXT\0"/"TO\0"/"STEP\0" bytes in before
    # exercising BASIC_MATCH_KEYWORD_BOUNDARY for real (see MSG_* /
    # KW_TO's own placeholder precedent above -- this simulator has no
    # memory image for DB data labels otherwise)
    'KW_FOR': 0x7100,
    'KW_NEXT': 0x7110,
    'KW_TO': 0x7120,
    'KW_STEP': 0x7130,
    # error-message placeholders -- BASIC_SET_PENDING_ERROR only ever
    # stores this pointer, never dereferences it, so content doesn't
    # matter here, only that the symbol resolves to something numeric
    'MSG_SYNTAX_ERROR': 0x7200,
    'MSG_MISSING_NEXT': 0x7210,
    'MSG_NEXT_WITHOUT_FOR': 0x7220,
    'MSG_NEXT_MISMATCH': 0x7230,
    'MSG_FOR_TOO_DEEP': 0x7240,
    'SEARCH_TARGET': 0x8318,
    # BASIC_REDRAW_PROGRAM integration verification.
    'PROG_END': 0x8104,
    'CUR_EDIT_POS': 0x82AE,
    'CUR_EDIT_INDEX': 0x82B0,
    'VIEW_TOP_INDEX': 0x82B2,
    'LINE_IS_ERROR': 0x831A,
    'ROW_SHADOW_POS': 0x831D,
    'ROW_SHADOW_FLAGS': 0x834D,
    'LAST_RENDERED_ROWS': 0x8365,
    'LINE_LEN_SIZE': 2,
    'PROG_AREA_START': 0x94FE,
    'DETOK_BUF': 0x822C,
    'BASIC_ACTIVE_ROW': 0x82AC,
    'PROGRAM_ROW': 0x82AD,
    'STMT_ROW_COUNT': 0x94F4,
    'STMT_ROW_IDX': 0x94F5,
    'ATTR_ERROR_RED': 0x3A,
    'ATTR_ADDR': 0x5800,
    'EDIT_BUF_OFFSET': 0x8002,
    'ATTR_STATUS_BAR': 0x47,  # this one's a constant value, not addr --
                              # handled specially below
}

STUB_ROUTINES = {
    'BASIC_APPEND_STR', 'BASIC_NUM_TO_STRING', 'GFX_CLEAR_ROW_TEXT',
    'GFX_PRINT_STRING', 'GFX_SET_ATTR',
    # added for the word-wrap BASIC_PRINT_LINE_HIGHLIGHTED verification:
    # real pixel drawing isn't in question here, only whether the right
    # (row, col, char) triples get passed to these two, captured via
    # trace_log instead (see driver script) rather than real behavior.
    # BASIC_DETECT_KEYWORD_PREFIX is also stubbed for that verification
    # specifically — its own keyword-table-walk is separately proven
    # elsewhere and out of scope; the driver pre-seeds HILITE_KW_LEN
    # directly instead of exercising the real detection logic.
    'GFX_PUTCHAR', 'GFX_PUTCHAR_BOLD', 'BASIC_DETECT_KEYWORD_PREFIX',
    # added for the BASIC_REDRAW_PROGRAM integration test: real pixel
    # clearing / attribute setting / status-line drawing aren't in
    # question, only whether the right rows get cleared/colored and
    # in what order — captured via trace_log. BASIC_IS_ERROR_STATEMENT
    # is scripted (see driver) rather than stubbed plain, since the
    # test wants to control which statement is "flagged" per call.
    'GFX_CLEAR_ROW', 'GFX_INVERT_ATTR', 'BASIC_DRAW_STATUS_LINE',
    'BASIC_COUNT_STATEMENTS',
}

# Scripted stubs: for routines whose REAL internals this simulator
# can't run (real port I/O -- STORAGE_WAIT_PILOT/STORAGE_RECEIVE_BLOCK
# do real tape timing this tool has no model for) but whose CALLING
# CONTRACT (what registers/flags they set) needs to be honored so the
# surrounding control flow can still be tested faithfully. Each value
# is a list of (regs_to_set, flags_to_set) pairs, consumed in order
# on successive calls -- the last entry repeats if the routine is
# called more times than scripted. Set via Interp.set_script() before
# running.


class Halt(Exception):
    pass

class Z80Sim:
    def __init__(self):
        self.regs = {'A':0,'B':0,'C':0,'D':0,'E':0,'H':0,'L':0,
                     'IX':0,'IY':0,'SP':0xFF00}
        self.flags = {'Z':0,'C':0,'S':0,'PV':0}
        self.alt_a = 0             # A' -- see 'ex af,af'' handler below
        self.alt_flags = {'Z':0,'C':0,'S':0,'PV':0}
        self.mem = bytearray(65536)
        self.stack_list = []  # logical push/pop stack -- see push/pop
        self.tuple_regs16 = {}  # overlay for code-address markers held
                                 # in a 16-bit register pair -- see
                                 # Interp.get_reg16/set_reg16
        self.io_writes = []     # [(port, value), ...] -- OUT is
                                 # recorded here, not simulated: no
                                 # fake device behavior is modeled
                                 # behind any port (see Interp's own
                                 # 'out' handler for why), so this is
                                 # purely for a test driver to assert
                                 # against, e.g. "did the code write
                                 # the expected byte to the expected
                                 # port", not "did paging visibly
                                 # happen" -- that still needs a real
                                 # emulator or hardware

    # ---- memory helpers ----
    def rb(self, addr): return self.mem[addr & 0xFFFF]
    def wb(self, addr, val):
        addr &= 0xFFFF
        # Real hardware: $0000-$3FFF is Home ROM -- a write there is a
        # silent no-op, never an error, on the real machine. Matching
        # that exactly (rather than raising, or just writing through)
        # is what actually catches this class of bug: this project
        # shipped this exact mistake once before (PRINT_ATTR_SCRATCH,
        # a `DB 0` scratch byte accidentally placed in ROM code —
        # see GFX_PRINT_STRING_ATTR's own header) and then again
        # (2026-08-18, rom/test_exrom_isolation.asm's RESULT_* bytes)
        # WITHOUT this simulator ever having a way to catch either one,
        # since a flat bytearray write "succeeds" regardless of
        # address. A test asserting a value written to ROM would have
        # correctly FAILED against this no-op semantics, exactly as it
        # did on real hardware -- rather than silently passing here
        # while failing for real later. allow_rom_writes exists for
        # the rare legitimate case (seeding fake ROM content purely
        # for a test's own setup, never a real write the code under
        # test performs) -- default False.
        if addr < 0x4000 and not getattr(self, 'allow_rom_writes', False):
            return
        self.mem[addr] = val & 0xFF
    def rw(self, addr): return self.rb(addr) | (self.rb(addr+1) << 8)
    def ww(self, addr, val):
        self.wb(addr, val & 0xFF)
        self.wb(addr+1, (val >> 8) & 0xFF)

    def get16(self, hi, lo):
        return (self.regs[hi] << 8) | self.regs[lo]
    def set16(self, hi, lo, val):
        val &= 0xFFFF
        self.regs[hi] = (val >> 8) & 0xFF
        self.regs[lo] = val & 0xFF

    def push(self, val):
        # Logical list-based stack (not byte-array-backed) -- Z80's
        # real stack uniformly holds both plain 16-bit values (PUSH
        # BC) and, via the "push a label address then JP" idiom this
        # project's hook mechanism uses, code-address markers. A
        # single Python list handles both without needing two
        # separate stack representations.
        self.regs['SP'] = (self.regs['SP'] - 2) & 0xFFFF
        self.stack_list.append(val)
    def pop(self):
        if not self.stack_list:
            raise Halt("stack underflow -- popped with nothing pushed")
        self.regs['SP'] = (self.regs['SP'] + 2) & 0xFFFF
        return self.stack_list.pop()

    def set_flags_from(self, val8):
        v = val8 & 0xFF
        self.flags['Z'] = 1 if v == 0 else 0
        self.flags['S'] = 1 if v & 0x80 else 0

class Program:
    def __init__(self):
        self.lines = []  # (global_scope, local_label_or_None, mnemonic, operand)
        self.label_index = {}  # (scope_or_None, name) -> line index
        self.entry_points = {}  # global_name -> line index

    def load_file(self, path, only_labels=None):
        current_scope = None
        with open(path) as f:
            for raw in f:
                line = raw.strip()
                if not line:
                    continue
                m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*):$', line)
                if m:
                    name = m.group(1)
                    current_scope = name
                    self.entry_points[name] = len(self.lines)
                    self.label_index[(None, name)] = len(self.lines)
                    self.lines.append((current_scope, name, None, None))
                    continue
                m = re.match(r'^(\.[A-Za-z_][A-Za-z0-9_]*):(.*)$', line)
                if m:
                    name = m.group(1)
                    self.label_index[(current_scope, name)] = len(self.lines)
                    rest = m.group(2).strip()
                    if rest:
                        mn, op = self._split_instr(rest)
                        self.lines.append((current_scope, name, mn, op))
                    else:
                        self.lines.append((current_scope, name, None, None))
                    continue
                mn, op = self._split_instr(line)
                if mn is None:
                    continue
                self.lines.append((current_scope, None, mn, op))

    def _split_instr(self, text):
        text = text.split(';')[0].strip()
        if not text:
            return None, None
        parts = text.split(None, 1)
        mn = parts[0].lower()
        op = parts[1].strip() if len(parts) > 1 else ''
        return mn, op

    def resolve_label(self, scope, name):
        if name.startswith('.'):
            if (scope, name) in self.label_index:
                return self.label_index[(scope, name)]
            raise KeyError(f"local label {name} not found in scope {scope}")
        if name in self.entry_points:
            return self.entry_points[name]
        raise KeyError(f"global label {name} not found")


def parse_val(token, sim, prog_scope):
    token = token.strip()
    if token in SYSVARS:
        return SYSVARS[token]
    if token.startswith('$'):
        return int(token[1:], 16)
    if token.startswith('%'):
        return int(token[1:], 2)
    if re.match(r'^-?\d+$', token):
        return int(token)
    if token.startswith("'") and token.endswith("'") and len(token) == 3:
        return ord(token[1])
    if token.startswith('"') and token.endswith('"') and len(token) == 3:
        # This project's own source uses double-quoted single-char
        # literals throughout (cp "-", cp "(", cp " ", etc. -- sjasmplus
        # accepts both ' and " for character constants) -- previously
        # unhandled here, since no routine exercised through this
        # simulator before now happened to compare against one.
        return ord(token[1])
    m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)\s*([+-])\s*(\d+)$', token)
    if m:
        base_name, op, offset = m.group(1), m.group(2), int(m.group(3))
        if base_name not in SYSVARS:
            raise ValueError(f"cannot parse value token: {token!r} -- "
                              f"base symbol {base_name!r} not in SYSVARS")
        base = SYSVARS[base_name]
        return base + offset if op == '+' else base - offset
    m = re.match(r'^(["\'])(.)\1\s*([+-])\s*(\d+)$', token)
    if m:
        # "9" + 1 style: a quoted-char base with an arithmetic offset --
        # this project's own boundary checks use this constantly (e.g.
        # cp "9"+1, cp "Z"+1) to mean "one past this character".
        _, ch, op, offset = m.groups()
        base = ord(ch)
        offset = int(offset)
        return base + offset if op == '+' else base - offset
    raise ValueError(f"cannot parse value token: {token!r}")

REG16_PAIRS = {'BC': ('B','C'), 'DE': ('D','E'), 'HL': ('H','L')}

class Interp:
    def __init__(self, prog: Program, sim: Z80Sim):
        self.prog = prog
        self.sim = sim
        self.call_stack = []  # for trace/debug only
        self.trace_log = []
        self.max_trace = 5000
        self.scripts = {}       # routine name -> list of (regs, flags)
        self.script_pos = {}    # routine name -> next index to consume

    def set_script(self, routine_name, calls):
        """calls: list of (regs_dict, flags_dict) applied in order on
        successive calls to routine_name; the last entry repeats if
        called more times than scripted."""
        self.scripts[routine_name] = calls
        self.script_pos[routine_name] = 0

    def get_reg16(self, name):
        s = self.sim
        # A tuple marker (('RETIDX', idx)) overlay takes precedence --
        # used only for the "ld de,.label / push de" manual return-
        # address idiom this codebase's hook mechanism relies on. Real
        # 8-bit/16-bit writes to the same register pair clear the
        # overlay (see set_reg16), so this can't go stale.
        if name in s.tuple_regs16:
            return s.tuple_regs16[name]
        if name == 'SP':
            return s.regs['SP']
        if name == 'IX':
            return s.regs['IX']
        if name == 'IY':
            return s.regs['IY']
        hi, lo = REG16_PAIRS[name]
        return s.get16(hi, lo)

    def set_reg16(self, name, val):
        s = self.sim
        if isinstance(val, tuple):
            s.tuple_regs16[name] = val
            return
        s.tuple_regs16.pop(name, None)
        val &= 0xFFFF
        if name == 'SP':
            s.regs['SP'] = val
            return
        if name == 'IX':
            s.regs['IX'] = val
            return
        if name == 'IY':
            s.regs['IY'] = val
            return
        hi, lo = REG16_PAIRS[name]
        s.set16(hi, lo, val)

    IX_OFFSET_RE = re.compile(r'^(ix|iy)\s*([+-])\s*(\d+)$', re.IGNORECASE)

    def resolve_ix_offset_addr(self, inner):
        """Resolves an '(ix+d)'/'(ix-d)'/'(iy+d)'/'(iy-d)' operand's
        inner text to a real numeric address, using IX/IY's CURRENT
        RUNTIME value -- not a symbolic label lookup like parse_val's
        own SYSVAR+-offset case. Requires IX/IY to already hold a real
        integer address (e.g. seeded directly by a driver script) --
        raises clearly if it instead holds a code-address marker
        (the tuple set by "ld ix,SOME_LABEL"), since this simulator
        has no real memory image for arbitrary DB/DW data labels; a
        caller walking a data table needs to seed IX/IY with a real
        address itself. Returns None if inner doesn't match this
        pattern at all, so callers can fall through to other cases.
        """
        m = self.IX_OFFSET_RE.match(inner.strip())
        if not m:
            return None
        reg, sign, digits = m.group(1).upper(), m.group(2), int(m.group(3))
        base = self.sim.regs[reg]
        if isinstance(base, tuple):
            raise ValueError(
                f"{reg} holds a code-address marker ({base}), not a real "
                f"memory address -- seed {reg} with an actual integer "
                f"address before indexing through it (this simulator has "
                f"no memory image for DB/DW data labels)")
        return (base + digits if sign == '+' else base - digits) & 0xFFFF

    def resolve_operand_value(self, tok, scope):
        """Resolve a source (right-hand) operand to an integer value."""
        tok = tok.strip()
        s = self.sim
        if tok in ('A','B','C','D','E','H','L'):
            return s.regs[tok]
        if tok in ('BC','DE','HL','IX','IY','SP'):
            return self.get_reg16(tok)
        if tok == '(HL)':
            return s.rb(self.get_reg16('HL'))
        if tok == '(BC)':
            return s.rb(self.get_reg16('BC'))
        if tok == '(DE)':
            return s.rb(self.get_reg16('DE'))
        m = re.match(r'^\((.+)\)$', tok)
        if m:
            inner = m.group(1).strip()
            ix_addr = self.resolve_ix_offset_addr(inner)
            addr = ix_addr if ix_addr is not None else parse_val(inner, s, scope)
            return s.rb(addr)
        return parse_val(tok, s, scope)

    def resolve_addr(self, tok, scope):
        tok = tok.strip()
        if tok == '(HL)':
            return self.get_reg16('HL')
        if tok == '(BC)':
            return self.get_reg16('BC')
        if tok == '(DE)':
            return self.get_reg16('DE')
        m = re.match(r'^\((.+)\)$', tok)
        if m:
            inner = m.group(1).strip()
            ix_addr = self.resolve_ix_offset_addr(inner)
            return ix_addr if ix_addr is not None else parse_val(inner, self.sim, scope)
        raise ValueError(f"not a memory operand: {tok!r}")

    def set_reg8(self, name, val):
        self.sim.regs[name] = val & 0xFF

    def split_operands(self, op):
        # split on top-level comma (operand strings here never contain
        # nested commas within parens for the instructions we support).
        # Also tracks quote state (single OR double -- this project's
        # source uses double-quoted char literals like "," throughout)
        # so a comma INSIDE a character literal, e.g. `cp ","`, isn't
        # mistaken for an operand separator -- previously unhandled
        # here, since no routine exercised through this simulator
        # before now happened to compare against a comma literal.
        parts = []
        depth = 0
        in_quote = None  # None, or the quote char currently open
        cur = ''
        for ch in op:
            if in_quote:
                if ch == in_quote:
                    in_quote = None
                cur += ch
                continue
            if ch in ('"', "'"):
                in_quote = ch
                cur += ch
                continue
            if ch == '(':
                depth += 1
            elif ch == ')':
                depth -= 1
            if ch == ',' and depth == 0:
                parts.append(cur.strip())
                cur = ''
            else:
                cur += ch
        if cur.strip():
            parts.append(cur.strip())
        return [self.normalize_token(p) for p in parts]

    REGISTER_NAMES = {'A','B','C','D','E','H','L','AF','BC','DE','HL','IX','IY','SP'}

    def normalize_token(self, tok):
        # Source uses lowercase register names ("push bc", "ld a,b")
        # but our internal comparisons are hardcoded uppercase --
        # normalize register tokens (bare or parenthesized) to
        # uppercase, leaving sysvar names/numeric literals/labels
        # (which are case-sensitive or don't collide) untouched.
        tok = tok.strip()
        m = re.match(r'^\((\w+)\)$', tok)
        if m:
            inner = m.group(1)
            if inner.upper() in self.REGISTER_NAMES:
                return f'({inner.upper()})'
            return tok
        if tok.upper() in self.REGISTER_NAMES:
            return tok.upper()
        return tok

    def run(self, start_scope, start_label, max_steps=200000):
        idx = self.prog.resolve_label(None, start_scope) if start_label is None \
              else self.prog.resolve_label(start_scope, start_label)
        steps = 0
        while True:
            steps += 1
            if steps > max_steps:
                raise Halt(f"exceeded max_steps ({max_steps}) -- likely infinite loop; "
                            f"last ~20 trace entries: {self.trace_log[-20:]}")
            scope, label, mn, op = self.prog.lines[idx]
            self.current_idx = idx        # needed by 'call' to compute its
                                          # own return address — real
                                          # (non-stub, non-scripted) CALLs
                                          # were never exercised through
                                          # this simulator before, so this
                                          # was never set at all
            if mn is None:
                idx += 1
                continue
            if len(self.trace_log) < self.max_trace:
                self.trace_log.append((scope, label, mn, op, dict(self.sim.regs), dict(self.sim.flags)))
            result = self.exec_instr(scope, mn, op)
            if result == 'HALT':
                return
            if isinstance(result, int):
                idx = result
            else:
                idx += 1

    def exec_instr(self, scope, mn, op):
        s = self.sim
        parts = self.split_operands(op) if op else []

        if mn == 'ld':
            dst, src = parts[0].strip(), parts[1].strip()
            if dst in ('A','B','C','D','E','H','L'):
                val = self.resolve_operand_value(src, scope)
                self.set_reg8(dst, val)
            elif dst in ('BC','DE','HL','IX','IY','SP'):
                if src.startswith('(') and src.endswith(')'):
                    addr = self.resolve_addr(src, scope)
                    val = s.rw(addr)
                elif src.startswith('.') or (re.match(r'^[A-Za-z_][A-Za-z0-9_]*$', src) and src not in ('BC','DE','HL','IX','IY','SP') and src not in SYSVARS):
                    # a label reference (e.g. "ld de,.done") -- resolve
                    # to a code-address marker, not a numeric value, so
                    # a later PUSH + JP(HL)-then-RET can jump back here
                    idx = self.prog.resolve_label(scope, src)
                    val = ('RETIDX', idx)
                elif src in ('BC','DE','HL','IX','IY','SP'):
                    val = self.get_reg16(src)
                else:
                    val = parse_val(src, s, scope)
                self.set_reg16(dst, val)
            elif dst == '(HL)':
                val = self.resolve_operand_value(src, scope)
                s.wb(self.get_reg16('HL'), val)
            elif dst == '(DE)':
                val = self.resolve_operand_value(src, scope)
                s.wb(self.get_reg16('DE'), val)
            elif dst == '(BC)':
                val = self.resolve_operand_value(src, scope)
                s.wb(self.get_reg16('BC'), val)
            elif dst.startswith('(') and dst.endswith(')'):
                addr = self.resolve_addr(dst, scope)
                if src in ('BC','DE','HL','IX','IY','SP'):
                    s.ww(addr, self.get_reg16(src))
                else:
                    val = self.resolve_operand_value(src, scope)
                    s.wb(addr, val)
            else:
                raise ValueError(f"unhandled ld dst: {dst!r}")
            return None

        if mn == 'push':
            r = parts[0].strip()
            if r == 'af':
                r = 'AF'
            val = self.get_reg16(r) if r != 'AF' else ((s.regs['A']<<8) | self.flags_byte())
            s.push(val)
            return None
        if mn == 'pop':
            r = parts[0].strip()
            val = s.pop()
            if r.lower() == 'af':
                s.regs['A'] = (val >> 8) & 0xFF
                self.set_flags_byte(val & 0xFF)
            else:
                self.set_reg16(r, val)
            return None

        if mn == 'inc':
            r = parts[0].strip()
            if r in ('BC','DE','HL','IX','IY','SP'):
                self.set_reg16(r, (self.get_reg16(r)+1) & 0xFFFF)
            elif r == '(HL)':
                addr = self.get_reg16('HL')
                v = (s.rb(addr)+1) & 0xFF
                s.wb(addr, v)
                s.set_flags_from(v)
            else:
                v = (s.regs[r]+1) & 0xFF
                s.regs[r] = v
                s.set_flags_from(v)
            return None
        if mn == 'dec':
            r = parts[0].strip()
            if r in ('BC','DE','HL','IX','IY','SP'):
                self.set_reg16(r, (self.get_reg16(r)-1) & 0xFFFF)
            elif r == '(HL)':
                addr = self.get_reg16('HL')
                v = (s.rb(addr)-1) & 0xFF
                s.wb(addr, v)
                s.set_flags_from(v)
            else:
                v = (s.regs[r]-1) & 0xFF
                s.regs[r] = v
                s.set_flags_from(v)
            return None

        if mn == 'add':
            dst, src = parts[0].strip(), parts[1].strip()
            if dst == 'hl':
                dst = 'HL'
            if dst == 'HL':
                a16 = self.get_reg16('HL')
                b16 = self.get_reg16(src) if src in ('BC','DE','HL','SP') else parse_val(src, s, scope)
                res = (a16 + b16) & 0xFFFF
                s.flags['C'] = 1 if (a16+b16) > 0xFFFF else 0
                self.set_reg16('HL', res)
            elif dst in ('IX', 'IY'):
                # "add ix,bc" style table-pointer advance -- IX/IY must
                # already hold a real integer address (see
                # resolve_ix_offset_addr's own note), not a code-address
                # marker, or this raises via get_reg16 returning a tuple
                # that the bare integer arithmetic below can't use.
                a16 = self.get_reg16(dst)
                if isinstance(a16, tuple):
                    raise ValueError(
                        f"{dst} holds a code-address marker, not a real "
                        f"address -- seed it with an actual integer first")
                b16 = self.get_reg16(src) if src in ('BC','DE','HL','SP') else parse_val(src, s, scope)
                res = (a16 + b16) & 0xFFFF
                s.flags['C'] = 1 if (a16+b16) > 0xFFFF else 0
                self.set_reg16(dst, res)
            elif dst == 'a' or dst == 'A':
                val = self.resolve_operand_value(src, scope)
                res = s.regs['A'] + val
                s.flags['C'] = 1 if res > 0xFF else 0
                s.regs['A'] = res & 0xFF
                s.set_flags_from(s.regs['A'])
            return None
        if mn == 'adc':
            dst, src = parts[0].strip(), parts[1].strip()
            val = self.resolve_operand_value(src, scope)
            res = s.regs['A'] + val + s.flags['C']
            s.flags['C'] = 1 if res > 0xFF else 0
            s.regs['A'] = res & 0xFF
            s.set_flags_from(s.regs['A'])
            return None
        if mn == 'sbc':
            dst, src = parts[0].strip(), parts[1].strip()
            if dst.lower() == 'hl':
                b16 = self.get_reg16(src)
                a16 = self.get_reg16('HL')
                res = a16 - b16 - s.flags['C']
                s.flags['C'] = 1 if res < 0 else 0
                self.set_reg16('HL', res & 0xFFFF)
                # BUG FIX: the 16-bit sign flag must come from bit 15
                # of the full 16-bit result, not from whichever single
                # byte this used to pick via a truthy `or` fallback
                # (`(res&0xFFFF)&0xFF or ((res&0xFFFF)>>8)` — picks the
                # LOW byte whenever it's nonzero, so e.g. a genuinely
                # positive result like 0x0081 got its sign flag read
                # from the low byte 0x81's own bit 7, incorrectly
                # setting S=1 for a positive value). Found while
                # verifying GFX_LINE64: MATH_COMPARE16's `jp m` check
                # on a real HL=640,DE=511 case returned the wrong
                # answer purely because of this simulator bug, not
                # because of anything wrong in the ROM code itself —
                # confirmed by checking the raw SBC HL,DE result (129,
                # correct) against the (wrong) flag it produced.
                res16 = res & 0xFFFF
                s.flags['S'] = 1 if res16 & 0x8000 else 0
                s.flags['Z'] = 1 if res16 == 0 else 0
            else:
                val = self.resolve_operand_value(src, scope)
                res = s.regs['A'] - val - s.flags['C']
                s.flags['C'] = 1 if res < 0 else 0
                s.regs['A'] = res & 0xFF
                s.set_flags_from(s.regs['A'])
            return None
        if mn == 'sub':
            src = parts[0].strip()
            val = self.resolve_operand_value(src, scope)
            res = s.regs['A'] - val
            s.flags['C'] = 1 if res < 0 else 0
            s.regs['A'] = res & 0xFF
            s.set_flags_from(s.regs['A'])
            return None
        if mn == 'and':
            src = parts[0].strip()
            val = self.resolve_operand_value(src, scope)
            s.regs['A'] &= val
            s.flags['C'] = 0
            s.set_flags_from(s.regs['A'])
            return None
        if mn == 'or':
            src = parts[0].strip()
            val = self.resolve_operand_value(src, scope)
            s.regs['A'] |= val
            s.flags['C'] = 0
            s.set_flags_from(s.regs['A'])
            return None
        if mn == 'xor':
            src = parts[0].strip()
            val = self.resolve_operand_value(src, scope)
            s.regs['A'] ^= val
            s.flags['C'] = 0
            s.set_flags_from(s.regs['A'])
            return None
        if mn == 'cp':
            src = parts[0].strip()
            val = self.resolve_operand_value(src, scope)
            res = s.regs['A'] - val
            s.flags['C'] = 1 if res < 0 else 0
            s.set_flags_from(res & 0xFF)
            return None
        if mn == 'bit':
            # BIT n,r -- tests bit n of r, sets Z=1 if that bit is
            # clear (0 if set). Doesn't touch C. S set only for the
            # well-known "BIT 7,r" sign-check idiom (S = the tested
            # bit itself in that specific case) -- this project's
            # real code uses exactly that idiom (GFX_CIRCLE's own
            # 16-bit decision-variable sign check via BIT 7,H) and
            # nothing else, so this is the only case that needs to be
            # right; not a full BIT implementation for every n.
            bit_n = int(parts[0].strip())
            reg = parts[1].strip()
            val = self.resolve_operand_value(reg, scope)
            tested = (val >> bit_n) & 1
            s.flags['Z'] = 1 if tested == 0 else 0
            if bit_n == 7:
                s.flags['S'] = tested
            return None

        if mn in ('rrca',):
            a = s.regs['A']
            bit0 = a & 1
            s.regs['A'] = ((a >> 1) | (bit0 << 7)) & 0xFF
            s.flags['C'] = bit0
            return None
        if mn in ('rlca',):
            a = s.regs['A']
            bit7 = (a >> 7) & 1
            s.regs['A'] = ((a << 1) | bit7) & 0xFF
            s.flags['C'] = bit7
            return None
        if mn == 'rra':
            a = s.regs['A']
            oldc = s.flags['C']
            s.flags['C'] = a & 1
            s.regs['A'] = ((a >> 1) | (oldc << 7)) & 0xFF
            return None
        if mn == 'rla':
            a = s.regs['A']
            oldc = s.flags['C']
            s.flags['C'] = (a >> 7) & 1
            s.regs['A'] = ((a << 1) | oldc) & 0xFF
            return None
        if mn == 'sla':
            r = parts[0].strip()
            v = s.regs[r]
            s.flags['C'] = (v >> 7) & 1
            s.regs[r] = (v << 1) & 0xFF
            s.set_flags_from(s.regs[r])
            return None
        if mn == 'srl':
            r = parts[0].strip()
            v = s.regs[r]
            s.flags['C'] = v & 1
            s.regs[r] = (v >> 1) & 0xFF
            s.set_flags_from(s.regs[r])
            return None
        if mn == 'rr':
            r = parts[0].strip()
            v = s.regs[r]
            oldc = s.flags['C']
            s.flags['C'] = v & 1
            s.regs[r] = ((v >> 1) | (oldc << 7)) & 0xFF
            s.set_flags_from(s.regs[r])
            return None
        if mn == 'rl':
            r = parts[0].strip()
            v = s.regs[r]
            oldc = s.flags['C']
            s.flags['C'] = (v >> 7) & 1
            s.regs[r] = ((v << 1) | oldc) & 0xFF
            s.set_flags_from(s.regs[r])
            return None

        if mn == 'ex':
            a, b = parts[0].strip(), parts[1].strip()
            if a.lower() == 'de' and b.lower() == 'hl':
                de = self.get_reg16('DE')
                hl = self.get_reg16('HL')
                self.set_reg16('DE', hl)
                self.set_reg16('HL', de)
                return None
            # "af'" survives split_operands with its trailing quote
            # intact (not a real token boundary), so match loosely.
            if a.lower() == 'af' and b.lower().startswith("af'"):
                s.regs['A'], s.alt_a = s.alt_a, s.regs['A']
                s.flags, s.alt_flags = s.alt_flags, s.flags
                return None
            raise ValueError(f"unhandled ex operands: {op}")

        if mn == 'ldir':
            hl = self.get_reg16('HL'); de = self.get_reg16('DE'); bc = self.get_reg16('BC')
            while bc > 0:
                s.wb(de, s.rb(hl))
                hl = (hl+1)&0xFFFF; de=(de+1)&0xFFFF; bc=(bc-1)&0xFFFF
            self.set_reg16('HL', hl); self.set_reg16('DE', de); self.set_reg16('BC', bc)
            return None

        if mn == 'scf':
            s.flags['C'] = 1
            return None

        if mn in ('jr','jp'):
            if ',' in op and not op.strip().startswith('('):
                cond, target = [x.strip() for x in op.split(',', 1)]
                take = self.check_cond(cond)
                if not take:
                    return None
                return self.jump_target(target, scope, mn)
            else:
                target = op.strip()
                if target == '(hl)':
                    # JP (HL): HL holds a value that was itself loaded
                    # from memory (STORAGE_PROGRESS_HOOK) via a plain
                    # 16-bit read -- we store instruction indices
                    # directly in that memory slot (not real emulated
                    # addresses, since this isn't a byte-accurate
                    # simulation), so no conversion is needed, just use
                    # it directly as the next instruction index.
                    hl = self.get_reg16('HL')
                    if isinstance(hl, tuple):
                        return self.addr_to_index(hl)
                    return hl
                return self.jump_target(target, scope, mn)

        if mn == 'call':
            if ',' in op:
                cond, target = [x.strip() for x in op.split(',', 1)]
                if not self.check_cond(cond):
                    return None
            else:
                target = op.strip()
            target_upper = target.upper()
            if target_upper in self.scripts:
                # Scripted stub: apply this call's scripted regs/flags
                # (consuming one entry, repeating the last if the
                # routine's called more times than scripted), then
                # treat as a no-op return (no return address pushed,
                # matching the plain-stub behavior below) since the
                # real internals aren't being simulated.
                calls = self.scripts[target_upper]
                pos = self.script_pos[target_upper]
                idx_to_use = min(pos, len(calls) - 1)
                regs, flags = calls[idx_to_use]
                for k, v in regs.items():
                    if k in ('BC','DE','HL','IX','IY','SP'):
                        self.set_reg16(k, v)
                    else:
                        s.regs[k] = v & 0xFF
                for k, v in flags.items():
                    s.flags[k] = v
                self.script_pos[target_upper] = pos + 1
                return None
            if target_upper in STUB_ROUTINES:
                # Stub: treat as a no-op entirely -- do NOT push a
                # return address, since nothing will ever pop it.
                # Correctness of these leaf graphics/string routines
                # isn't in question here; only whether the call/return
                # mechanics of the REAL surrounding code survive.
                return None
            ret_idx = self.current_idx + 1
            s.push(('RETIDX', ret_idx))
            return self.jump_target(target, scope, mn)

        if mn == 'ret':
            if op:
                cond = op.strip()
                if not self.check_cond(cond):
                    return None
            val = s.pop()
            if isinstance(val, tuple) and val[0] == 'RETIDX':
                return val[1]
            if isinstance(val, tuple) and val[0] == 'HALT':
                raise Halt("clean stop: outermost RET reached (test entry point returned)")
            return self.addr_to_index(val)

        if mn == 'djnz':
            s.regs['B'] = (s.regs['B']-1) & 0xFF
            if s.regs['B'] != 0:
                return self.jump_target(op.strip(), scope, mn)
            return None

        if mn == 'di' or mn == 'ei':
            return None

        if mn == 'out':
            # Both real forms exist ('out (n),a' and 'out (c),r'), but
            # this project only ever uses 'out (port),a' -- the value
            # written is always A. Recorded to sim.io_writes, not
            # acted on: no device behavior is modeled behind any port
            # (see Z80Sim.__init__'s own comment on io_writes for why)
            # -- a test driver reads this list to assert what WAS
            # written, same spirit as checking a memory address, not
            # to simulate what a real chip would then do about it.
            parts2 = self.split_operands(op)
            port_tok, src = parts2[0].strip(), parts2[1].strip()
            port = parse_val(port_tok.strip('()'), s, scope)
            val = self.resolve_operand_value(src, scope)
            s.io_writes.append((port & 0xFF, val & 0xFF))
            return None

        raise ValueError(f"unhandled mnemonic: {mn} {op}")

    def check_cond(self, cond):
        s = self.sim
        c = cond.lower()
        if c == 'z': return s.flags['Z'] == 1
        if c == 'nz': return s.flags['Z'] == 0
        if c == 'c': return s.flags['C'] == 1
        if c == 'nc': return s.flags['C'] == 0
        if c == 'm': return s.flags['S'] == 1
        if c == 'p': return s.flags['S'] == 0
        raise ValueError(f"unknown condition {cond}")

    def flags_byte(self):
        s = self.sim
        b = 0
        if s.flags['S']: b |= 0x80
        if s.flags['Z']: b |= 0x40
        if s.flags['C']: b |= 0x01
        return b
    def set_flags_byte(self, b):
        s = self.sim
        s.flags['S'] = 1 if b & 0x80 else 0
        s.flags['Z'] = 1 if b & 0x40 else 0
        s.flags['C'] = 1 if b & 0x01 else 0

    def jump_target(self, target, scope, mn):
        target = target.strip()
        if target.upper() in STUB_ROUTINES:
            # stub: immediately "return" -- simulate as a call that
            # does nothing and returns right away
            if mn == 'call':
                return None  # exec_instr already pushed return addr;
                              # simulate immediate ret by NOT pushing --
                              # handled specially below
        idx = self.prog.resolve_label(scope, target)
        return idx

    def addr_to_index(self, val):
        if isinstance(val, tuple) and val[0] == 'RETIDX':
            return val[1]
        raise ValueError(f"cannot convert raw value {val} to instruction index")
