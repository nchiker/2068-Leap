# Raw logs behind docs/V2_FEATURE_COST_STUDY.md

Plain captured output of the runs quoted in the report (file names are the working names used during the study):

| file | what |
|---|---|
| `base_defects.log` | known-defect suite on the clean Phase 2D worktree: 3 PASS + 14 XFAIL |
| `flicker_base*.log`, `flicker_i1*.log`, `flicker_i2.log`, `run_enh2.log` (flicker section), `run_ess.log` (flicker section) | `tools/study_flicker.py` per scenario: baseline, I1, I1+I2, Enhanced, Essential (JSON lines: T-states per key, GFX_CLS / V2_DRAW_TEXT / GFX_CLEAR_ROW_TEXT hit counts, differential-oracle mismatches) |
| `or_*.log` | D11 error variant: `tools/study_vm_oracle.py` mul / mulop / add / sub, 105 476 pairs each |
| `pr_*.log` | D11 promotion variant (ORACLE_PROMOTE=1), 105 476 pairs each |
| `fill_*.log` | D7: known-defect D7 cases, `v2_fill_check.py`, and the exact-but-slow timing runs |
| `probe_lang.log` | 85-snippet compile probe on the Phase 2D ROM (compile error code per snippet) |
| `lang_print.log` | multi-item PRINT / INPUT prompt test (screen read back) |
| `run_ess.log`, `run_enh2.log` | every focused study suite on the final Essential / Enhanced build |
| `ce_rest.log`, `cen_rest.log`, `cen_sa.log` | Essential: production checks + FILL check + gate + Array Store + known-defect suite; Enhanced: the same, and the standalone component tests (37) |
| `final_make_test_essential.log` | one uninterrupted `make test` on the final Essential tree |
