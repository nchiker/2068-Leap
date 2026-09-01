.PHONY: all build check smoke-build test budget audit-basic manual clean cplot-extension block-extension frame-extension invert-extension ayreg-extension out-extension release-assets

all: check build

build:
	mkdir -p build
	tools/sjasmplus_strict.sh --sym=build/test_basic.sym --lst=build/test_basic.lst rom/test_basic.asm
	cp test_basic.bin build/test_basic.bin
	tools/sjasmplus_strict.sh --sym=build/exrom.sym --lst=build/exrom.lst rom/exrom_build.asm
	cp exrom.bin build/exrom.bin
	tools/make_eightyone_dck.sh build/exrom.bin build/exrom.dck
	tools/sjasmplus_strict.sh rom/zesarux_combined.asm

check: build
	python3 tools/check_asm.py
	python3 tools/check_docs.py
	python3 tools/check_ram_aliases.py build/test_basic.sym
	python3 tools/check_storage_contract.py
	python3 tools/check_tape_fixture.py
	python3 tools/check_commit_validation.py
	python3 tools/z80sim/test_calc_dispatcher.py
	python3 tools/z80sim/test_sprite_driver.py
	python3 tools/z80sim/test_sprite_basic_driver.py
	tools/build_smoke_roms.sh

smoke-build:
	tools/build_smoke_roms.sh

test: all
	tools/run_smoke_rom_tests.sh
	tools/run_editor_auto_test.sh
	tools/run_editor_auto_test.sh insert
	tools/run_storage_named_load_test.sh
	tools/run_storage_named_load_test.sh extension
	tools/run_storage_named_load_test.sh extension_bad_length
	tools/run_storage_named_load_test.sh extension_bad_version
	tools/run_storage_named_load_test.sh extension_wildcard
	tools/run_storage_named_load_test.sh extension_save_missing
	tools/run_storage_named_load_test.sh extension_roundtrip
	tools/run_storage_named_load_test.sh autorun_roundtrip
	tools/run_storage_named_load_test.sh autorun_zero
	tools/run_storage_named_load_test.sh autorun_trailing
	tools/run_storage_named_load_test.sh autorun_out_of_range
	tools/run_all_tests.sh

budget: build
	python3 tools/report_budget.py build/test_basic.lst build/exrom.lst build/test_basic.sym
	python3 tools/report_rom_map.py build/test_basic.lst build/exrom.lst

cplot-extension: build
	mkdir -p build/extensions
	tools/sjasmplus_strict.sh rom/extensions/cplot.asm
	python3 tools/make_extension_tzx.py build/extensions/cplot.tzx CPLOT build/extensions/cplot.bin
	tools/sjasmplus_strict.sh rom/test_extension_inject.asm --sym=rom/test_extension_inject.sym
	tools/sjasmplus_strict.sh rom/extensions/cplot_test.asm
	tools/sjasmplus_strict.sh rom/test_extension_clear_inject.asm --sym=rom/test_extension_clear_inject.sym
	tools/sjasmplus_strict.sh rom/extensions/cplot_clear_test.asm

block-extension: build
	mkdir -p build/extensions
	tools/sjasmplus_strict.sh rom/extensions/block.asm
	python3 tools/make_extension_tzx.py build/extensions/block.tzx BLOCK build/extensions/block.bin
	tools/sjasmplus_strict.sh rom/test_extension_inject.asm --sym=rom/test_extension_inject.sym
	tools/sjasmplus_strict.sh rom/extensions/block_test.asm
	tools/sjasmplus_strict.sh rom/test_extension_clear_inject.asm --sym=rom/test_extension_clear_inject.sym
	tools/sjasmplus_strict.sh rom/extensions/block_clear_test.asm

