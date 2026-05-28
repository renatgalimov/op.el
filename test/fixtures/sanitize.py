#!/usr/bin/env python3
"""Sanitize fixture files by replacing real IDs with mock ones.

Run this after generating fixtures with OP_MODE=verify to ensure
no real 1Password account IDs leak into the repository.
"""

import sys
from pathlib import Path

FIXTURE_DIR = Path(__file__).resolve().parent

# Mapping of real IDs to mock IDs.
# Add new entries here when additional IDs need sanitizing.
REPLACEMENTS = {
    "VK6XJVTGTFE3TG6WEQZLYIDWEQ": "PXCTHFHEUXV4KPI5J63KDYOBO5",
    "IAH6DN35JBCRLIS57PQOMZYK6Y": "WRYZIV66ZGZOUUQR3SKXFQ753Q",
    "HQFE3WKP3FDQJA3VHPTEX3HZSI": "PXCTHFHEUXV4KPI5J63KDYOBO5",
    "rgalimov": "jondoe",
}


def sanitize_file(filepath):
    """Apply all replacements to a single file. Returns True if modified."""
    text = filepath.read_text()
    original = text
    for real_id, mock_id in REPLACEMENTS.items():
        text = text.replace(real_id, mock_id)
    if text != original:
        filepath.write_text(text)
        return True
    return False


def main():
    modified_count = 0
    file_count = 0
    for filepath in sorted(FIXTURE_DIR.iterdir()):
        if filepath.name == Path(__file__).name:
            continue
        if not filepath.is_file():
            continue
        file_count += 1
        if sanitize_file(filepath):
            modified_count += 1
            print(f"sanitized: {filepath.name}", file=sys.stderr)

    print(
        f"Checked {file_count} files, sanitized {modified_count}.",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
