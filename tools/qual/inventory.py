"""V2 language surface inventory (derived from the source tables of the three configurations).

Sources read (Enhanced tree; Baseline/Essential differences noted in `cfgs`):
  rom/exrom_v2_compiler.asm  KEYWORD_TABLE (44 rows Ess/Enh, 43 Baseline), COMPILE_STATEMENT_LIST
                             dispatch, COMPILE_EXPR..COMPILE_FACTOR, BUILTIN_FN_TABLE (32 rows Ess/Enh,
                             30 Baseline), COMPILE_DIMN, COMPILE_LPRINT
  rom/exrom_v2_vm_core.asm   VM_OP_TABLE (70 opcodes Enh, 68 Ess, 67 Baseline), BUILTIN_FN_JUMP_TABLE
  rom/exrom_v2_shell.asm     V2_DISPATCH (RUN LIST NEW SAVE LOAD VERIFY, `:` immediate), EXT/ARRAY suffixes
  rom/ext_*_module.asm       package registrations (EXT2_REGISTER name / argcount / argtypes)
  rom/exrom_editor.asm       editor keys

Classification codes (as requested):
  ID  implemented and documented        IU  implemented but undocumented (in current docs)
  DM  documented but missing            PI  partially implemented
  NS  intentionally unsupported         HW  requires physical hardware to qualify
`doc` names the document that describes it (manual = docs/user_manual.md, a V1-era text with a V2
transition note; spec = docs/v2/V2_LANGUAGE_SPEC.md; R10.8 = docs/v2/R10_8_FEATURE_MATRIX.md).
`tests` lists corpus feature keys (tools/qual/corpus.py `feature`) and existing gate suites.
"""

ALL = ("baseline", "essential", "enhanced")
NEW = ("essential", "enhanced")
ENH = ("enhanced",)

FN_CASES = {
    "LEN": ["case:str.len", "case:str.empty", "case:str.uninit", "case:str.concat_cap"], "CODE": ["case:str.code"],
    "VAL": ["case:str.val"], "CHR$": ["case:str.chr", "case:str.temps.chr3"], "STR$": ["case:str.str_", "case:str.temps.strs"],
    "UPPER$": ["case:str.upper", "case:str.temps"], "LOWER$": ["case:str.lower"], "LEFT$": ["case:str.left", "case:strrec"],
    "RIGHT$": ["case:str.right"], "MID$": ["case:str.mid", "case:str.temps.lit_fn_lit"], "INKEY$": ["case:str.inkey"],
    "HIT": ["case:ns.hit"], "ATN_ASN_ACS_EXP_LN": ["case:ns.atn", "case:ns.exp"], "INSTR": ["case:str.instr"],
}

