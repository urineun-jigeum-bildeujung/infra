#!/usr/bin/env python3
"""Explicit maintenance operations; default execution never initializes missing data."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

from common import (ACCOUNT, BUCKET, CLUSTER, GITOPS, REGION, ROOT, apply, aws,
                    download, get, identity, kube, load, read_latest, require,
                    run, save, sha, upload, utc)
import bootstrap
import cnpg
import kafka
import maintenance
import redis_cart


def log(message):
    print("[stateful] " + message, flush=True)


def source_hashes():
    paths = ("platform/40-kafka-operator/application.yaml", "platform/50-kafka-cluster/manifests/kafka.yaml",
             "platform/50-kafka-cluster/manifests/kafka-users.yaml", "platform/40-redis/application.yaml",
             "platform/91-external-secrets-config/manifests/redis-credentials.yaml",
             "platform/00-internal-ca/manifests/internal-ca.yaml", "platform/39-redis-cert/manifests/redis-cert.yaml")
    hashes = {p: sha((GITOPS / p).read_bytes()) for p in paths}
    # Qualification is tied to executable recovery code, not only the topology file.
    for p in ("bootstrap.py", "kafka.py", "redis_cart.py", "common.py", "cnpg.py", "maintenance.py", "control.py"):
        hashes["infra/scripts/stateful/" + p] = sha((Path(__file__).parent / p).read_bytes())
    for p in ("cnpg-s3-backup.sh", "restore-cnpg-before-gitops.sh"):
        hashes["infra/scripts/" + p] = sha((ROOT / "scripts" / p).read_bytes())
    return hashes


def qualification():
    path = os.environ.get("PETFLOW_STATEFUL_QUALIFICATION")
    require(path, "격리 복원 검증 보고서가 필요합니다. PETFLOW_STATEFUL_QUALIFICATION을 지정하세요. 운영 리소스는 아직 중지하지 않았습니다.")
    report = load(path)
    require(report.get("schemaVersion") == 1 and report.get("isolated") is True, "isolated qualification evidence required")
    require(report.get("sourceHashes") == source_hashes(), "qualification is for different code/configuration")
    require(report.get("kafkaVersion") == "3.9.0" and report.get("strimziVersion") == "0.45.2", "qualification version mismatch")
    tests = ("coldRestore", "clusterIdentity", "committedOffsets", "messages", "scramAuthentication",
             "produceConsumeAfterRestore", "cartOnly", "redisRestart", "partialRestoreRetry")
    require(all(report.get("checks", {}).get(k) is True for k in tests), "qualification checks incomplete")
    require(report.get("evidenceUri") and report.get("verifiedAt"), "qualification evidence location/time missing")
    return report


def manifest_shape(manifest):
    require(manifest.get("schemaVersion") == 1 and manifest.get("complete") is True, "incomplete recovery manifest")
    require(manifest.get("account") == ACCOUNT and manifest.get("region") == REGION and
            manifest.get("cluster") == CLUSTER, "manifest environment mismatch")
    require(re.match(r"^[A-Za-z0-9_-]{1,40}$", manifest.get("runId", "")), "invalid backup run ID")
    require(manifest.get("quiescedAt") and manifest.get("sourceHashes"), "backup barrier evidence missing")
    require(manifest["cnpg"]["targetName"] == "petflow_" + manifest["runId"].replace("-", "_"), "CNPG restore point belongs to another run")
    for name in ("redis", "kafka"):
        require(manifest[name]["key"].startswith("recovery/runs/" + manifest["runId"] + "/"), "artifact belongs to another run")


def verify_manifest(manifest, run_id=None):
    manifest_shape(manifest)
    if run_id:
        require(manifest["runId"] == run_id, "backup is not from this destroy run")
    cnpg.verify(manifest["cnpg"])
    redis_cart.validate_payload(download(manifest["redis"]))
    state = download(manifest["kafka"])
    require(state["runId"] == manifest["runId"], "Kafka run ID mismatch")
    kafka.verify_recovery_points(state)


def evidence_directory():
    directory = Path(os.environ.get("PETFLOW_DESTROY_EVIDENCE_DIR", str(ROOT / ".destroy-evidence")))
    directory.mkdir(parents=True, exist_ok=True)
    directory.chmod(0o700)
    return directory


def backup():
    identity()
    qualification()  # MUST precede every live mutation.
    run_id = os.environ.get("PETFLOW_DESTROY_RUN_ID", "")
    require(re.match(r"^[A-Za-z0-9_-]{1,40}$", run_id), "invalid destroy run ID")
    require(aws("s3api", "get-bucket-versioning", "--bucket", BUCKET).get("Status") == "Enabled", "versioned backup bucket required")
    existing = aws("s3api", "list-objects-v2", "--bucket", BUCKET,
                   "--prefix", "recovery/runs/" + run_id + "/", "--max-keys", "1")
    require(not existing.get("Contents"), "backup run already has artifacts; use a new run ID")
    kafka.inventory()  # preflight topology, CA and disk identity before stopping services
    directory = evidence_directory()
    journal_path = directory / (run_id + "-maintenance.json")
    log("서비스 원래 상태 기록 및 업무 쓰기 중단")
    barrier = maintenance.quiesce(journal_path, run_id)
    cnpg.assert_no_clients()
    hashes = cnpg.fingerprints()
    log("장바구니만 추출 (로그인 세션/락 제외)")
    payload = redis_cart.export_cart([0])
    redis_ref = upload("recovery/runs/" + run_id + "/cart.json", payload)
    log("CNPG base backup 및 지정 WAL 복원 지점 확인")
    source_path = directory / (run_id + "-cnpg-source.json")
    env = dict(os.environ, PETFLOW_CNPG_PINNED_OUTPUT=str(source_path),
               PETFLOW_CNPG_RESTORE_POINT="petflow_" + run_id.replace("-", "_"))
    import subprocess
    subprocess.check_call([str(ROOT / "scripts/cnpg-s3-backup.sh"), os.environ["KUBECONFIG"]], env=env)
    subprocess.check_call([str(ROOT / "scripts/backup-cnpg-before-destroy.sh"), "--manifest",
                           os.environ["PETFLOW_CNPG_BACKUP_MANIFEST"]])
    log("Kafka 정상 종료 및 EBS AWS Backup")
    state = kafka.backup(run_id, directory / (run_id + "-kafka-journal.json"))
    kafka_ref = upload("recovery/runs/" + run_id + "/kafka.json", state)
    maintenance.assert_no_business_pods()
    cnpg.assert_no_clients()
    require(cnpg.fingerprints() == hashes, "PostgreSQL business data changed during backup")
    redis_cart.assert_unchanged(payload)
    manifest = {"schemaVersion": 1, "complete": True, "runId": run_id, "account": ACCOUNT,
                "region": REGION, "cluster": CLUSTER, "quiescedAt": barrier["quiescedAt"],
                "completedAt": utc(), "sourceHashes": source_hashes(), "cnpg": load(source_path),
                "databaseFingerprints": hashes, "redis": redis_ref, "kafka": kafka_ref}
    verify_manifest(manifest, run_id)
    ref = upload("recovery/runs/" + run_id + "/manifest.json", manifest)
    # One versioned object publishes the complete cohort. No component advances it alone.
    upload("recovery/latest-complete.json", {"manifest": ref})
    manifest_path = Path(os.environ["PETFLOW_STATEFUL_BACKUP_MANIFEST"])
    save(manifest_path, manifest)
    log("통합 백업 검증 완료: " + str(manifest_path))


def mark(data):
    apply({"apiVersion": "v1", "kind": "ConfigMap", "metadata": {
        "name": "stateful-recovery", "namespace": "database"}, "data": data})


def current_ready():
    cluster = get("cluster", "petflow-db", "database")
    require(cluster and any(c.get("type") == "Ready" and c.get("status") == "True"
                           for c in cluster.get("status", {}).get("conditions", [])), "CNPG is not Ready")
    redis = get("statefulset", "redis-master", "redis")
    require(redis and redis.get("status", {}).get("readyReplicas", 0) == 1, "Redis is not Ready")
    require(kafka.ready(), "Kafka is not Ready")


def restore():
    identity()
    marker = get("configmap", "stateful-recovery", "database")
    if marker and marker["data"].get("phase") == "ready":
        current_ready()
        log("이미 검증된 데이터 유지. 기존 장바구니/DB/Kafka를 덮어쓰지 않습니다.")
        return
    exists = get("cluster", "petflow-db", "database")
    if exists and marker is None:
        current_ready()  # Adoption is allowed only when all three live stores already exist.
        mark({"phase": "ready", "runId": "existing", "verifiedAt": utc()})
        log("기존 정상 클러스터를 유지했습니다. 새 백업 복원은 실행하지 않습니다.")
        return
    maintenance.assert_no_business_pods()
    # Keep the originally selected cohort even if a newer backup is published.
    selected = marker and marker.get("data", {}).get("selectedManifest")
    latest = json.loads(selected) if selected else read_latest()
    if latest is None:
        require(os.environ.get("PETFLOW_STATEFUL_INITIALIZE") == "true", "통합 백업이 없습니다. 최초 설치만 PETFLOW_STATEFUL_INITIALIZE=true를 사용하세요. 기존 CNPG 단독 백업으로 자동 대체하지 않습니다.")
        # Initialization must not hide any old/partial backup artifacts.
        if marker is None:
            for prefix in ("recovery/runs/", "cnpg/"):
                listed = aws("s3api", "list-objects-v2", "--bucket", BUCKET, "--prefix", prefix, "--max-keys", "1")
                require(not listed.get("Contents"), "backup artifacts exist; refusing empty initialization")
            apply({"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": "database"}})
            mark({"phase": "initializing", "runId": "initial"})
        else:
            require(marker["data"] == {"phase": "initializing", "runId": "initial"}, "unexpected incomplete restore without a cohort")
        run([str(ROOT / "scripts/restore-cnpg-before-gitops.sh")])
        mark({"phase": "initializing", "runId": "initial"})
        bootstrap.prepare_redis()
        bootstrap.render_application("platform/40-kafka-operator/application.yaml", "kafka")
        kube("wait", "--for=condition=Established", "crd/kafkas.kafka.strimzi.io", "--timeout=5m")
        kube("apply", "-f", str(GITOPS / "platform/50-kafka-cluster/manifests"))
        from common import poll
        poll(kafka.ready, bool, 1200)
        current_ready()
        mark({"phase": "ready", "runId": "initial", "verifiedAt": utc()})
        return
    verify_manifest(latest)
    require(latest["sourceHashes"] == source_hashes(), "restore code/GitOps configuration differs from the backup; use the recorded revisions")
    directory = ROOT / ".restore-evidence" / latest["runId"]
    directory.mkdir(parents=True, exist_ok=True)
    directory.chmod(0o700)
    if marker:
        require(marker["data"]["runId"] == latest["runId"], "partial restore must resume the same cohort")
        require(marker["data"].get("manifestHash") == sha(json.dumps(latest, sort_keys=True).encode()),
                "partial restore manifest changed")
    else:
        apply({"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": "database"}})
        mark({"phase": "restoring", "runId": latest["runId"],
              "manifestHash": sha(json.dumps(latest, sort_keys=True).encode()),
              "selectedManifest": json.dumps(latest, sort_keys=True)})
    journal_path = directory / "progress.json"
    progress = load(journal_path) if journal_path.exists() else {"runId": latest["runId"]}
    require(progress["runId"] == latest["runId"], "local restore journal belongs to another run")
    source = directory / "cnpg.json"
    save(source, latest["cnpg"])
    if not progress.get("cnpg"):
        import subprocess
        subprocess.check_call([str(ROOT / "scripts/restore-cnpg-before-gitops.sh")],
                              env=dict(os.environ, PETFLOW_CNPG_PINNED_SOURCE=str(source)))
        require(cnpg.fingerprints() == latest["databaseFingerprints"], "restored PostgreSQL data differs")
        progress["cnpg"] = True
        save(journal_path, progress)
    if not progress.get("redis"):
        bootstrap.prepare_redis()
        payload = download(latest["redis"])
        # Partial Redis writes are never silently overwritten. Keep the same cohort,
        # verify the exact expected key set before treating an interrupted import as complete.
        was_started = progress.get("redisStarted", False)
        progress["redisStarted"] = True
        save(journal_path, progress)
        progress["redis"] = redis_cart.restore_cart(payload, allow_partial=was_started)
        save(journal_path, progress)
    if not progress.get("kafka"):
        state = download(latest["kafka"])
        progress["kafka"] = bootstrap.restore_kafka(state, directory / "kafka-progress.json")
        save(journal_path, progress)
    current_ready()
    mark({"phase": "ready", "runId": latest["runId"], "verifiedAt": utc()})
    save(directory / "verified.json", {"runId": latest["runId"], "verifiedAt": utc(), "steps": progress})
    log("CNPG/장바구니/Kafka 복원 검증 완료. GitOps 서비스 배포를 시작할 수 있습니다.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("backup", "restore", "verify", "begin-cleanup", "resume-maintenance", "resume-kafka", "source-hashes"))
    parser.add_argument("--manifest")
    parser.add_argument("--journal")
    args = parser.parse_args()
    if args.mode == "source-hashes":
        print(json.dumps(source_hashes(), indent=2))
    elif args.mode == "backup":
        backup()
    elif args.mode == "restore":
        restore()
    elif args.mode in ("verify", "begin-cleanup"):
        identity()
        require(args.manifest, "manifest required before deletion")
        manifest = load(args.manifest)
        verify_manifest(manifest, os.environ.get("PETFLOW_DESTROY_RUN_ID"))
        path = evidence_directory() / (manifest["runId"] + "-maintenance.json")
        journal = load(path)
        require(journal["status"] in ("quiesced", "deleting"), "services were resumed after this backup")
        if args.mode == "begin-cleanup":
            journal["status"] = "deleting"
            save(path, journal)
        log("통합 삭제 전 백업 검증 통과")
    else:
        identity()
        require(args.journal, "journal required")
        if args.mode == "resume-kafka":
            kafka.resume(Path(args.journal))
        else:
            maintenance.resume(Path(args.journal))


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, KeyError, ValueError, OSError, subprocess.CalledProcessError) as error:
        print("[stateful] ERROR: " + str(error), file=sys.stderr)
        print("[stateful] 중지된 서비스는 자동 재개하지 않습니다. maintenance journal과 문서를 확인하세요.", file=sys.stderr)
        sys.exit(1)
