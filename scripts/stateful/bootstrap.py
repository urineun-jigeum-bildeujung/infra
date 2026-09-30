"""Render the existing GitOps sources without starting the root Application."""
import json
import copy
import os
from pathlib import Path
import tempfile

import yaml

from common import (GITOPS, apply, aws, clean, get, kube, load, poll, require,
                    run, save, sha, terraform_output)
import kafka


def application_source(relative):
    with open(str(GITOPS / relative)) as handle:
        return yaml.safe_load(handle)["spec"]["source"]


def desired_matches(desired, actual):
    """Allow API defaulted fields while requiring every GitOps setting to match."""
    if isinstance(desired, dict):
        return isinstance(actual, dict) and all(k in actual and desired_matches(v, actual[k]) for k, v in desired.items())
    if isinstance(desired, list):
        return isinstance(actual, list) and len(desired) == len(actual) and all(desired_matches(a, b) for a, b in zip(desired, actual))
    return desired == actual


def render_application(relative, namespace):
    source = application_source(relative)
    require("chart" in source, "expected Helm Application")
    apply({"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": namespace}})
    helm = source.get("helm", {})
    with tempfile.TemporaryDirectory() as directory:
        values = Path(directory) / "values.yaml"
        values.write_text(helm.get("values", "{}"))
        values.chmod(0o600)
        rendered = run(["helm", "template", helm.get("releaseName", source["chart"]), source["chart"],
                        "--repo", source["repoURL"], "--version", source["targetRevision"],
                        "--namespace", namespace, "--include-crds", "-f", str(values)])
    kube("apply", "-f", "-", input_data=rendered)


def prepare_redis():
    kube("apply", "-f", str(GITOPS / "platform/05-storageclass/manifests/gp3.yaml"))
    kube("apply", "-f", str(GITOPS / "platform/00-internal-ca/manifests/internal-ca.yaml"))
    kube("wait", "--for=condition=Ready", "certificate/internal-ca", "-n", "cert-manager", "--timeout=5m")
    kube("wait", "--for=condition=Ready", "clusterissuer/internal-ca-issuer", "--timeout=5m")
    apply({"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": "redis"}})
    kube("apply", "-f", str(GITOPS / "platform/39-redis-cert/manifests/redis-cert.yaml"))
    kube("wait", "--for=condition=Ready", "certificate/redis-server-mtls", "-n", "redis", "--timeout=5m")
    # Use the same source secret and ACL as External Secrets, without installing the root.
    payload = aws("secretsmanager", "get-secret-value", "--secret-id", "petflow/redis/credentials")
    credentials = json.loads(payload["SecretString"])
    source = GITOPS / "platform/91-external-secrets-config/manifests/redis-credentials.yaml"
    import hashlib
    with open(str(source)) as handle:
        template = next(yaml.safe_load_all(handle))["spec"]["target"]["template"]["data"]["users.conf"]
    template = template.replace("{{ .appPassword | sha256sum }}", hashlib.sha256(credentials["app-password"].encode()).hexdigest())
    template = template.replace("{{ .auditPassword | sha256sum }}", hashlib.sha256(credentials["audit-password"].encode()).hexdigest())
    require("{{" not in template, "unsupported Redis ACL template")
    apply({"apiVersion": "v1", "kind": "Secret", "metadata": {"name": "redis-auth", "namespace": "redis"},
           "type": "Opaque", "stringData": {"redis-password": credentials["default-password"], "users.conf": template}})
    render_application("platform/40-redis/application.yaml", "redis")
    kube("rollout", "status", "statefulset/redis-master", "-n", "redis", "--timeout=10m")


