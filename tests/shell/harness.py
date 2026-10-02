"""Run Bash modules with synthetic inputs; no AWS/Kubernetes executables required."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def run(body, fixtures=None, sources=None):
    with tempfile.TemporaryDirectory() as directory:
        folder = Path(directory)
        for name, value in (fixtures or {}).items():
            path = folder / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(value) if not isinstance(value, str) else value)
        sources = sources or ["scripts/reconcile-grafana-admin.sh"]
        script = "set -Eeuo pipefail\n" + "\n".join('source "' + str(ROOT / s) + '"' for s in sources)
        script += '\ngrafana_init\ncd "$CASE_DIR"\n' + body
        env = dict(os.environ, CASE_DIR=str(folder), GITOPS_DIR=str(ROOT.parent / "gitops"))
        for name in ("AWS_PROFILE", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN", "KUBECONFIG", "PETFLOW_STATEFUL_TARGET_FILE"):
            env.pop(name, None)
        result = subprocess.run(["bash", "-c", script], cwd=str(ROOT), env=env,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, timeout=20)
        output = {str(p.relative_to(folder)): p.read_text() for p in folder.rglob("*") if p.is_file()}
        return result, output
