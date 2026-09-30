"""Cold EBS backup of the pinned, single-node Strimzi KRaft topology."""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time

from common import (ACCOUNT, REGION, apply, aws, clean, get, kube, load, poll,
                    require, save, sha, terraform_output, upload, utc)

NAMESPACE = "kafka"
NAME = "pet-subscription-kafka"
SELECTOR = "strimzi.io/cluster=" + NAME


def ready():
    doc = get("kafka", NAME, NAMESPACE)
    return doc and any(c.get("type") == "Ready" and c.get("status") == "True"
                       for c in doc.get("status", {}).get("conditions", []))


def inventory():
    cluster = get("kafka", NAME, NAMESPACE)
    pools = get("kafkanodepools", namespace=NAMESPACE, selector=SELECTOR)["items"]
    require(cluster and cluster["spec"]["kafka"]["version"] == "3.9.0", "Kafka version is not qualified")
    require(len(pools) == 1 and pools[0]["spec"]["replicas"] == 1 and
            sorted(pools[0]["spec"]["roles"]) == ["broker", "controller"],
            "only the single dual-role node topology is supported")
    pods = get("pods", namespace=NAMESPACE, selector="strimzi.io/name=" + NAME + "-kafka")["items"]
    require(len(pods) == 1, "expected exactly one Kafka broker Pod")
    pod = pods[0]
    node_ids = pools[0].get("status", {}).get("nodeIds", [])
    require(len(node_ids) == 1, "Kafka node ID missing")
    cluster_id = cluster.get("status", {}).get("clusterId")
    require(bool(cluster_id), "Kafka cluster ID missing")
    meta = kube("exec", "-n", NAMESPACE, pod["metadata"]["name"], "-c", "kafka", "--",
                "cat", "/var/lib/kafka/data-0/kafka-log{}/meta.properties".format(node_ids[0]))
    require("cluster.id=" + cluster_id in meta and "node.id=" + str(node_ids[0]) in meta,
            "Kafka disk identity mismatch")
    volumes = []
    for volume in pod["spec"]["volumes"]:
        if "persistentVolumeClaim" not in volume:
            continue
        pvc = get("pvc", volume["persistentVolumeClaim"]["claimName"], NAMESPACE)
        pv = get("pv", pvc["spec"]["volumeName"])
        require(pv["spec"].get("csi", {}).get("driver") == "ebs.csi.aws.com", "Kafka volume is not EBS")
        volume_id = pv["spec"]["csi"]["volumeHandle"]
        require(re.match(r"^vol-[0-9a-f]+$", volume_id), "unexpected EBS volume ID")
        detail = aws("ec2", "describe-volumes", "--volume-ids", volume_id)["Volumes"][0]
        volumes.append({"pvc": clean(pvc), "volumeId": volume_id,
                        "availabilityZone": detail["AvailabilityZone"], "sizeGiB": detail["Size"],
                        "encrypted": detail["Encrypted"], "kmsKeyId": detail.get("KmsKeyId"),
                        "pv": clean(pv)})
    require(len(volumes) == 1, "expected one shared KRaft/data volume")
    operator = get("deployment", "strimzi-cluster-operator", NAMESPACE)
    require(operator, "Strimzi operator not found")
    require(any("0.45.2" in c["image"] for c in operator["spec"]["template"]["spec"]["containers"]),
            "Strimzi version is not qualified")
    # Store only Kafka-owned credentials, never arbitrary namespace Secrets.
    secrets = get("secrets", namespace=NAMESPACE)["items"]
    secrets = [clean(s) for s in secrets if s["metadata"].get("labels", {}).get("strimzi.io/cluster") == NAME
               and s.get("type") != "kubernetes.io/service-account-token"]
    require(any(s["metadata"]["name"] == NAME + "-cluster-ca" for s in secrets), "Kafka cluster CA key missing")
    return {"cluster": clean(cluster), "pools": [clean(p) for p in pools],
            "clusterId": cluster_id, "nodeIds": node_ids, "podName": pod["metadata"]["name"],
            "operatorReplicas": operator["spec"].get("replicas", 1), "volumes": volumes,
            "secrets": secrets, "topics": [clean(t) for t in get("kafkatopics", namespace=NAMESPACE)["items"]],
            "users": [clean(u) for u in get("kafkausers", namespace=NAMESPACE)["items"]]}