def restore_kafka(state, journal_path):
    namespace = kafka.NAMESPACE
    state = copy.deepcopy(state)
    for doc in state["secrets"] + state["pools"] + state["topics"] + state["users"] + [state["cluster"]]:
        doc["metadata"]["namespace"] = namespace
    require(state["kafkaVersion"] == "3.9.0" and state["strimziVersion"] == "0.45.2", "unsupported Kafka backup version")
    require(application_source("platform/40-kafka-operator/application.yaml")["targetRevision"] == "0.45.2",
            "GitOps Strimzi version differs from backup")
    with open(str(GITOPS / "platform/50-kafka-cluster/manifests/kafka.yaml")) as handle:
        current = list(yaml.safe_load_all(handle))
    current_cluster = next(d for d in current if d["kind"] == "Kafka")
    require(desired_matches(current_cluster["spec"], state["cluster"]["spec"]), "GitOps Kafka settings differ; restore using the qualified source revision")
    for pool in state["pools"]:
        desired = next((d for d in current if d["kind"] == "KafkaNodePool" and d["metadata"]["name"] == pool["metadata"]["name"]), None)
        require(desired and desired_matches(desired["spec"], pool["spec"]), "GitOps KafkaNodePool settings differ")
    journal = load(journal_path) if journal_path.exists() else {"runId": state["runId"], "volumes": {}}
    require(journal["runId"] == state["runId"], "Kafka restore journal belongs to another backup")
    existing = get("kafka", kafka.NAME, namespace)
    if existing:
        require(existing["metadata"].get("annotations", {}).get("petflow.io/recovery-run") == state["runId"],
                "Kafka already exists outside this recovery run")
        if journal.get("starting") and not kafka.ready():
            # Storage and identity were already installed. Resume startup, never replace disks.
            kube("annotate", "kafka", kafka.NAME, "-n", namespace, "strimzi.io/pause-reconciliation-", "--overwrite")
            kube("scale", "deployment", "strimzi-cluster-operator", "-n", namespace, "--replicas=1")
            poll(kafka.ready, bool, 1200)
        if kafka.ready():
            live = kafka.inventory()
            require(live["clusterId"] == state["clusterId"] and live["nodeIds"] == state["nodeIds"], "Kafka recovery identity mismatch")
            require(kafka.offsets(live["podName"]) == state["offsets"], "Kafka recovery offsets mismatch")
            journal.update(verified=True, clusterId=live["clusterId"], nodeIds=live["nodeIds"], offsetsVerified=True)
            save(journal_path, journal)
            return journal
    render_application("platform/40-kafka-operator/application.yaml", namespace)
    kube("scale", "deployment", "strimzi-cluster-operator", "-n", namespace, "--replicas=0")
    kube("wait", "--for=delete", "pods", "-l", "name=strimzi-cluster-operator", "-n", namespace, "--timeout=5m")
    for crd in ("kafkas.kafka.strimzi.io", "kafkanodepools.kafka.strimzi.io"):
        kube("wait", "--for=condition=Established", "crd/" + crd, "--timeout=5m")
    # No broker is allowed to start before identity and restored volumes are bound.
    require(not get("pods", namespace=namespace, selector="strimzi.io/name=" + kafka.NAME + "-kafka")["items"],
            "Kafka broker already exists; refusing disk replacement")
    for secret in state["secrets"]:
        apply(secret)
    role = terraform_output("cnpg_ebs_backup_role_arn")
    nodes = get("nodes")["items"]
    zones = sorted(set(n["metadata"]["labels"]["topology.kubernetes.io/zone"] for n in nodes
                       if any(c["type"] == "Ready" and c["status"] == "True" for c in n["status"]["conditions"])))
    require(zones, "no Ready worker availability zone")
    for source in state["volumes"]:
        name = source["pvc"]["metadata"]["name"]
        progress = journal["volumes"].get(name)
        if progress is None:
            metadata = aws("backup", "get-recovery-point-restore-metadata", "--backup-vault-name", source["vault"],
                           "--recovery-point-arn", source["recoveryPointArn"])["RestoreMetadata"]
            metadata.update(availabilityZone=zones[0], volumeType="gp3")
            result = aws("backup", "start-restore-job", "--recovery-point-arn", source["recoveryPointArn"],
                         "--iam-role-arn", role, "--resource-type", "EBS", "--metadata", json.dumps(metadata),
                         "--idempotency-token", sha((state["runId"] + "-restore-" + source["volumeId"]).encode())[:40])
            progress = {"jobId": result["RestoreJobId"], "zone": zones[0]}
            journal["volumes"][name] = progress
            save(journal_path, journal)
        def completed(result):
            require(result["Status"] not in ("FAILED", "ABORTED"), "Kafka EBS restore job failed")
            return result["Status"] == "COMPLETED"
        result = poll(lambda: aws("backup", "describe-restore-job", "--restore-job-id", progress["jobId"]), completed)
        volume_id = result["CreatedResourceArn"].split("/")[-1]
        volume = aws("ec2", "describe-volumes", "--volume-ids", volume_id)["Volumes"][0]
        require(volume["Size"] == source["sizeGiB"] and volume["Encrypted"] == source["encrypted"], "restored EBS attributes mismatch")
        if source.get("kmsKeyId"):
            require(volume.get("KmsKeyId") == source["kmsKeyId"], "restored EBS encryption key mismatch")
        pv_name = "restore-" + namespace + "-" + name
        existing_pvc = get("pvc", name, namespace)
        require(not existing_pvc or existing_pvc["spec"].get("volumeName") == pv_name,
                "Kafka PVC already uses another volume")
        existing_pv = get("pv", pv_name)
        require(not existing_pv or existing_pv["spec"]["csi"]["volumeHandle"] == volume_id, "Kafka PV identity mismatch")
        pv = {"apiVersion": "v1", "kind": "PersistentVolume", "metadata": {"name": pv_name}, "spec": {
            "capacity": {"storage": str(source["sizeGiB"]) + "Gi"}, "accessModes": ["ReadWriteOnce"],
            "persistentVolumeReclaimPolicy": "Delete", "storageClassName": "gp3", "volumeMode": "Filesystem",
            "claimRef": {"namespace": namespace, "name": name},
            "csi": {"driver": "ebs.csi.aws.com", "volumeHandle": volume_id, "fsType": source["pv"]["spec"]["csi"].get("fsType", "ext4")},
            "nodeAffinity": {"required": {"nodeSelectorTerms": [{"matchExpressions": [{
                "key": "topology.kubernetes.io/zone", "operator": "In", "values": [volume["AvailabilityZone"]]}]}]}}}}
        apply(pv)
        pvc = copy.deepcopy(source["pvc"])
        # Binding/provisioner annotations belong to the old PV and old cluster.
        pvc["metadata"]["namespace"] = namespace
        pvc["metadata"].pop("annotations", None)
        pvc["spec"] = {"accessModes": ["ReadWriteOnce"], "storageClassName": "gp3", "volumeName": pv_name,
                       "resources": {"requests": {"storage": str(source["sizeGiB"]) + "Gi"}}}
        apply(pvc)
    cluster = state["cluster"]
    cluster["metadata"].setdefault("annotations", {})["strimzi.io/pause-reconciliation"] = "true"
    cluster["metadata"]["annotations"]["petflow.io/recovery-run"] = state["runId"]
    for pool in state["pools"]:
        pool["metadata"].setdefault("annotations", {})["strimzi.io/next-node-ids"] = json.dumps(state["nodeIds"])
        apply(pool)
        kube("patch", "kafkanodepool", pool["metadata"]["name"], "-n", namespace, "--subresource=status",
             "--type=merge", "-p", json.dumps({"status": {"clusterId": state["clusterId"], "nodeIds": state["nodeIds"]}}))
    apply(cluster)
    kube("patch", "kafka", kafka.NAME, "-n", namespace, "--subresource=status", "--type=merge",
         "-p", json.dumps({"status": {"clusterId": state["clusterId"]}}))
    for document in state["topics"] + state["users"]:
        apply(document)
    journal["starting"] = True
    save(journal_path, journal)
    kube("annotate", "kafka", kafka.NAME, "-n", namespace, "strimzi.io/pause-reconciliation-", "--overwrite")
    kube("scale", "deployment", "strimzi-cluster-operator", "-n", namespace, "--replicas=1")
    poll(kafka.ready, bool, 1200)
    live = kafka.inventory()
    require(live["clusterId"] == state["clusterId"] and live["nodeIds"] == state["nodeIds"], "restored Kafka identity mismatch")
    require(kafka.offsets(live["podName"]) == state["offsets"], "restored Kafka offsets differ")
    journal.update(verified=True, clusterId=live["clusterId"], nodeIds=live["nodeIds"], offsetsVerified=True)
    save(journal_path, journal)
    return journal