frame-extension: build
	mkdir -p build/extensions
	tools/sjasmplus_strict.sh rom/extensions/frame.asm
	python3 tools/make_extension_tzx.py build/extensions/frame.tzx FRAME build/extensions/frame.bin
	tools/sjasmplus_strict.sh rom/test_extension_inject.asm --sym=rom/test_extension_inject.sym
	tools/sjasmplus_strict.sh rom/extensions/frame_test.asm
	tools/sjasmplus_strict.sh rom/test_extension_clear_inject.asm --sym=rom/test_extension_clear_inject.sym
	tools/sjasmplus_strict.sh rom/extensions/frame_clear_test.asm

invert-extension: build
	mkdir -p build/extensions
	tools/sjasmplus_strict.sh rom/extensions/invert.asm
	python3 tools/make_extension_tzx.py build/extensions/invert.tzx INVERT build/extensions/invert.bin
	tools/sjasmplus_strict.sh rom/test_extension_inject.asm --sym=rom/test_extension_inject.sym
	tools/sjasmplus_strict.sh rom/extensions/invert_test.asm
	tools/sjasmplus_strict.sh rom/test_extension_clear_inject.asm --sym=rom/test_extension_clear_inject.sym
	tools/sjasmplus_strict.sh rom/extensions/invert_clear_test.asm

ayreg-extension: build
	mkdir -p build/extensions
	tools/sjasmplus_strict.sh rom/extensions/ayreg.asm
	python3 tools/make_extension_tzx.py build/extensions/ayreg.tzx AYREG build/extensions/ayreg.bin
	tools/sjasmplus_strict.sh rom/test_extension_inject.asm --sym=rom/test_extension_inject.sym
	tools/sjasmplus_strict.sh rom/extensions/ayreg_test.asm
	tools/sjasmplus_strict.sh rom/test_extension_clear_inject.asm --sym=rom/test_extension_clear_inject.sym
	tools/sjasmplus_strict.sh rom/extensions/ayreg_clear_test.asm

out-extension: build
	mkdir -p build/extensions
	tools/sjasmplus_strict.sh rom/extensions/out.asm
	python3 tools/make_extension_tzx.py build/extensions/out.tzx OUT build/extensions/out.bin
	tools/sjasmplus_strict.sh rom/test_extension_inject.asm --sym=rom/test_extension_inject.sym
	tools/sjasmplus_strict.sh rom/extensions/out_test.asm
	tools/sjasmplus_strict.sh rom/test_extension_clear_inject.asm --sym=rom/test_extension_clear_inject.sym
	tools/sjasmplus_strict.sh rom/extensions/out_clear_test.asm

release-assets: build cplot-extension block-extension frame-extension invert-extension ayreg-extension out-extension manual
	mkdir -p build/release/roms build/release/extensions build/release/docs build/release/demos build/release/patches
	cp build/test_basic.bin build/exrom.bin build/exrom.dck build/ts2068rom_zesarux.bin build/release/roms/
	cp build/extensions/cplot.tzx build/extensions/block.tzx build/extensions/frame.tzx build/extensions/invert.tzx build/extensions/ayreg.tzx build/extensions/out.tzx build/release/extensions/
	cp README.md RELEASE_NOTES.md ANNOUNCEMENT_RELEASE_1_BETA.md LICENSE build/release/
	cp docs/emulator_setup.md docs/whats_new_release_1_beta.md docs/2068-Leap_Whats_New_Release_1_Beta.docx docs/user_manual.md docs/2068_Leap_Users_Manual.docx build/release/docs/
	cp demos/showcase.txt demos/smoketest.txt build/release/demos/
	cp patches/0001-Add-ULAplus-support-for-Timex-machines.patch build/release/patches/
	cd build/release && sha256sum roms/* extensions/* > SHA256SUMS.txt
	cd build/release && zip -qrFS ../2068-Leap-Release-1-Beta.zip .
audit-basic: build
	python3 tools/report_basic_routines.py basic/basic.asm build/test_basic.sym

manual:
	python3 tools/build_user_manual_docx.py
	python3 tools/build_whats_new_docx.py

clean:
	rm -rf build
