.PHONY: all build check test budget clean

all: check build

build:
	mkdir -p build
	sjasmplus --sym=build/test_basic.sym --lst=build/test_basic.lst rom/test_basic.asm
	cp test_basic.bin build/test_basic.bin
	sjasmplus --sym=build/exrom.sym --lst=build/exrom.lst rom/exrom_build.asm
	cp exrom.bin build/exrom.bin

check:
	python3 tools/check_asm.py
	python3 tools/check_docs.py
	python3 tools/check_storage_contract.py
	python3 tools/check_tape_fixture.py

test: all
	tools/run_all_tests.sh

budget: build
	python3 tools/report_budget.py build/test_basic.lst build/exrom.lst build/test_basic.sym

clean:
	rm -rf build