def offsets(pod):
    base = ["exec", "-n", NAMESPACE, pod, "-c", "kafka", "--"]
    bootstrap = "localhost:9092"
    end = kube(*(base + ["/opt/kafka/bin/kafka-get-offsets.sh", "--bootstrap-server", bootstrap, "--time", "-1"]))
    groups = kube(*(base + ["/opt/kafka/bin/kafka-consumer-groups.sh", "--bootstrap-server", bootstrap,
                           "--all-groups", "--describe"]))
    # Ignore volatile member/host columns; pin only partition and committed offset.
    committed = []
    for line in groups.splitlines():
        fields = line.split()
        if len(fields) >= 6 and fields[2].isdigit() and (fields[3].isdigit() or fields[3] == "-"):
            committed.append(fields[:4])
    end_offsets = sorted(l.strip() for l in end.splitlines() if re.match(r"^.+:\d+:\d+$", l.strip()))
    require(end_offsets, "Kafka partition offsets could not be read")
    return {"endOffsets": end_offsets, "committedOffsets": sorted(committed)}


def shutdown_confirmed(log, node_ids):
    # Kafka 3.9 KRaft does not emit the legacy "Kafka Server stopped" message.
    # Require completion of log storage, broker shutdown and the controller's
    # Raft driver, followed by the final server unregister for every node.
    if "Shutdown complete. (kafka.log.LogManager)" not in log:
        return False
    for node in node_ids:
        required = [
            "[BrokerServer id={}] Transition from SHUTTING_DOWN to SHUTDOWN".format(node),
            "[kafka-{}-raft-io-thread]: Shutdown completed".format(node),
            "[SocketServer listenerType=CONTROLLER, nodeId={}] Shutdown completed".format(node),
            "App info kafka.server for {} unregistered".format(node),
        ]
        if not all(message in log for message in required):
            return False
    return True


def stop(state):
    kube("annotate", "kafka", NAME, "-n", NAMESPACE, "strimzi.io/pause-reconciliation=true", "--overwrite")
    kube("scale", "deployment", "strimzi-cluster-operator", "-n", NAMESPACE, "--replicas=0")
    kube("wait", "--for=delete", "pod", "-l", "name=strimzi-cluster-operator", "-n", NAMESPACE, "--timeout=5m")
    # Capture shutdown confirmation while Kubernetes sends TERM. Never force-delete.
    prefix = ["kubectl", "--context", "petflow-dev"]
    if os.environ.get("KUBECONFIG"):
        prefix = ["kubectl", "--kubeconfig", os.environ["KUBECONFIG"]]
    with tempfile.TemporaryFile(mode="w+") as output:
        logger = subprocess.Popen(prefix + ["logs", "-f", "--tail=100", "-n", NAMESPACE,
                                             state["podName"], "-c", "kafka"],
                                  stdout=output, stderr=subprocess.DEVNULL)
        try:
            deadline = time.monotonic() + 60
            while True:
                output.seek(0)
                if output.read():
                    break
                require(logger.poll() is None and time.monotonic() < deadline,
                        "Kafka log stream was not attached; refusing to terminate broker")
                time.sleep(0.2)
            kube("delete", "pod", state["podName"], "-n", NAMESPACE, "--wait=true", "--timeout=10m")
            logger.wait(timeout=30)
            output.seek(0)
            shutdown = output.read()
            evidence = os.environ.get("PETFLOW_KAFKA_SHUTDOWN_LOG")
            if evidence:
                path = Path(evidence)
                path.write_text(shutdown)
                path.chmod(0o600)
            require(shutdown_confirmed(shutdown, state["nodeIds"]),
                    "Kafka graceful KRaft shutdown was not confirmed")
        finally:
            if logger.poll() is None:
                logger.terminate()
                logger.wait(timeout=10)
    for volume in state["volumes"]:
        poll(lambda: aws("ec2", "describe-volumes", "--volume-ids", volume["volumeId"])["Volumes"][0],
             lambda v: v["State"] == "available" and not v.get("Attachments"), 600)


