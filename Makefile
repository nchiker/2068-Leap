.PHONY: all build check smoke-build test budget audit-basic manual clean cplot-extension

all: check build

build:
	mkdir -p build
	sjasmplus --sym=build/test_basic.sym --lst=build/test_basic.lst rom/test_basic.asm
	cp test_basic.bin build/test_basic.bin
	sjasmplus --sym=build/exrom.sym --lst=build/exrom.lst rom/exrom_build.asm
	cp exrom.bin build/exrom.bin
	tools/make_eightyone_dck.sh build/exrom.bin build/exrom.dck
	sjasmplus rom/zesarux_combined.asm

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
	tools/run_all_tests.sh

budget: build
	python3 tools/report_budget.py build/test_basic.lst build/exrom.lst build/test_basic.sym
	python3 tools/report_rom_map.py build/test_basic.lst build/exrom.lst

cplot-extension: build
	mkdir -p build/extensions
	sjasmplus rom/extensions/cplot.asm
	sjasmplus rom/test_extension_inject.asm --sym=rom/test_extension_inject.sym
	sjasmplus rom/extensions/cplot_test.asm
	sjasmplus rom/test_extension_clear_inject.asm --sym=rom/test_extension_clear_inject.sym
	sjasmplus rom/extensions/cplot_clear_test.asm

audit-basic: build
	python3 tools/report_basic_routines.py basic/basic.asm build/test_basic.sym

manual:
	python3 tools/build_user_manual_docx.py

clean:
	rm -rf build
