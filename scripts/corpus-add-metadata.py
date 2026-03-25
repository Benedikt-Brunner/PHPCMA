#!/usr/bin/env python3
"""Add metadata to a PHPCMA golden file, handling invalid JSON escapes.

PHPCMA may emit unescaped backslashes in fqn fields (PHP namespace separators).
This script sanitizes them before parsing.

Usage: corpus-add-metadata.py <golden-file> <corpus-name> <duration-seconds>
"""
import json
import re
import sys
from datetime import datetime, timezone


def sanitize_json(raw: str) -> str:
    """Fix unescaped backslashes in JSON string values."""
    # Match backslashes that are NOT followed by valid JSON escape characters
    # and NOT already escaped (preceded by another backslash)
    return re.sub(r'(?<!\\)\\(?![\\"/bfnrtu])', r'\\\\', raw)


def main():
    if len(sys.argv) < 4:
        print("Usage: corpus-add-metadata.py <golden-file> <corpus-name> <duration-seconds>")
        sys.exit(1)

    golden_file = sys.argv[1]
    corpus_name = sys.argv[2]
    duration_s = float(sys.argv[3])

    with open(golden_file) as f:
        raw = f.read()

    data = json.loads(sanitize_json(raw))
    data["_metadata"] = {
        "corpus": corpus_name,
        "snapshot_time": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "duration_seconds": duration_s,
    }

    with open(golden_file, "w") as f:
        json.dump(data, f, indent=2)


if __name__ == "__main__":
    main()