# (id, kind, syntax, cfgs, source, doc, class, tests, note)
INV = [
    # ---------------- statements (KEYWORD_TABLE + COMPILE_STATEMENT_LIST) ----------------
    ("stmt.assign", "statement", "name = expr / name$ = sexpr / a(i) = expr / a$(i) = sexpr", ALL, "COMPILE_ASSIGN_CONTINUED, COMPILE_STR_ASSIGN_CONTINUED, COMPILE_ARR_ASSIGN_COMMON",
     "manual 6", "ID", ["expr.assign", "variable.float", "array.numeric", "array.string", "string"], "no LET (error 2)"),
    ("stmt.label", "statement", "name:", ALL, "COMPILE_STATEMENT_LIST.label, LABEL_DEFINE", "manual 4", "ID", ["label"], "duplicate labels accepted silently (Q-12)"),
    ("stmt.GOTO", "statement", "GOTO label", ALL, "COMPILE_GOTO", "manual 4", "ID", ["stmt.GOTO", "stmt.IF.goto", "stmt.FOR.goto"], "labels only"),
    ("stmt.IF.goto", "statement", "IF cond THEN GOTO label", ALL, "COMPILE_IF", "manual 5", "ID", ["stmt.IF.goto"], ""),
    ("stmt.IF.block", "statement", "IF cond THEN ... [ELSE ...] ENDIF", ALL, "COMPILE_IF_BLOCK", "manual 5 (END IF spelling differs)", "ID", ["stmt.IF.block", "stmt.IF.condition", "stmt.IF"], "condition on a float tests the slot index (Q-06)"),
    ("stmt.IF.single", "statement", "IF cond THEN stmt (no ENDIF)", ALL, "-", "manual 5, 17 (V1)", "NS", ["stmt.IF.single"], "R10.8 L1: IF is always a block; V1 manual still documents it -> doc defect"),
    ("stmt.ELSEIF", "statement", "ELSEIF / ELSE IF ... ENDIF ENDIF", ALL, "ELSE + nested IF", "manual 17 (ELSEIF)", "PI", ["stmt.IF.elseif"], "`ELSE IF` works; `ELSEIF` keyword missing (L-ELIF)"),
    ("stmt.FOR", "statement", "FOR v = a TO b [STEP s] ... NEXT v", ALL, "COMPILE_FOR/COMPILE_NEXT, OP_FOR_INIT/OP_FOR_NEXT/OP_FOR_POP", "manual 5", "PI",
     ["stmt.FOR", "stmt.FOR.step", "stmt.FOR.limit", "stmt.FOR.float", "stmt.FOR.zerotrip", "stmt.FOR.nesting", "stmt.FOR.goto", "stmt.FOR.structure", "stmt.NEXT"],
     "zero-trip runs the body once (Q-07); float bounds/step read as slot index (Q-08); D11 limit wrap (baseline)"),
    ("stmt.NEXT.bare", "statement", "NEXT (no variable)", ALL, "-", "manual 5", "DM", ["stmt.NEXT.bare"], "error 10 (L-NEXT)"),
    ("stmt.EXIT", "statement", "EXIT FOR", ALL, "COMPILE_EXIT_FOR", "manual 5", "ID", ["stmt.EXIT"], ""),
    ("stmt.PROC", "statement", "PROC name(p): ... ENDP / CALL name(expr)", ALL, "COMPILE_PROC, COMPILE_CALL_STMT, OP_PARAM_BIND/UNBIND", "manual 4 (V1 CALL form); R10.8", "PI",
     ["stmt.PROC", "stmt.PROC.scope", "stmt.PROC.recursion", "stmt.PROC.nesting", "stmt.CALL"], "exactly one parameter; nested PROC/DEF FN definitions corrupt the enclosing PROC (Q-11); N-1 (baseline)"),
    ("stmt.DEF FN", "statement", "DEF FN name(p) = expr / FN name(arg)", ALL, "COMPILE_DEF_FN, COMPILE_FACTOR.udf_call", "manual 6", "ID", ["stmt.DEF FN", "stmt.DEF FN.scope"], "numeric only, one parameter"),
    ("stmt.GOSUB", "statement", "GOSUB / RETURN", ALL, "-", "manual 5, 17 (V1)", "NS", [], "replaced by PROC/CALL (decision)"),
    ("stmt.PRINT", "statement", "PRINT expr | sexpr", ALL, "COMPILE_PRINT, OP_PRINT_NUM/STR", "manual 8", "ID", ["stmt.PRINT"], "single item in Baseline/Essential"),
    ("stmt.PRINT.multi", "statement", "PRINT item {; | , item} [; | ,]  /  bare PRINT", ENH, "COMPILE_PRINT (study/lang-print), OP_NL, OP_PRINT_COMMA", "cost study B.2", "IU", ["stmt.PRINT.multi"], "Enhanced only; not in current docs"),
    ("stmt.PRINT.AT", "statement", "PRINT AT r,c; ... / PRINT TAB n; ...", ALL, "-", "R10.8 (stock)", "DM", ["stmt.PRINT.AT"], "standalone AT/TAB statements exist"),
    ("stmt.AT", "statement", "AT row,col", ALL, "COMPILE_AT, OP_AT", "manual 8", "ID", ["stmt.AT"], ""),
    ("stmt.TAB", "statement", "TAB col", ALL, "COMPILE_TAB, OP_TAB", "manual 8", "ID", ["stmt.TAB"], ""),
    ("stmt.CLS", "statement", "CLS", ALL, "COMPILE_CLS, OP_CLS", "manual 8", "PI", ["stmt.CLS"], "does not home the print position (Q-14)"),
    ("stmt.INK", "statement", "INK n / PAPER n / BRIGHT n / FLASH n / INVERSE n / OVER n", ALL, "COMPILE_1ARG_STMT", "manual 8", "ID", ["stmt.INK", "stmt.BRIGHT", "stmt.INVERSE", "stmt.OVER"], "values masked (INK 9 = INK 1)"),
    ("stmt.BORDER", "statement", "BORDER n", ALL, "OP_BORDER", "manual 8", "ID", ["stmt.BORDER"], "visible colour: hardware"),
    ("stmt.PLOT", "statement", "PLOT x,y", ALL, "COMPILE_PLOT, OP_PLOT", "manual 9", "ID", ["stmt.PLOT", "fn.POINT"], "coordinates wrap mod 256 (decision)"),
    ("stmt.LINE", "statement", "LINE x0,y0 TO x1,y1", ALL, "COMPILE_LINE, OP_LINE", "manual 9", "ID", ["stmt.LINE"], ""),
    ("stmt.BEEP", "statement", "BEEP dur,pitch", ALL, "OP_BEEP", "manual 11", "HW", ["stmt.BEEP"], "audio needs hardware"),
    ("stmt.SOUND", "statement", "SOUND reg,val", ALL, "OP_SOUND", "manual 11", "HW", ["stmt.SOUND"], "register range checked; audio needs hardware"),
    ("stmt.POKE", "statement", "POKE addr,val", ALL, "OP_POKE", "manual 13", "ID", ["stmt.POKE", "literal.integer.address"], "value truncated to a byte"),
    ("stmt.PAUSE", "statement", "PAUSE n (0 = key)", ALL, "OP_PAUSE", "manual 5", "ID", ["stmt.PAUSE"], "BREAK-aware in Essential/Enhanced"),
    ("stmt.RANDOMISE", "statement", "RANDOMISE n", ALL, "OP_RANDOMISE", "manual 16", "ID", ["stmt.RANDOMISE", "fn.RND"], "RANDOMIZE spelling not accepted"),
    ("stmt.INPUT", "statement", "INPUT v / INPUT v$", ALL, "COMPILE_INPUT, OP_INPUT_NUM/STR", "manual 12", "PI", ["stmt.INPUT", "stmt.INPUT.range", "stmt.INPUT.decimal"],
     "numeric: 5 digits, wraps > 32767 (Q-16), '.' silently dropped (Q-15); no editing keys"),
    ("stmt.INPUT.prompt", "statement", 'INPUT "prompt"; v', ENH, "COMPILE_INPUT (study/lang-print)", "manual 12 (V1)", "PI", ["stmt.INPUT.prompt"], "Enhanced only"),
    ("stmt.DIM", "statement", "DIM a(n) / DIM a$(n[,w])", ALL, "COMPILE_DIM(_STR), ARR_DIM (EXROM), ARENA_ALLOC_*", "manual 6", "PI",
     ["array.dim", "array.dim.capacity", "array.numeric", "array.string"], "literal size only; large sizes overflow the size arithmetic (Q-04)"),
    ("stmt.CLEAR", "statement", "CLEAR", ALL, "OP_CLEAR, MEM_CLEAR_V2", "manual 6", "ID", ["stmt.CLEAR"], "inside FOR: loop restarts forever (Q-21)"),
    ("stmt.REM", "statement", "REM text", ALL, "COMPILE_STATEMENT_LIST.rem", "manual 17", "ID", ["statement.REM"], ""),
    ("stmt.END", "statement", "END / STOP", ALL, "OP_HALT", "manual 5", "ID", ["stmt.END", "stmt.STOP"], "no CONT"),
    ("stmt.LPRINT", "statement", "LPRINT expr | sexpr", ALL, "COMPILE_LPRINT -> PRINTER package", "manual 8", "HW", ["pkg.PRINTER"], "needs the PRINTER package; printer output needs hardware"),
    ("stmt.OUT", "statement", "OUT port,value (16-bit port)", NEW, "COMPILE_OUT, OP_OUT (study/lang-hw)", "manual 13 (V1 package)", "HW", ["stmt.OUT"], "non-$FE ports need hardware"),
    ("stmt.separator", "syntax", ": (statement separator, line continuation)", ALL, "LEX_NEXT_TOKEN, CHUNK_APPEND_ONE_RECORD", "manual 17", "ID", ["statement.separator"], ""),
    ("stmt.bareword", "syntax", "a line holding only a name", ALL, "COMPILE_STATEMENT_LIST.label (N-2)", "-", "ID", ["statement.bareword"], "error 64 in Essential/Enhanced; silently ignored in Baseline (N-2)"),
    ("stmt.DATA", "statement", "DATA / READ / RESTORE", ALL, "-", "spec: rejected", "NS", [], "arrays + Array Store replace it"),
    ("stmt.other_stock", "statement", "LET MERGE CONT COPY DRAW SCREEN$ VAL$ RANDOMIZE", ALL, "-", "R10.8", "NS", [], "not accepted"),
    # ---------------- expressions / operators ----------------
    ("op.arith", "operator", "+ - * / unary -  ( )", ALL, "COMPILE_ADDITIVE/TERM/FACTOR, OP_ADD/SUB/MUL/DIV", "manual 7", "PI", ["expr.arith", "expr.div0"],
     "int overflow: wraps (Baseline, D11) / promotes (Ess/Enh); > 2 live float temporaries corrupt results (Q-02)"),
    ("op.rel", "operator", "< <= = >= > <> (numeric)", ALL, "COMPILE_RELATIONAL, OP_CMP_*", "manual 7", "ID", ["expr.relational"], "non-associative"),
    ("op.logic", "operator", "AND OR NOT", ALL, "COMPILE_EXPR/BOOL_AND/BOOL_NOT, OP_AND/OR/NOT", "manual 7", "PI", ["expr.logical", "expr.logical.float"],
     "no short-circuit (L-SC); a float operand resets the machine (Q-03)"),
    ("op.strcat", "operator", "s$ + t$", ALL, "COMPILE_STR_EXPR, OP_STR_CONCAT", "manual 7", "PI", ["string"], "> 2 live string temporaries corrupt results (Q-02)"),
    ("op.strcmp", "operator", "s$ = t$, s$ < t$ (IF head only)", ALL, "COMPILE_IF.str_condition, OP_STR_CMP_*", "manual 7", "PI", ["string.compare"], "compares LENGTHS only (Q-01)"),
    ("op.strcmp.ordering", "operator", "s$ <> > <= >= t$", ALL, "-", "spec MUST HAVE", "DM", ["string.compare.ordering"], "L-STR"),
    ("op.MOD.infix", "operator", "a MOD b / a DIV b infix", ALL, "-", "manual 16 example", "NS", [], "function forms MOD()/DIV() only"),
    ("op.pow", "operator", "^", ALL, "-", "R10.8", "NS", [], ""),
    ("lit.int", "literal", "decimal integer 0..32767", ALL, "LEX_SCAN_NUMBER, COMPILE_NUMBER_LITERAL", "manual 6", "ID", ["literal.integer"], ""),
    ("lit.int.large", "literal", "integer literal > 32767", ALL, "LEX_ACCUM_DIGIT (L-A in Ess/Enh)", "cost study G.1", "PI", ["literal.integer.large", "literal.integer.address"],
     "L-A: 32768..65535 are 16-bit patterns (PRINT 40000 -> -25536; -32768 -> +32768.0000, Q-05); >= 65536 error 64; Baseline wraps"),
    ("lit.dec", "literal", "decimal literal n.ddd", ALL, "LEX_SCAN_NUMBER, OP_PUSH_FLOAT_LIT", "R10.8", "PI", ["literal.decimal", "literal.decimal.precision"],
     "mantissa <= 32767 (L-A); 5+ fractional digits overflow the 16-bit divisor silently (Q-09)"),
    ("lit.str", "literal", '"text" (0..31 chars)', ALL, "LEX_SCAN_STRING, COMPILE_STR_FACTOR", "manual 6", "ID", ["literal.string", "literal.string.limit"], "longer literal silently cut to 31 (L3)"),
    ("lit.hex", "literal", "$FF / 1E3", ALL, "-", "R10.8", "NS", ["literal.hex", "literal.exponent"], ""),
    ("lex.ident", "syntax", "identifiers: letter{letter|digit} up to 31, case-insensitive; name$ strings", ALL, "LEX_SCAN_IDENT, CLAMP_IDENT_LEN", "R10.8", "ID",
     ["identifier", "identifier.length", "identifier.reserved", "lexer.case"], ""),
    ("ns.array_scalar", "semantics", "array name used as a scalar", ALL, "COMPILE_FACTOR (ARRSYM_LOOKUP before scalar)", "-", "PI", ["namespace.array_scalar"], "N-4"),
    ("arr.bounds", "semantics", "array subscript bounds / type checks (error 10 / 11)", ALL, "VM_ARR_VALIDATE_INDEX, VM_POP_CHECK_INT", "manual 6", "PI",
     ["array.bounds", "array.type", "array.string.bounds"], "the failing store still writes (Q-18)"),
    ("str.record", "semantics", "string values: 31-character records, temporaries", ALL, "STRTAB, OP_PUSH_STR_LIT, OP_STR_CONCAT, VM_STR_ALLOC_TEMP", "manual 6", "PI",
     ["string.record", "string.variables", "string.type"], "Q-02, Q-27, Q-28"),
    ("var.scalar", "semantics", "numeric scalars: implicit creation, zero default, 251/253 per program", ALL, "CSYM_FIND_OR_CREATE, VM_CARVE_TABLES", "R10.8", "ID",
     ["variable.default", "variable.capacity", "variable.float"], ""),
    ("compile.strict", "semantics", "strict compilation: unknown/trailing tokens are errors (64/65/66)", ALL, "COMPILE_STATEMENT_LIST.after_stmt (Phase 2D)", "R10.9 2D", "ID",
     ["compile.strict", "lexer", "lexer.comment", "program", "gate:v2_prod_regress D3-*"], ""),
    ("compile.errorline", "semantics", "a compile error moves the cursor to its line", ALL, "LEX_LINE, V2_JUMP_TO_ERROR_LINE (Phase 2D; FOR line N-3 Enhanced)", "manual 18", "ID",
     ["compile.errorline", "gate:v2_prod_regress D4-*"], ""),
    ("fn.calls", "semantics", "built-in call checking: argument count / type / nesting", ALL, "COMPILE_FACTOR.fn_call", "manual 16", "ID",
     ["fn.argcount", "fn.argtype", "fn.nesting"], ""),
    ("err.runtime", "semantics", "runtime errors stop the program with a message", ALL, "VM_ERR_*, V2_RUNTIME_MSG", "manual 18", "PI",
     ["runtime.error", "expr.div0"], "messages are generic (RUNTIME ERROR) for most codes (U4/U5)"),
    ("ns.keywords", "statement", "GOSUB RETURN DATA READ LET MERGE ^ infix MOD", ALL, "-", "spec / R10.8", "NS", ["case:ns.", "ns.keywords"], "must be rejected at compile time"),
    # ---------------- built-in functions (BUILTIN_FN_TABLE) ----------------
] + [("fn." + n, "function", sig, cf, "BUILTIN_FN_TABLE / BUILTIN_FN_" + n.rstrip("$").replace("$", ""), "manual 16" if doc else "-", cls, ["fn." + n.rstrip("$")] + extra + FN_CASES.get(n, []), note)
     for (n, sig, cf, doc, cls, extra, note) in (
        ("ABS", "ABS(x)", ALL, 1, "PI", [], "ABS(-32768) wraps (D11-EXT)"),
        ("SGN", "SGN(x)", ALL, 1, "PI", [], "float argument truncated first: SGN(0.5)=0 (Q-10)"),
        ("MOD", "MOD(a,b)", ALL, 1, "PI", [], "MOD(x,0) = 0 silently (Q-13); floats truncated"),
        ("DIV", "DIV(a,b)", ALL, 1, "PI", [], "DIV(x,0) = 0 silently (Q-13); DIV(-32768,-1) wraps (D11-EXT)"),
        ("RND", "RND(n): 0..n-1", ALL, 1, "ID", [], ""),
        ("INT", "INT(x): truncates toward zero", ALL, 1, "PI", [], "manual says no-op; R10.8 L6 truncation; INT(>32767) saturates (D11-EXT)"),
        ("SQR", "SQR(x)", ALL, 1, "PI", [], "argument truncated to integer (Q-10); SQR(-x)=0 silently; precision loss for large x"),
        ("PI", "PI()", ALL, 1, "ID", [], "D10 display"),
        ("RAD", "RAD(x)", ALL, 1, "PI", [], "argument truncated to integer (Q-10)"),
        ("DEG", "DEG(x)", ALL, 1, "PI", [], "argument truncated to integer: DEG(PI())=171.88 (Q-10)"),
        ("SIN", "SIN(deg)", ALL, 1, "PI", [], "integer degrees only (Q-10); D10"),
        ("COS", "COS(deg)", ALL, 0, "PI", [], "integer degrees only; D10"),
        ("TAN", "TAN(deg)", ALL, 0, "PI", [], "integer degrees only"),
        ("PEEK", "PEEK(addr)", ALL, 1, "ID", [], ""),
        ("USR", "USR(addr): HL", ALL, 1, "ID", [], ""),
        ("POINT", "POINT(x,y)", ALL, 1, "ID", [], ""),
        ("ATTR", "ATTR(r,c)", ALL, 1, "ID", [], ""),
        ("LEN", "LEN(s$)", ALL, 1, "ID", [], ""),
        ("CODE", "CODE(s$)", ALL, 1, "ID", [], ""),
        ("VAL", "VAL(s$)", ALL, 1, "PI", [], "skips non-digits instead of stopping (Q-17); wraps > 32767"),
        ("CHR$", "CHR$(n)", ALL, 1, "ID", [], ""),
        ("STR$", "STR$(x)", ALL, 1, "ID", [], ""),
        ("UPPER$", "UPPER$(s$)", ALL, 1, "ID", [], ""),
        ("LOWER$", "LOWER$(s$)", ALL, 1, "ID", [], ""),
        ("LEFT$", "LEFT$(s$,n)", ALL, 1, "ID", [], ""),
        ("RIGHT$", "RIGHT$(s$,n)", ALL, 1, "ID", [], ""),
        ("MID$", "MID$(s$,start,len)", ALL, 0, "IU", [], "not in the manual's function table"),
        ("INKEY$", "INKEY$()", ALL, 1, "ID", [], ""),
        ("FREE", "FREE() / FREE(n)", ALL, 1, "ID", [], ""),
        ("DIMN", "DIMN(a)", ALL, 1, "PI", [], "string arrays not accepted (manual says DIMN(name$))"),
        ("IN", "IN(port)", NEW, 0, "HW", [], "non-$FE ports need hardware"),
        ("STICK", "STICK(n)", NEW, 1, "HW", [], "directions need hardware; STICK(5) returns a value (manual: INVALID ARGUMENT)"),
        ("INSTR", "INSTR(a$,b$)", ALL, 1, "DM", [], "L-INSTR"),
        ("HIT", "HIT(s1,s2)", ALL, 1, "DM", [], "sprite collision function documented, absent in V2"),
        ("ATN_ASN_ACS_EXP_LN", "ATN ASN ACS EXP LN SCREEN$", ALL, 0, "NS", [], "package-class (cost study L-FN)"),
)] + [
    # ---------------- packages ----------------
    ("pkg.MODE", "package", "MODE m / ULAPLUS u / PALETTE i,v", ALL, "rom/ext_mode_module.asm (165 B)", "manual 9", "HW", ["pkg.MODE"], "hi-res/ULAplus visible output: hardware"),
    ("pkg.SPRITE", "package", "GRAB s,r,c,w,h / SHOW s,r,c / HIDE s / MOVE s,r,c", ALL, "rom/ext_sprite_module.asm (832 B)", "manual 10 (SPRITE GRAB form)", "PI", ["pkg.SPRITE"], "syntax differs from the manual"),
    ("pkg.PRINTER", "package", "LPRINT x / LPRINT s$ / LLIST", ALL, "rom/ext_printer_module.asm (345 B)", "manual 8, 15", "HW", ["pkg.PRINTER"], ""),
    ("pkg.SHAPES", "package", "CIRCLE x,y,r / FILL x,y", ALL, "rom/ext_v2_shapes_module.asm (795 B; 1007 B Ess/Enh)", "manual 9", "PI", ["pkg.SHAPES"], "D7 (Baseline); exact but slow worst case (Ess/Enh)"),
    ("pkg.GRAPHICS", "package", "CPLOT x,y / BLOCK r,c,w,h / FRAME r,c,w,h / INVERT r,c,w,h", ALL, "rom/ext_v2_graphics_module.asm (467 B)", "manual 14 says 'not linked'", "IU", ["pkg.GRAPHICS"], "doc discrepancy DD-5"),
    ("pkg.unloaded", "package", "package statement with no package loaded", ALL, "COMPILE_STATEMENT_LIST.ident_stmt (EXT2_LOOKUP)", "R10.8", "ID", ["pkg.unloaded"], "compile error 2"),
    # ---------------- system / editor commands ----------------
    ("cmd.RUN", "command", "RUN", ALL, "V2_DISPATCH -> V2_RUN_STORED", "manual 15", "ID", ["gate:v2_prod_regress"], ""),
    ("cmd.LIST", "command", "LIST", ALL, "V2_LIST", "manual 15", "ID", ["gate:v2_prod_regress"], "abortable in Enhanced (ED5)"),
    ("cmd.NEW", "command", "NEW", ALL, "V2_DISPATCH.not_list", "manual 15", "ID", ["gate:v2_prod_regress"], "empties the Array Store"),
    ("cmd.SAVE", "command", 'SAVE "name" [EXT | ARRAY a]', ALL, "V2_SAVE / V2_SAVE_ARRAY", "manual 3, 6", "HW", ["gate:v2_prod_regress", "gate:v2_prod_arrays"], "SEND side intercepted; analogue path needs hardware"),
    ("cmd.LOAD", "command", 'LOAD "name" [EXT | ARRAY a]', ALL, "V2_LOAD / V2_LOAD_ARRAY", "manual 3, 6", "HW", ["gate:v2_prod_regress", "gate:v2_prod_arrays"], "synthesised EAR stream in the gate"),
    ("cmd.VERIFY", "command", 'VERIFY "name"', ALL, "V2_VERIFY", "manual 18", "HW", ["gate:v2_prod_regress"], ""),
    ("cmd.immediate", "command", ": statement(s)", ALL, "V2_RUN_IMMEDIATE", "manual 15", "ID", ["gate:v2_prod_regress"], ""),
    ("cmd.save_vars", "command", "save/restore program WITH its current variables", ALL, "-", "R10.9 decision 1 (storage goal 2)", "DM", [], "not implemented (Array Store is arrays only); see the remaining-budget report"),
    ("cmd.DELETE_EDIT_HELP", "command", "DELETE / EDIT / HELP", ALL, "-", "manual 15, 17 (V1)", "DM", [], "V1 commands, absent in V2 (R10.8 regression list)"),
    ("ed.keys", "editor", "LEFT RIGHT UP DOWN DELETE delete-line insert-line ENTER BREAK", ALL, "rom/exrom_editor.asm EDITOR_LOOP", "manual 19", "ID",
     ["gate:v2_prod_regress", "study:edit_preserve", "study:flicker", "study:break_matrix"], "D9/D5/U6/I1/I2 per configuration"),
    ("ed.SYMSHIFT_AS", "editor", "SYMBOL SHIFT+A / +S next/previous error", ALL, "-", "manual 19", "DM", [], "R10.8 U12 dead keys"),
    ("ed.BREAK", "editor", "BREAK stops a running program", NEW, "ISR (study/break)", "manual 18", "HW", ["study:break_matrix", "gate:known_defects D5"], "Baseline: D5 (not implemented)"),
    ("ed.flicker", "editor", "selective redraw while typing / navigating", NEW, "V2_REDRAW scope (study/flicker-i1, -i2)", "cost study D", "HW", ["study:flicker"], "visible flicker needs hardware"),
    ("disp.font", "display", "character set 32..127 + block graphics 128..143", ALL, "font data", "manual 19", "PI", ["display.font"], "[ \\ ] ^ ` { | } ~ have blank glyphs (Q-26)"),
]

FIELDS = ("id", "kind", "syntax", "cfgs", "source", "doc", "class", "tests", "note")


def rows():
    for t in INV:
        yield dict(zip(FIELDS, t))
