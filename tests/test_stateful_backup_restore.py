"""Behavioral maintenance tests; no AWS/Kubernetes connection or credentials needed."""
import base64
import contextlib
import copy
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/stateful"))
import bootstrap
import common
import control
import redis_cart
import maintenance
import kafka
import yaml


def payload(records):
    return {"schemaVersion": 1, "redisVersion": "7.4.3", "databases": [0],
            "count": len(records), "records": records,
            "fingerprint": redis_cart.fingerprint(records)}


def record(key=b"cart:10", value=b"\x00\xff\r\n", expiry=None):
    return {"db": 0, "key": base64.b64encode(key).decode(),
            "dump": base64.b64encode(value).decode(), "expiresAtMs": expiry, "type": "hash"}


class FakeRedis:
    def __init__(self, records=()):
        self.data = {0: {base64.b64decode(r["key"]): copy.deepcopy(r) for r in records}}
        self.database = 0
        self.writes = []
        self.fsync = True

    def command(self, *args):
        cmd = args[0]
        if cmd == "INFO":
            return b"redis_version:7.4.3\r\n"
        if cmd == "SELECT":
            self.database = args[1]
            self.data.setdefault(self.database, {})
            return b"OK"
        if cmd == "DBSIZE":
            return len(self.data[self.database])
        if cmd == "TIME":
            return [b"1000", b"0"]
        if cmd == "SCAN":
            keys = [k for k in self.data[self.database] if k.startswith(b"cart:")]
            return [b"0", keys + keys]  # SCAN may return duplicates.
        if cmd == "EVAL":
            r = self.data[self.database].get(args[-1])
            return [] if r is None else [base64.b64decode(r["dump"]), r["expiresAtMs"] or -1, r["type"].encode()]
        if cmd == "RESTORE":
            _, key, expiry, value = args[:4]
            self.writes.append(args)
            self.data[self.database][key] = record(key, value, expiry or None)
            return b"OK"
        if cmd == "WAITAOF":
            return [1 if self.fsync else 0, 0]
        raise AssertionError(args)


@contextlib.contextmanager
def fake_connection(client):
    yield client


class RedisTests(unittest.TestCase):
    def restore(self, source, client, partial=False):
        with patch.object(redis_cart, "connect", lambda: fake_connection(client)):
            return redis_cart.restore_cart(source, partial)

    def test_binary_payload_round_trips_and_scan_deduplicates(self):
        source = payload([record()])
        client = FakeRedis()
        result = self.restore(source, client)
        self.assertEqual(base64.b64decode(client.data[0][b"cart:10"]["dump"]), b"\x00\xff\r\n")
        self.assertEqual(result["restored"], 1)
        self.assertTrue(result["aofFsyncVerified"])
        self.assertEqual(len(client.writes), 1)

    def test_zero_carts_is_success(self):
        self.assertEqual(self.restore(payload([]), FakeRedis())["restored"], 0)

    def test_expired_keys_are_not_resurrected(self):
        client = FakeRedis()
        result = self.restore(payload([record(expiry=900000)]), client)
        self.assertEqual(result["expired"], 1)
        self.assertEqual(client.writes, [])

    def test_absolute_ttl_is_preserved(self):
        client = FakeRedis()
        self.restore(payload([record(expiry=2000000)]), client)
        self.assertIn("ABSTTL", client.writes[0])
        self.assertEqual(client.writes[0][2], 2000000)

    def test_sessions_are_rejected_before_writing(self):
        client = FakeRedis()
        with self.assertRaisesRegex(RuntimeError, "allowlist"):
            self.restore(payload([record(b"spring:session:1")]), client)
        self.assertEqual(client.writes, [])

    def test_normal_restore_never_overwrites_existing_cart(self):
        client = FakeRedis([record(value=b"new user data")])
        with self.assertRaisesRegex(RuntimeError, "nonempty"):
            self.restore(payload([record()]), client)
        self.assertEqual(client.writes, [])

    def test_same_cohort_partial_restore_only_fills_missing_keys(self):
        source = payload([record(), record(b"cart:20", b"second")])
        client = FakeRedis([record()])
        self.restore(source, client, partial=True)
        self.assertEqual([w[1] for w in client.writes], [b"cart:20"])

    def test_modified_partial_restore_is_rejected(self):
        client = FakeRedis([record(value=b"user changed")])
        with self.assertRaisesRegex(RuntimeError, "modified"):
            self.restore(payload([record()]), client, partial=True)
        self.assertEqual(client.writes, [])

    def test_noncart_data_in_partial_restore_is_rejected(self):
        client = FakeRedis([record(b"session:1")])
        with self.assertRaisesRegex(RuntimeError, "non-cart"):
            self.restore(payload([]), client, partial=True)

    def test_aof_failure_prevents_success(self):
        client = FakeRedis()
        client.fsync = False
        with self.assertRaisesRegex(RuntimeError, "fsync"):
            self.restore(payload([record()]), client)

    def test_duplicate_or_corrupt_backup_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, "duplicate"):
            redis_cart.validate_payload(payload([record(), record()]))
        source = payload([record()])
        source["records"][0]["dump"] = "changed"
        with self.assertRaisesRegex(RuntimeError, "checksum"):
            redis_cart.validate_payload(source)

    def test_resp_bulk_preserves_zero_and_non_utf8(self):
        class Connection:
            def makefile(self, _):
                return io.BytesIO(b"$4\r\n\x00\xff\r\n\r\n")
            def sendall(self, raw):
                self.raw = raw
        connection = Connection()
        self.assertEqual(redis_cart.Redis(connection).command("DUMP", b"cart:1"), b"\x00\xff\r\n")


