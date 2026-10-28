# z80sim: vendored copy

`tools/z80sim/` carries a copy of the standalone simulator, which is the **authoritative source**:

| | |
|---|---|
| Repository | https://github.com/nchiker/z80sim (local clone: `~/z80sim`) |
| Version used here | commit `13c9bce9901e7c6dbce28840a232b4580fa8d953` (`main`) |
| Vendored files | `sim.py`, `extract_routine.py`, `snapshot.py`, `replay_snapshot.py`, `test_flags.py`, `test_snapshot.py`, `README.md` (byte-identical to that commit, except README's LICENSE link, which points at this repository's `../../LICENSE`) |
| 2068-Leap only | `test_calc_dispatcher.py`, `test_sprite_driver.py`, `test_sprite_basic_driver.py` (they load this project's source tree), this file |

Rules:

- Change the simulator **in the z80sim repository**, test it there (`python3 -m unittest -v test_flags test_snapshot`),
  commit, then sync it here. Do not edit the vendored files in this directory.
- Sync, then run `make check` (it runs the three project driver suites from the repo root and
  `test_flags`/`test_snapshot`), and update the commit above in the same 2068-Leap commit:

  ```sh
  cd ~/z80sim && git rev-parse HEAD            # the commit to record above
  for f in sim.py extract_routine.py snapshot.py replay_snapshot.py test_flags.py test_snapshot.py README.md; do
      cp ~/z80sim/$f ~/2068-Leap/tools/z80sim/$f
  done
  ```

- Publish z80sim with the project: push the z80sim commit recorded above before (or with) any 2068-Leap
  push that carries it. `tools/hooks/pre-push` refuses a 2068-Leap push whose `UPSTREAM.md` names a
  z80sim commit not yet on z80sim's remote (the clone at `~/z80sim`, or `$Z80SIM_DIR`); install it once per
  clone with `git config core.hooksPath tools/hooks`.
- Check that the vendored files still match the recorded commit (clean z80sim clone checked out at it):
  `for f in sim.py extract_routine.py snapshot.py replay_snapshot.py test_flags.py test_snapshot.py README.md; do cmp ~/z80sim/$f tools/z80sim/$f; done`
  (no output means identical).
- History: the z80sim repository was created from this directory's history (`git subtree split`), so
  the commits before the upgrade are the originals; the upgrade is commit `ba32f6c` in 2068-Leap.

Related: `tools/sim_from_debugger.py` turns a live `ts2068-debug` session's registers and memory into a
simulator snapshot (`docs/TESTING.md`, "Debugging tools in this workflow").
