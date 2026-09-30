"""Persist reversible controls before stopping writers; fail closed on ambiguity."""
from common import apply, clean, get, kube, load, poll, require, save, utc

SERVICES = ("api-gateway", "auth-service", "member-service", "product-service",
            "order-service", "payment-service", "review-service", "notification-service",
            "recommendation", "nutrition", "web")
CONTROLLERS = (("argocd", "statefulset", "argocd-application-controller"),
               ("argocd", "deployment", "argocd-applicationset-controller"),
               ("argo-rollouts", "deployment", "argo-rollouts"),
               ("keda", "deployment", "keda-operator"),
               ("jenkins", "statefulset", "jenkins"))


def capture(path, run_id):
    require(not path.exists(), "maintenance journal already exists; use a new run ID")
    state = {"runId": run_id, "startedAt": utc(), "controllers": [],
             "workloads": [], "hpas": [], "scaledObjects": [], "cronJobs": [],
             "status": "captured"}
    for namespace, kind, name in CONTROLLERS:
        doc = get(kind, name, namespace)
        if doc:
            state["controllers"].append({"namespace": namespace, "kind": kind,
                                         "name": name, "replicas": doc["spec"].get("replicas", 1)})
    # Check all relevant resources before any mutations.
    for namespace in SERVICES:
        if not get("namespace", namespace):
            continue
        jobs = get("jobs", namespace=namespace)["items"]
        require(not any(j.get("status", {}).get("active", 0) for j in jobs),
                "active business Job in {}; wait for completion before backup".format(namespace))
        for kind in ("deployments", "statefulsets", "rollouts.argoproj.io"):
            for doc in get(kind, namespace=namespace)["items"]:
                state["workloads"].append({"namespace": namespace, "kind": kind,
                                            "name": doc["metadata"]["name"],
                                            "replicas": doc["spec"].get("replicas", 1)})
        for original in get("hpa", namespace=namespace)["items"]:
            doc = clean(original)
            if original["metadata"].get("ownerReferences"):
                doc["metadata"]["ownerReferences"] = original["metadata"]["ownerReferences"]
            state["hpas"].append(doc)
        state["scaledObjects"] += [clean(d) for d in get("scaledobjects.keda.sh", namespace=namespace)["items"]]
        state["cronJobs"] += [clean(d) for d in get("cronjobs", namespace=namespace)["items"]]
    save(path, state)
    return state


def scale(item, replicas):
    kube("scale", item["kind"], item["name"], "-n", item["namespace"],
         "--replicas=" + str(replicas))


def assert_no_business_pods():
    for namespace in SERVICES:
        if get("namespace", namespace):
            pods = get("pods", namespace=namespace)["items"]
            require(not any(p.get("status", {}).get("phase") not in ("Succeeded", "Failed")
                            for p in pods), "business Pod still exists: " + namespace)


def quiesce(path, run_id):
    state = capture(path, run_id)
    state["status"] = "quiescing"
    save(path, state)
    # Stop reconcilers first. Every original setting is already durable on disk.
    for item in state["controllers"]:
        # Rollout replica changes require its controller to reconcile ReplicaSets.
        # Stop it only after the business Pods have drained.
        if item["namespace"] == "argo-rollouts":
            continue
        scale(item, 0)
        poll(lambda: get(item["kind"], item["name"], item["namespace"]),
             lambda d: d.get("status", {}).get("replicas", 0) == 0, 300)
    for doc in state["scaledObjects"]:
        kube("annotate", "scaledobject", doc["metadata"]["name"], "-n", doc["metadata"]["namespace"],
             "autoscaling.keda.sh/paused-replicas=0", "--overwrite")
    for doc in state["hpas"]:
        kube("delete", "hpa", doc["metadata"]["name"], "-n", doc["metadata"]["namespace"], "--wait=true")
    for doc in state["cronJobs"]:
        kube("patch", "cronjob", doc["metadata"]["name"], "-n", doc["metadata"]["namespace"],
             "--type=merge", "-p", '{"spec":{"suspend":true}}')
    # Gateway goes first; remaining processes receive Kubernetes graceful termination.
    for item in sorted(state["workloads"], key=lambda w: w["namespace"] != "api-gateway"):
        scale(item, 0)
    poll(lambda: get("pods"), lambda d: not any(
        p["metadata"].get("namespace") in SERVICES and
        p.get("status", {}).get("phase") not in ("Succeeded", "Failed") for p in d["items"]), 900)
    assert_no_business_pods()
    for item in state["controllers"]:
        if item["namespace"] == "argo-rollouts":
            scale(item, 0)
            poll(lambda: get(item["kind"], item["name"], item["namespace"]),
                 lambda d: d.get("status", {}).get("replicas", 0) == 0, 300)
    state.update(status="quiesced", quiescedAt=utc())
    save(path, state)
    return state


def resume(path):
    state = load(path)
    require(state["status"] not in ("deleting", "deleted"), "cannot resume after storage cleanup started")
    # Resume requires Kafka to be Ready; rollback must not restart writers into stopped Kafka.
    kafka = get("kafka", "pet-subscription-kafka", "kafka")
    require(kafka and any(c.get("type") == "Ready" and c.get("status") == "True"
                         for c in kafka.get("status", {}).get("conditions", [])),
            "Kafka is not Ready; run resume-kafka before resume-maintenance")
    for item in state["workloads"]:
        scale(item, item["replicas"])
    # Restore KEDA ownership before its admission webhook sees an unpause request.
    for hpa in state["hpas"]:
        for scaled in state["scaledObjects"]:
            name = scaled.get("spec", {}).get("advanced", {}).get("horizontalPodAutoscalerConfig", {}).get("name", "keda-hpa-" + scaled["metadata"]["name"])
            if hpa["metadata"]["name"] == name and hpa["metadata"]["namespace"] == scaled["metadata"]["namespace"]:
                live = get("scaledobject", scaled["metadata"]["name"], scaled["metadata"]["namespace"])
                require(live, "original KEDA ScaledObject is missing")
                hpa["metadata"]["ownerReferences"] = [{"apiVersion":live["apiVersion"],"kind":live["kind"],
                    "name":live["metadata"]["name"],"uid":live["metadata"]["uid"],"controller":True,"blockOwnerDeletion":True}]
    for doc in state["hpas"] + state["cronJobs"] + state["scaledObjects"]:
        apply(doc)
    # Client-side apply cannot remove an annotation it never originally owned.
    for doc in state["scaledObjects"]:
        original = doc["metadata"].get("annotations", {}).get("autoscaling.keda.sh/paused-replicas")
        import json
        kube("patch", "scaledobject", doc["metadata"]["name"], "-n", doc["metadata"]["namespace"],
             "--type=merge", "-p", json.dumps({"metadata":{"annotations":{"autoscaling.keda.sh/paused-replicas":original}}}))
    for item in reversed(state["controllers"]):
        scale(item, item["replicas"])
    state.update(status="resumed", resumedAt=utc())
    save(path, state)
    print("Services resumed. Discard this backup attempt; next backup must use a new run ID.")