class GuardTests(unittest.TestCase):
    def test_rollout_controller_stops_only_after_business_pods_drain(self):
        state={"status":"captured", "controllers":[{"namespace":"argo-rollouts","kind":"deployment","name":"argo-rollouts","replicas":2}],
               "workloads":[{"namespace":"auth-service","kind":"rollouts.argoproj.io","name":"generic-service","replicas":2}],
               "scaledObjects":[],"hpas":[],"cronJobs":[]}
        events=[]
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(maintenance,"capture",return_value=state), patch.object(maintenance,"poll"), \
                    patch.object(maintenance,"scale",side_effect=lambda item,n:events.append(item["namespace"])), \
                    patch.object(maintenance,"assert_no_business_pods",side_effect=lambda:events.append("drained")):
                maintenance.quiesce(Path(directory)/"state.json","test")
        self.assertEqual(events,["auth-service","drained","argo-rollouts"])

    def test_aws_timestamp_formats_have_same_epoch(self):
        expected = common.epoch("2026-10-01T00:00:00Z")
        self.assertEqual(common.epoch("2026-10-01T09:00:00+09:00"), expected)
        self.assertEqual(common.epoch(expected), expected)
        self.assertEqual(common.epoch(str(expected)), expected)

    def test_keda_resume_removes_runtime_pause_annotation(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "maintenance.json"
            common.save(path, {"status": "quiesced", "workloads": [], "controllers": [],
                               "cronJobs": [], "hpas": [], "scaledObjects": [{"metadata": {"name": "orders", "namespace": "order-service"}}]})
            with patch.object(maintenance, "get", return_value={"status": {"conditions": [{"type": "Ready", "status": "True"}]}}), \
                    patch.object(maintenance, "apply"), patch.object(maintenance, "kube") as kube:
                maintenance.resume(path)
                self.assertIsNone(json.loads(kube.call_args[0][-1])["metadata"]["annotations"]["autoscaling.keda.sh/paused-replicas"])

    def test_keda_hpa_owner_is_restored_before_unpause(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/"maintenance.json"
            common.save(path,{"status":"quiesced","workloads":[],"controllers":[],"cronJobs":[],
                "hpas":[{"metadata":{"name":"keda-hpa-payment","namespace":"payment-service"}}],
                "scaledObjects":[{"metadata":{"name":"payment","namespace":"payment-service"}}]})
            def get(kind,*args,**kwargs):
                if kind=="kafka":return {"status":{"conditions":[{"type":"Ready","status":"True"}]}}
                return {"apiVersion":"keda.sh/v1alpha1","kind":"ScaledObject","metadata":{"name":"payment","uid":"original-uid"}}
            with patch.object(maintenance,"get",side_effect=get),patch.object(maintenance,"apply") as apply,patch.object(maintenance,"kube"):
                maintenance.resume(path)
                first=apply.call_args_list[0][0][0]
                self.assertEqual(first["metadata"]["name"],"keda-hpa-payment")
                self.assertEqual(first["metadata"]["ownerReferences"][0]["uid"],"original-uid")

    def test_kafka_defaults_allowed_but_storage_changes_rejected(self):
        self.assertTrue(bootstrap.desired_matches({"replicas": 1}, {"replicas": 1, "defaults": True}))
        self.assertFalse(bootstrap.desired_matches({"storage": {"size": "10Gi"}}, {"storage": {"size": "20Gi"}}))

    def test_kafka_retry_after_startup_does_not_restore_disk_again(self):
        with open(str(common.GITOPS / "platform/50-kafka-cluster/manifests/kafka.yaml")) as handle:
            documents = list(yaml.safe_load_all(handle))
        cluster = next(d for d in documents if d["kind"] == "Kafka")
        pools = [d for d in documents if d["kind"] == "KafkaNodePool"]
        state = {"runId": "retry", "kafkaVersion": "3.9.0", "strimziVersion": "0.45.2",
                 "cluster": cluster, "pools": pools, "clusterId": "original", "nodeIds": [0], "offsets": {"saved": True},
                 "secrets": [], "topics": [], "users": []}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "progress.json"
            common.save(path, {"runId": "retry", "volumes": {}, "starting": True})
            with patch.object(bootstrap, "get", return_value={"metadata": {"annotations": {"petflow.io/recovery-run": "retry"}}}), \
                    patch.object(bootstrap.kafka, "ready", side_effect=[False, True]), \
                    patch.object(bootstrap, "poll"), patch.object(bootstrap, "kube"), \
                    patch.object(bootstrap.kafka, "inventory", return_value={"clusterId": "original", "nodeIds": [0], "podName": "restored"}), \
                    patch.object(bootstrap.kafka, "offsets", return_value={"saved": True}), \
                    patch.object(bootstrap, "aws") as aws, patch.object(bootstrap, "render_application") as render:
                result = bootstrap.restore_kafka(state, path)
                self.assertTrue(result["verified"])
                aws.assert_not_called()
                render.assert_not_called()

    def test_qualification_absent_aborts_before_live_mutation(self):
        with patch.dict(os.environ, {"PETFLOW_STATEFUL_QUALIFICATION": ""}), \
                patch.object(control, "identity"), patch.object(control.maintenance, "quiesce") as stop, \
                patch.object(control.kafka, "inventory") as inventory:
            with self.assertRaisesRegex(RuntimeError, "격리"):
                control.backup()
            stop.assert_not_called()
            inventory.assert_not_called()

    def test_qualification_is_invalidated_by_code_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "report.json"
            path.write_text(json.dumps({"schemaVersion": 1, "isolated": True, "sourceHashes": {}}))
            with patch.dict(os.environ, {"PETFLOW_STATEFUL_QUALIFICATION": str(path)}):
                with self.assertRaisesRegex(RuntimeError, "different code"):
                    control.qualification()

    def test_live_ready_apply_does_not_run_data_restore(self):
        with patch.object(control, "identity"), patch.object(control, "get", return_value={"data": {"phase": "ready"}}), \
                patch.object(control, "current_ready"), patch.object(control, "read_latest") as latest, \
                patch.object(control.redis_cart, "restore_cart") as restore:
            control.restore()
            latest.assert_not_called()
            restore.assert_not_called()

    def test_missing_cohort_never_initializes_without_explicit_request(self):
        with patch.object(control, "identity"), patch.object(control, "get", return_value=None), \
                patch.object(control.maintenance, "assert_no_business_pods"), \
                patch.object(control, "read_latest", return_value=None), patch.object(control, "run") as invoke, \
                patch.dict(os.environ, {"PETFLOW_STATEFUL_INITIALIZE": "false"}):
            with self.assertRaisesRegex(RuntimeError, "통합 백업"):
                control.restore()
            invoke.assert_not_called()

    def test_s3_checksum_failure_never_returns_payload(self):
        def aws_stub(*args):
            Path(args[-1]).write_text('{"records":[]}')
            return {}
        with patch.object(common, "aws", side_effect=aws_stub):
            with self.assertRaisesRegex(RuntimeError, "checksum"):
                common.download({"bucket": common.BUCKET, "key": "recovery/runs/x/cart.json",
                                 "versionId": "one", "sha256": "wrong"})

    def test_mixed_run_manifest_is_rejected(self):
        source = {"schemaVersion": 1, "complete": True, "account": common.ACCOUNT,
                  "region": common.REGION, "cluster": common.CLUSTER, "runId": "new",
                  "quiescedAt": "now", "sourceHashes": {"x": "hash"},
                  "cnpg": {"targetName": "petflow_new"},
                  "redis": {"key": "recovery/runs/old/cart.json"},
                  "kafka": {"key": "recovery/runs/new/kafka.json"}}
        with self.assertRaisesRegex(RuntimeError, "another run"):
            control.manifest_shape(source)

    def test_partial_redis_failure_does_not_publish_ready_marker(self):
        # A coordinator checkpoint is written before import, but ready must not be published.
        with tempfile.TemporaryDirectory() as directory:
            cohort = {"runId": "test-run", "sourceHashes": {"same": "hash"}, "cnpg": {},
                      "databaseFingerprints": {}, "redis": {}}
            marker = {"data": {"runId": "test-run", "phase": "restoring",
                               "manifestHash": common.sha(json.dumps(cohort, sort_keys=True).encode()),
                               "selectedManifest": json.dumps(cohort)}}
            progress = Path(directory) / ".restore-evidence/test-run/progress.json"
            common.save(progress, {"runId": "test-run", "cnpg": True})
            with patch.object(control, "ROOT", Path(directory)), patch.object(control, "identity"), \
                    patch.object(control, "get", return_value=marker), \
                    patch.object(control.maintenance, "assert_no_business_pods"), \
                    patch.object(control, "read_latest", side_effect=AssertionError("must keep pinned cohort")), \
                    patch.object(control, "verify_manifest"), patch.object(control, "source_hashes", return_value={"same": "hash"}), \
                    patch.object(control.bootstrap, "prepare_redis"), \
                    patch.object(control, "download", return_value=payload([])), \
                    patch.object(control.redis_cart, "restore_cart", side_effect=RuntimeError("fsync failed")), \
                    patch.object(control, "mark") as mark:
                with self.assertRaisesRegex(RuntimeError, "fsync"):
                    control.restore()
                mark.assert_not_called()
                self.assertTrue(common.load(progress)["redisStarted"])

    def test_backup_error_does_not_advance_latest(self):
        with tempfile.TemporaryDirectory() as directory:
            env = {"PETFLOW_DESTROY_RUN_ID": "test", "PETFLOW_DESTROY_EVIDENCE_DIR": directory,
                   "KUBECONFIG": "test-only", "PETFLOW_CNPG_BACKUP_MANIFEST": directory + "/cnpg.json"}
            with patch.dict(os.environ, env), patch.object(control, "identity"), patch.object(control, "qualification"), \
                    patch.object(control, "aws", return_value={"Status": "Enabled"}), \
                    patch.object(control.kafka, "inventory"), \
                    patch.object(control.maintenance, "quiesce", return_value={"quiescedAt": "now"}), \
                    patch.object(control.cnpg, "assert_no_clients"), patch.object(control.cnpg, "fingerprints", return_value={}), \
                    patch.object(control.redis_cart, "export_cart", return_value=payload([])), \
                    patch.object(control, "upload", return_value={}) as upload, \
                    patch("subprocess.check_call", side_effect=subprocess.CalledProcessError(1, "backup")):
                with self.assertRaises(subprocess.CalledProcessError):
                    control.backup()
                self.assertEqual([c[0][0] for c in upload.call_args_list], ["recovery/runs/test/cart.json"])


class KafkaShutdownTests(unittest.TestCase):
    def test_requires_all_kraft_shutdown_components(self):
        lines = [
            "Shutdown complete. (kafka.log.LogManager)",
            "[BrokerServer id=0] Transition from SHUTTING_DOWN to SHUTDOWN",
            "[kafka-0-raft-io-thread]: Shutdown completed",
            "[SocketServer listenerType=CONTROLLER, nodeId=0] Shutdown completed",
            "App info kafka.server for 0 unregistered",
        ]
        self.assertTrue(kafka.shutdown_confirmed("\n".join(lines), [0]))
        for omitted in range(len(lines)):
            self.assertFalse(kafka.shutdown_confirmed("\n".join(lines[:omitted] + lines[omitted+1:]), [0]))
        self.assertFalse(kafka.shutdown_confirmed("\n".join(lines), [1]))


if __name__ == "__main__":
    unittest.main()
