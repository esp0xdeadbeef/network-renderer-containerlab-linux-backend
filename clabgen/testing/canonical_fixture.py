from __future__ import annotations

import json
import os
import subprocess
import tempfile
from pathlib import Path
from typing import Any, Dict


def canonical_bundle_path(
    repo_root: Path, cpm: Dict[str, Any], scope: str, dest: Path | None = None
) -> Path:
    """Release a CPM fixture into a canonical bundle and return its path.

    The bundle is produced by network-realization-model (release + validation);
    the test never fabricates the release stamp.
    """
    root = Path(repo_root)
    helper = root / "tests" / "lib" / "canonical-bundle.sh"
    if not helper.exists():
        raise RuntimeError(f"canonical bundle helper missing: {helper}")

    payload = cpm.get("control_plane_model", cpm)
    tmp = Path(tempfile.mkdtemp(prefix="clab-canonical-fixture-"))
    cpm_path = tmp / "cpm.json"
    cpm_path.write_text(json.dumps({"control_plane_model": payload}))
    bundle_path = Path(dest) if dest is not None else tmp / "bundle.json"

    subprocess.run(
        [
            "bash",
            "-c",
            'source "$1"; emit_canonical_bundle "$2" "$3" "$4"',
            "canonical-bundle",
            str(helper),
            str(cpm_path),
            str(bundle_path),
            scope,
        ],
        check=True,
        cwd=str(root),
        env={**os.environ, "SMS_TEST_REPO_ROOT": str(root)},
    )
    return bundle_path


__all__ = ["canonical_bundle_path"]