def backup(run_id, journal_path):
    state = inventory()
    state["offsets"] = offsets(state["podName"])
    save(journal_path, state)  # credentials: local owner-only file, recoverable on failure
    stop(state)
    state["stoppedAt"] = utc()
    vault = terraform_output("cnpg_ebs_backup_vault_name")
    role = terraform_output("cnpg_ebs_backup_role_arn")
    retention_days = aws("backup", "describe-backup-vault", "--backup-vault-name", vault).get("MinRetentionDays", 7)
    require(retention_days >= 7, "backup vault retention is below seven days")
    for volume in state["volumes"]:
        job = aws("backup", "start-backup-job", "--backup-vault-name", vault,
                  "--resource-arn", "arn:aws:ec2:{}:{}:volume/{}".format(REGION, ACCOUNT, volume["volumeId"]),
                  "--iam-role-arn", role, "--idempotency-token", sha((run_id + "-" + volume["volumeId"]).encode())[:40],
                  "--lifecycle", json.dumps({"DeleteAfterDays": retention_days}), "--recovery-point-tags",
                  json.dumps({"Purpose": "pre-kafka-maintenance", "DestroyRunId": run_id}))
        def job_ready(result):
            require(result["State"] not in ("FAILED", "ABORTED", "EXPIRED", "PARTIAL"), "Kafka AWS Backup job failed")
            return result["State"] == "COMPLETED"
        result = poll(lambda: aws("backup", "describe-backup-job", "--backup-job-id", job["BackupJobId"]), job_ready)
        volume.update(backupJobId=job["BackupJobId"], recoveryPointArn=result["RecoveryPointArn"], vault=vault)
    state.update(schemaVersion=1, runId=run_id, kafkaVersion="3.9.0", strimziVersion="0.45.2")
    return state


def resume(path):
    state = load(path)
    # PodSet controller restarts the original Pod when the operator resumes.
    kube("annotate", "kafka", NAME, "-n", NAMESPACE, "strimzi.io/pause-reconciliation-", "--overwrite")
    kube("scale", "deployment", "strimzi-cluster-operator", "-n", NAMESPACE,
         "--replicas=" + str(state["operatorReplicas"]))
    poll(lambda: get("deployment", "strimzi-cluster-operator", NAMESPACE),
         lambda d: d.get("status", {}).get("readyReplicas",0) >= state["operatorReplicas"], 300)
    # A restarted Operator can wait for the absent broker before reconciling its
    # existing PodSet. Recreate only the already desired Pod, using its original PVC.
    if not get("pod", state["podName"], NAMESPACE):
        current = get("kafka", NAME, NAMESPACE)
        require(current.get("status",{}).get("clusterId") == state["clusterId"], "Kafka resume identity changed")
        sets = get("strimzipodsets", namespace=NAMESPACE, selector=SELECTOR)["items"]
        podsets = [s for s in sets if any(p["metadata"]["name"]==state["podName"] for p in s["spec"]["pods"])]
        require(len(podsets)==1, "original broker PodSet not found")
        podset = podsets[0]
        pod = next(p for p in podset["spec"]["pods"] if p["metadata"]["name"]==state["podName"])
        claims = sorted(v["persistentVolumeClaim"]["claimName"] for v in pod["spec"]["volumes"] if "persistentVolumeClaim" in v)
        require(claims==sorted(v["pvc"]["metadata"]["name"] for v in state["volumes"]), "Kafka resume PVC identity changed")
        pod["metadata"]["ownerReferences"] = [{"apiVersion":podset["apiVersion"],"kind":podset["kind"],
            "name":podset["metadata"]["name"],"uid":podset["metadata"]["uid"],"controller":True,"blockOwnerDeletion":True}]
        try:
            kube("create", "-f", "-", input_data=json.dumps(pod))
        except RuntimeError:
            require(get("pod",state["podName"],NAMESPACE), "Kafka broker could not be recreated")
    poll(ready, bool, 900)


def verify_recovery_points(state):
    for volume in state["volumes"]:
        detail = aws("backup", "describe-recovery-point", "--backup-vault-name", volume["vault"],
                     "--recovery-point-arn", volume["recoveryPointArn"])
        require(detail["Status"] == "COMPLETED", "Kafka recovery point unavailable")
        require(detail["ResourceArn"].endswith("/" + volume["volumeId"]), "Kafka backup source mismatch")
        tags = aws("backup", "list-tags", "--resource-arn", volume["recoveryPointArn"])["Tags"]
        require(tags.get("DestroyRunId") == state["runId"] and tags.get("Purpose") == "pre-kafka-maintenance",
                "Kafka recovery point belongs to a different run")
        deletion = detail.get("CalculatedLifecycle", {}).get("DeleteAt")
        from common import epoch
        require(deletion is not None and epoch(deletion) - time.time() >= 86400,
                "Kafka recovery point has less than 24 hours retention")
