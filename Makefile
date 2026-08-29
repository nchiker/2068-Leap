.PHONY: all build check smoke-build test budget audit-basic manual clean

all: check build

build:
	mkdir -p build
	sjasmplus --sym=build/test_basic.sym --lst=build/test_basic.lst rom/test_basic.asm
	cp test_basic.bin build/test_basic.bin
	sjasmplus --sym=build/exrom.sym --lst=build/exrom.lst rom/exrom_build.asm
	cp exrom.bin build/exrom.bin
	tools/make_eightyone_dck.sh build/exrom.bin build/exrom.dck
	sjasmplus rom/zesarux_combined.asm

check:
	python3 tools/check_asm.py
	python3 tools/check_docs.py
	python3 tools/check_storage_contract.py
	python3 tools/check_tape_fixture.py
	python3 tools/check_commit_validation.py
	tools/build_smoke_roms.sh

smoke-build:
	tools/build_smoke_roms.sh

test: all
	tools/run_smoke_rom_tests.sh
	tools/run_editor_auto_test.sh
	tools/run_all_tests.sh

budget: build
	python3 tools/report_budget.py build/test_basic.lst build/exrom.lst build/test_basic.sym
	python3 tools/report_rom_map.py build/test_basic.lst build/exrom.lst

audit-basic: build
	python3 tools/report_basic_routines.py basic/basic.asm build/test_basic.sym

manual:
	python3 tools/build_user_manual_docx.py

clean:
	rm -rf build
