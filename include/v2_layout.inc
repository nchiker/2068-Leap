; Integrated R9 source, compiler input, and bytecode regions.
    IFNDEF V2_LAYOUT_INC
    DEFINE V2_LAYOUT_INC
; R10.7 P1 -- the idle staging region is reclaimed for the source/array pool.
; The pool now ends where the compile/run zone begins; the zone is only as big
; as the chunk buffer + its state + the identifier buffer (278 B), anchored at
; the bytecode base so the two can never drift apart (ASSERT below). The
; run-only scalar/string overflow tiers (240 B) overlay the chunk buffer in
; the same zone: compile and run are disjoint phases (docs/v2/
; R10_7_CAPACITY_ARCHITECTURE_AUDIT.md s0/s7; verified by canary in the
; production ROM, docs/v2/R10_7_WORKSPACE_MANAGER_FEASIBILITY.md s9).
V2_CODE_BASE    EQU $A455
CHUNK_SIZE      EQU 264
IDENT_MAX_LEN   EQU 31                    ; R10.7 P2: significant identifier characters
STMT_IDENT_NAME_BUF_LEN EQU IDENT_MAX_LEN + 1
V2_ZONE_SIZE    EQU CHUNK_SIZE + 6 + STMT_IDENT_NAME_BUF_LEN ; chunk + 3 state words + ident buf
V2_SOURCE_END   EQU V2_CODE_BASE - V2_ZONE_SIZE   ; = $A33F
V2_SOURCE_STAGE EQU V2_SOURCE_END

; R10.7 source-staging-architecture change (docs/v2/R10_7_SOURCE_STAGING_
; ARCHITECTURE_AUDIT.md): V2_SOURCE_STAGE no longer holds a full flattened
; copy of the whole program. It now holds a small CHUNK_SIZE-byte rolling
; window, refilled one authoritative line-store record at a time by
; CHUNK_REFILL (rom/exrom_v2_compiler.asm), as the lexer consumes it.
; CHUNK_SIZE derivation: EDIT_LINE_BUF_LEN=128 hard-caps every stored
; record's content at 127 bytes (ASSERTed in include/sysvars.inc), so one
; "record unit" (content + its own CR separator) is at most 128 bytes.
; CHUNK_MARGIN=128 guarantees at least one full fresh record unit of
; lookahead is available whenever a new token starts (checked once, at
; the top of LEX_NEXT_TOKEN) -- proven bound: right before the refill
; loop's last append, buffered-so-far < CHUNK_MARGIN (128); that append
; adds <=128 more; so buffered-so-far after <= 255, plus <=1 byte for the
; true-EOF $00 sentinel on the final record = <=256. CHUNK_SIZE=264 keeps
; 8 bytes of margin past that exact proof, not an arbitrary round number.
; This buffer is compiler scratch, not another persistent representation
; of the program: it is rebuilt from authoritative source every RUN and
; never written back. The three CHUNK_* state cells immediately follow
; the data region, inside the same vacated V2_SOURCE_STAGE window, so no
; other RAM region's address changes.
CHUNK_MARGIN        EQU 128
CHUNK_BUF           EQU V2_SOURCE_STAGE
CHUNK_NEXT_REC      EQU CHUNK_BUF + CHUNK_SIZE        ; 2B: next record to
                                                       ; pull in, or 0
CHUNK_FILL_PTR      EQU CHUNK_NEXT_REC + 2             ; 2B: buffer addr up
                                                       ; to which data is
                                                       ; currently valid
CHUNK_CUR_REC_PTR   EQU CHUNK_FILL_PTR + 2             ; 2B: authoritative
                                                       ; pointer of the
                                                       ; most-recently-
                                                       ; appended record
                                                       ; (error-line lookup)

; STASH_IDENT_AND_PEEK (rom/exrom_v2_compiler.asm) used to stash only a
; POINTER into the live buffer (STMT_IDENT_NAME_PTR). That pointer could
; go stale the instant its own "call LEX_NEXT_TOKEN" (peeking the token
; immediately after the identifier -- '(' for an array/PROC/DEF-FN name,
; '=' for a plain assignment) triggers a refill: the identifier's own
; bytes are BEHIND SRC_PTR by then, outside the region CHUNK_REFILL
; preserves, and get overwritten by the very next appended record. Found
; live (an array assignment failed "never DIM'd" even though DIM had
; already run) via ts2068-debug single-stepping, not by inspection.
; STMT_IDENT_NAME_BUF is a copy destination immune to this -- 8 bytes,
; matching CLAMP_LEN8's own already-established "identifiers significant
; to 8 characters" convention used by every symbol-table FIND_OR_CREATE/
; LOOKUP call site, so no behavior beyond this bug fix changes.
STMT_IDENT_NAME_BUF EQU CHUNK_CUR_REC_PTR + 2          ; 8B: see above
    ASSERT STMT_IDENT_NAME_BUF + STMT_IDENT_NAME_BUF_LEN == V2_CODE_BASE    ; zone ends exactly at the code

