.PHONY: all build check smoke-build test budget audit-basic manual clean cplot-extension block-extension frame-extension invert-extension ayreg-extension out-extension sprite-extension shapes-extension v2-packages v2-standalone-test release-assets

all: check build

build:
	mkdir -p build
	tools/sjasmplus_strict.sh --sym=build/test_basic.sym --lst=build/test_basic.lst rom/v2_home.asm
	python3 tools/write_v2_crossbank.py build/test_basic.sym build/v2_crossbank.inc
	cp v2_home.bin build/test_basic.bin
	tools/sjasmplus_strict.sh --sym=build/exrom.sym --lst=build/exrom.lst rom/v2_exrom.asm
	cp v2_exrom.bin build/exrom.bin
	tools/make_eightyone_dck.sh build/exrom.bin build/exrom.dck
	tools/sjasmplus_strict.sh rom/zesarux_combined.asm

check: build
	python3 tools/check_asm.py
	python3 tools/check_docs.py
	python3 tools/check_ram_aliases.py build/test_basic.sym
	python3 tools/check_storage_contract.py
	python3 tools/check_tape_fixture.py
	python3 tools/check_commit_validation.py
	python3 tools/test_check_basic_source.py
	# tests/err1.txt is excluded: it's tools/run_all_tests.sh's own EXPECTED_CYAN
	# fixture, deliberately testing an out-of-bounds DIM access -- a genuine,
	# intentional finding here, not a regression to fail the build over.
	python3 tools/check_basic_source.py $(filter-out tests/err1.txt,$(wildcard tests/*.txt)) demos/*.txt
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
	tools/run_v2_standalone_tests.sh

v2-standalone-test: build
	tools/run_v2_standalone_tests.sh

budget: build
	python3 tools/report_budget.py build/test_basic.lst build/exrom.lst build/test_basic.sym
	python3 tools/report_rom_map.py build/test_basic.lst build/exrom.lst

v2-packages: build
	mkdir -p build/extensions
	tools/sjasmplus_strict.sh rom/v2_package_mode.asm
	tools/sjasmplus_strict.sh rom/v2_package_sprite.asm
	tools/sjasmplus_strict.sh rom/v2_package_printer.asm
	tools/sjasmplus_strict.sh rom/v2_package_shapes.asm
	python3 tools/make_extension_tzx.py build/extensions/v2_mode.tzx MODE build/v2_package_mode.bin
	python3 tools/make_extension_tzx.py build/extensions/v2_sprite.tzx SPRITE build/v2_package_sprite.bin
	python3 tools/make_extension_tzx.py build/extensions/v2_printer.tzx PRINTER build/v2_package_printer.bin
	python3 tools/make_extension_tzx.py build/extensions/v2_shapes.tzx SHAPES build/v2_package_shapes.bin

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

sprite-extension: build
	mkdir -p build/extensions
	tools/sjasmplus_strict.sh rom/extensions/sprite.asm
	python3 tools/make_extension_tzx.py build/extensions/sprite.tzx SPRITE build/extensions/sprite.bin
	tools/sjasmplus_strict.sh rom/test_extension_inject.asm --sym=rom/test_extension_inject.sym
	tools/sjasmplus_strict.sh rom/extensions/sprite_test.asm
	tools/sjasmplus_strict.sh rom/test_extension_clear_inject.asm --sym=rom/test_extension_clear_inject.sym
	tools/sjasmplus_strict.sh rom/extensions/sprite_clear_test.asm

shapes-extension: build
	mkdir -p build/extensions
	tools/sjasmplus_strict.sh rom/extensions/shapes.asm
	python3 tools/make_extension_tzx.py build/extensions/shapes.tzx SHAPES build/extensions/shapes.bin
	tools/sjasmplus_strict.sh rom/test_extension_inject.asm --sym=rom/test_extension_inject.sym
	tools/sjasmplus_strict.sh rom/extensions/shapes_test.asm
	tools/sjasmplus_strict.sh rom/test_extension_clear_inject.asm --sym=rom/test_extension_clear_inject.sym
	tools/sjasmplus_strict.sh rom/extensions/shapes_clear_test.asm

release-assets: build v2-packages manual
	mkdir -p build/release/roms build/release/extensions build/release/docs build/release/demos build/release/patches
	cp build/test_basic.bin build/exrom.bin build/exrom.dck build/ts2068rom_zesarux.bin build/release/roms/
	cp build/extensions/v2_mode.tzx build/extensions/v2_sprite.tzx build/extensions/v2_printer.tzx build/extensions/v2_shapes.tzx build/release/extensions/
	cp README.md RELEASE_NOTES.md ANNOUNCEMENT_RELEASE_1_BETA.md LICENSE build/release/
	cp docs/emulator_setup.md docs/whats_new_release_1_beta.md docs/2068-Leap_Whats_New_Release_1_Beta.docx docs/user_manual.md docs/2068_Leap_Users_Manual.docx build/release/docs/
	cp demos/showcase.txt demos/smoketest.txt build/release/demos/
	cp patches/0001-Add-ULAplus-support-for-Timex-machines.patch patches/0001-zesarux-mirror-ts2068-exrom.patch build/release/patches/
	cd build/release && sha256sum roms/* extensions/* > SHA256SUMS.txt
	cd build/release && zip -qrFS ../2068-Leap-Release-1-Beta.zip .
audit-basic: build
	python3 tools/report_basic_routines.py basic/basic.asm build/test_basic.sym

manual:
	python3 tools/build_user_manual_docx.py
	python3 tools/build_whats_new_docx.py

clean:
	rm -rf build
