# z80sim: vendored copy

`tools/z80sim/` carries a copy of the standalone simulator, which is the **authoritative source**:

| | |
|---|---|
| Repository | https://github.com/nchiker/z80sim (local clone: `~/z80sim`) |
| Version used here | commit `99638578e06adbf961247b66cefd0b30bb26138d` (`main`) |
| Vendored files | `sim.py`, `extract_routine.py`, `snapshot.py`, `replay_snapshot.py`, `test_flags.py`, `test_snapshot.py`, `README.md` (byte-identical to that commit) |
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

- Check that the vendored files still match the recorded commit (clean z80sim clone checked out at it):
  `for f in sim.py extract_routine.py snapshot.py replay_snapshot.py test_flags.py test_snapshot.py README.md; do cmp ~/z80sim/$f tools/z80sim/$f; done`
  (no output means identical).
- History: the z80sim repository was created from this directory's history (`git subtree split`), so
  the commits before the upgrade are the originals; the upgrade is commit `ba32f6c` in 2068-Leap.

Related: `tools/sim_from_debugger.py` turns a live `ts2068-debug` session's registers and memory into a
simulator snapshot (`docs/v2/TESTING.md`, "Debugging tools in this workflow").
