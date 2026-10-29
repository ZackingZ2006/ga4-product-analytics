"""Convert BigQuery UI JSON exports to CSV without altering values."""
import csv
import json
from pathlib import Path
import sys

for folder in map(Path, sys.argv[1:]):
    for path in sorted(folder.glob('*.json')):
        rows = json.loads(path.read_text(encoding='utf-8'))
        if rows:
            with path.with_suffix('.csv').open('w', encoding='utf-8', newline='') as f:
                writer = csv.DictWriter(f, fieldnames=rows[0].keys())
                writer.writeheader()
                writer.writerows(rows)
