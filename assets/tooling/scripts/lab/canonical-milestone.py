#!/usr/bin/env python3
import json,sys
from pathlib import Path
value=sys.argv[1].upper()
for entry in json.loads(Path(__file__).with_name('milestones.json').read_text())['milestones']:
    if value==entry['milestone'] or value.lower() in entry['aliases']:
        print(entry['milestone']);raise SystemExit(0)
print(value)
