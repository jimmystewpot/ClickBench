import json
import subprocess
import sys
from pathlib import Path

def test_compare_cli(tmp_path):
    v1 = {
        "system": "StarRocks",
        "version": "4.0.14",
        "machine": "c6a.4xlarge",
        "load_time": 500,
        "data_size": 18000000000,
        "result": [
            [1.0, 0.5, 0.5],
            [2.0, 1.0, 1.0]
        ]
    }
    v2 = {
        "system": "StarRocks",
        "version": "4.1.1",
        "machine": "c6a.4xlarge",
        "load_time": 450,
        "data_size": 17500000000,
        "result": [
            [0.5, 0.25, 0.25], # 50% faster
            [3.0, 1.5, 1.5]   # 50% slower
        ]
    }
    f1 = tmp_path / "4.0.14.json"
    f2 = tmp_path / "4.1.1.json"
    f1.write_text(json.dumps(v1))
    f2.write_text(json.dumps(v2))

    compare_script = Path(__file__).resolve().parent.parent / "compare.py"
    cmd = [sys.executable, str(compare_script), str(f1), str(f2)]
    out = subprocess.check_output(cmd, text=True)

    assert "StarRocks 4.0.14" in out
    assert "StarRocks 4.1.1" in out
    assert "Q0" in out
    assert "-50.0%" in out
    assert "+50.0%" in out
    assert "Geometric mean" in out
