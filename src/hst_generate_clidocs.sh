#!/usr/bin/env bash
# info: generate clidocs help summary
# options: NONE
#
# This function automatically iterates through Hestia CLI binaries and logs their help outputs.

OUTPUT_DOC="$HOME/hestia_cli_help.txt"
echo "=== HestiaCP CLI Help Documentation Summary ===" > "$OUTPUT_DOC"

for file in /usr/local/hestia/bin/*; do
    if [ -f "$file" ] && [ -x "$file" ]; then
        echo "" >> "$OUTPUT_DOC"
        echo "--------------------------------------------------------" >> "$OUTPUT_DOC"
        echo "Command: $(basename "$file")" >> "$OUTPUT_DOC"
        echo "--------------------------------------------------------" >> "$OUTPUT_DOC"
        "$file" >> "$OUTPUT_DOC" 2>&1
    fi
done

if [ -f /etc/freebsd-version ] || [ "$(uname -s)" = "FreeBSD" ]; then
    sed -i '' 's|/usr/local/hestia/bin/||g' "$OUTPUT_DOC"
else
    sed -i 's|/usr/local/hestia/bin/||g' "$OUTPUT_DOC"
fi

echo "[ ✓ ] CLI Documentation successfully generated at: $OUTPUT_DOC"