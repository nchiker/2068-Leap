#!/bin/sh
set -eu

input=${1:-build/exrom.bin}
output=${2:-build/exrom.dck}

if [ ! -f "$input" ]; then
    echo "make_eightyone_dck: input not found: $input" >&2
    exit 1
fi

size=$(wc -c < "$input")
if [ "$size" -ne 8192 ]; then
    echo "make_eightyone_dck: expected an 8192-byte EXROM, got $size bytes" >&2
    exit 1
fi

mkdir -p "$(dirname "$output")"
printf '\376\000\000\000\000\000\000\002\000' > "$output"
dd if="$input" of="$output" bs=1 seek=9 conv=notrunc 2>/dev/null

output_size=$(wc -c < "$output")
if [ "$output_size" -ne 8201 ]; then
    echo "make_eightyone_dck: generated file has unexpected size: $output_size" >&2
    exit 1
fi

echo "EightyOne cartridge: $output"