; R10.7 P2 -- tagged compile symbol table state (see rom/exrom_v2_symtab.asm).
SYM_K_NUM       equ 0
SYM_K_STR       equ 1
SYM_K_ARR       equ 2
SYM_K_SARR      equ 3
SYM_K_LAB       equ 4

SYM_COUNTS:     equ $B800   ; 5 bytes, one count per kind
SYM_BASE_V:     equ $B805   ; 2: table start
SYM_END_V:      equ $B807   ; 2: -> terminating 0 byte
SYM_LIMIT_V:    equ $B809   ; 2: first byte the table may NOT use
SS_NAME:        equ $B80B   ; 2: name pointer of the lookup in progress
; R10.7 P3 -- run-time table bases, set by VM_CARVE_TABLES (rom/exrom_v2_vm_core.asm)
RT_SYMTAB_PTR:    equ $B80D   ; 2 each: base of the exactly-sized run-time tables
RT_FLOATTAB_PTR:  equ $B80F
RT_STRTAB_PTR:    equ $B811
RT_ARRPTR_PTR:    equ $B813
RT_STRARRPTR_PTR: equ $B815
RT_NUM_COUNT:     equ $B817   ; 1: numeric symbols (float temp slots follow them)
RT_STR_COUNT:     equ $B818   ; 1: string symbols (string temp slots follow them)
VM_CSP:           equ $B819   ; 2: control stack pointer (lowest used byte); R10.7 P4
; R10.7 P5.4 -- second array segment. When an array does not fit in the main pool
; (ARRAYS_END .. VM_CSP), OP_DIM / array LOAD place it in $E000-$E7FF, which is
; always-visible RAM that FILL (ends $DC00) and the sprite buffers ($E800) leave free.
; The array pointer tables already hold absolute descriptor addresses, so element
; access is unchanged. FREE(1) reports ARR2_LIMIT - ARR2_END.
ARR2_BASE:        equ $E000
ARR2_LIMIT:       equ $E800
ARR2_END:         equ $B81B   ; 2: next free byte of segment 2 (reset by VM_INIT)
ARR2_SWAPPED:     equ $B81D   ; 1: nonzero while ARRAYS_END/ARR2_END are exchanged
; R10.9 Phase 2C -- persistent Array Store (rom/exrom_v2_arrstore.asm). The store occupies
; ARR2_BASE .. PAS_END; entry = [len:2][kind:1 (2 numeric | 3 string)][namelen:1][name][descriptor].
; PAS_END is set at cold start (V2_EXROM_ENTRY) and by NEW only -- never by MEM_INIT_V2, which
; is also the failed-program-LOAD recovery. ARR2_END is always >= PAS_END.
PAS_END:          equ $B81E   ; 2: first byte past the Array Store (ARR2_BASE = empty)
ASV_KIND:         equ $B820   ; 1: DIM kind (SYM_K_ARR / SYM_K_SARR)
ASV_IDX:          equ $B821   ; 1: array index
ASV_ENT:          equ $B822   ; 2: store entry being built
ASV_DESC:         equ $B824   ; 2: its descriptor
ASV_NL:           equ $B826   ; 2: its total length
ASV_EL:           equ $B828   ; 2: length of the entry being replaced
    ASSERT GFX_FILL_STACK_END <= ARR2_BASE
    ASSERT ARR2_LIMIT <= SPRITE_SLOT_IMG_BUF
CSYM_COUNT:     equ SYM_COUNTS + SYM_K_NUM
STRSYM_COUNT:   equ SYM_COUNTS + SYM_K_STR
ARRSYM_COUNT:   equ SYM_COUNTS + SYM_K_ARR
STRARRSYM_COUNT: equ SYM_COUNTS + SYM_K_SARR


V2_CODE_LIMIT   EQU $B400
V2_FLOATTAB_BASE EQU V2_CODE_LIMIT
V2_DECOMP_END_ADDR EQU $BD9F
V2_MACHINE_STACK_TOP EQU $FF00
V2_HOME_IMAGE_END EQU $4000
    ENDIF
