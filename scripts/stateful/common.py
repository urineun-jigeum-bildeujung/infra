"""Shared helpers for maintenance commands; never log credentials or payloads."""
import base64
import datetime
import hashlib
import json
import os
import re
from pathlib import Path
import subprocess
import tempfile
import time

ACCOUNT = "297165773875"
REGION = "ap-northeast-2"
CLUSTER = "petflow-eks"
BUCKET = "petflow-dev-db-backups"
ROOT = Path(__file__).resolve().parents[2]
GITOPS = Path(os.environ.get("GITOPS_DIR", str(ROOT.parent / "gitops"))).resolve()


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def run(args, input_data=None):
    proc = subprocess.run([str(a) for a in args], input=input_data,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          universal_newlines=True)
    # stderr may contain Secret payloads or authentication details.
    require(proc.returncode == 0, "command failed: {} (exit {})".format(
        " ".join(str(a) for a in args[:3]), proc.returncode))
    return proc.stdout


def aws(*args):
    raw = run(["aws", "--region", REGION] + list(args) + ["--output", "json"])
    return json.loads(raw) if raw.strip() else {}


def kube(*args, **kwargs):
    timeout = "0" if args and args[0] in ("wait", "delete", "rollout") and any(str(a).startswith("--timeout") for a in args) else "30s"
    prefix = ["kubectl", "--request-timeout=" + timeout]
    if os.environ.get("KUBECONFIG"):
        prefix += ["--kubeconfig", os.environ["KUBECONFIG"]]
    else:
        prefix += ["--context", "petflow-dev"]
    return run(prefix + list(args), kwargs.get("input_data"))


def get(kind, name=None, namespace=None, selector=None):
    args = ["get", kind]
    if name:
        args += [name, "--ignore-not-found"]
    if namespace:
        args += ["-n", namespace]
    else:
        args += ["-A"]
    if selector:
        args += ["-l", selector]
    raw = kube(*(args + ["-o", "json"]))
    return json.loads(raw) if raw.strip() else None


def apply(document):
    kube("apply", "-f", "-", input_data=json.dumps(document))


def clean(document):
    """Strip server ownership fields; status must be restored explicitly."""
    doc = json.loads(json.dumps(document))
    metadata = doc["metadata"]
    doc["metadata"] = {k: metadata[k] for k in ("name", "namespace", "labels", "annotations")
                       if k in metadata}
    doc.pop("status", None)
    return doc


def utc():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def epoch(value):
    if isinstance(value, (int, float)):
        return float(value)
    # AWS CLI v1 can emit numeric timestamps; CLI v2 emits ISO 8601.
    if re.match(r"^\d+(\.\d+)?$", value):
        return float(value)
    offset = re.search(r"([+-])(\d\d):(\d\d)$", value)
    seconds = (int(offset.group(2)) * 3600 + int(offset.group(3)) * 60) if offset else 0
    if offset and offset.group(1) == "-":
        seconds = -seconds
    return datetime.datetime.strptime(value[:19], "%Y-%m-%dT%H:%M:%S").replace(
        tzinfo=datetime.timezone.utc).timestamp() - seconds


def save(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent))
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(value, handle, sort_keys=True)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, str(path))
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def load(path):
    with open(str(path)) as handle:
        return json.load(handle)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def upload(key, value):
    raw = json.dumps(value, sort_keys=True).encode()
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "object.json"
        path.write_bytes(raw)
        path.chmod(0o600)
        result = aws("s3api", "put-object", "--bucket", BUCKET, "--key", key,
                     "--body", str(path), "--content-type", "application/json",
                     "--server-side-encryption", "AES256", "--content-md5",
                     base64.b64encode(hashlib.md5(raw).digest()).decode())
    require(result.get("VersionId") not in (None, "null"), "backup bucket must have versioning enabled")
    ref = {"bucket": BUCKET, "key": key, "versionId": result["VersionId"], "sha256": sha(raw)}
    require(download(ref) == value, "S3 read-back mismatch")
    return ref


def download(ref):
    require(ref.get("bucket") == BUCKET, "unexpected backup bucket")
    require(ref.get("key", "").startswith("recovery/"), "unexpected object prefix")
    require(bool(ref.get("versionId")), "missing S3 object version")
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "download.json"
        aws("s3api", "get-object", "--bucket", BUCKET, "--key", ref["key"],
            "--version-id", ref["versionId"], str(path))
        raw = path.read_bytes()
    require(sha(raw) == ref["sha256"], "S3 object checksum mismatch")
    return json.loads(raw.decode())


def read_latest():
    # Listing failure is never interpreted as an absent backup.
    result = aws("s3api", "list-objects-v2", "--bucket", BUCKET,
                 "--prefix", "recovery/latest-complete.json")
    if not any(o["Key"] == "recovery/latest-complete.json" for o in result.get("Contents", [])):
        return None
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "latest.json"
        aws("s3api", "get-object", "--bucket", BUCKET,
            "--key", "recovery/latest-complete.json", str(path))
        return download(load(path)["manifest"])


def poll(function, ready, timeout=3600):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = function()
        if ready(value):
            return value
        time.sleep(10)
    raise RuntimeError("operation timed out")


def identity():
    require(aws("sts", "get-caller-identity")["Account"] == ACCOUNT, "unexpected AWS account")


def terraform_output(name):
    return run(["terraform", "-chdir=" + str(ROOT / "terraform/environments/dev"),
                "output", "-raw", name]).strip()
