# HPA, KEDA, and Karpenter validation — 2026-09-30

## Result

The bounded DEV validation completed without application errors, database
pressure, restarts, or changes to business Kafka data. KEDA completed a full
1 → 3 → 1 consumer cycle. Karpenter provisioned one additional on-demand node,
which remained because Jenkins workloads adopted it after test cleanup. The
product HPA did not scale because observed CPU remained below its 60% target.

No Terraform apply/destroy, business transaction, Spot node, recurring job,
production threshold change, or forced node deletion was performed.

## Environment and baseline

- Window: 2026-09-30 14:25–15:14 KST (05:25–06:14 UTC)
- Kubernetes context: `petflow-dev`
- AWS account/region: `297165773875`, `ap-northeast-2`
- Baseline observation: 5 minutes
- Service pods: 30/30 Ready, zero restarts and zero Pending
- Product HPA: 2/3 replicas, CPU target 60%, initial CPU 2–5%
- Database: 5/100 connections, no connection errors
- Product p95: about 12.5 ms; 5xx: 0
- Karpenter: one Ready `m7i-flex.large` NodeClaim before the test
- Business Kafka group `payment-service.refund-consumer`: topic
  `order.item-cancelled`, log-end 0 before and after the test

## Public read-only HTTP test

Traffic originated outside the cluster and used only these public GET routes:

- 30% `GET /api/v1/time-deals?status=ACTIVE`
- 70% `GET /api/v1/time-deals/items/{7..12}`

The runner capped concurrency at 20, used a 5-second timeout, performed no
retries, and stopped on three errors, repeated auth/not-found responses,
dropped iterations, or p95 ≥ 1 second. Total active duration was 11 minutes.

| Rate | Duration | Requests | Failures | p95 | Max |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 RPS | 2m | 120 | 0 | 35.69 ms | 114.16 ms |
| 5 RPS | 3m | 900 | 0 | 28.76 ms | 84.34 ms |
| 10 RPS | 3m | 1,800 | 0 | 27.90 ms | 83.07 ms |
| 20 RPS | 3m | 3,600 | 0 | 34.01 ms | 258.64 ms |

All 6,420 requests returned HTTP 200. There were no timeouts, dropped
iterations, 401/403/404/429 responses, or 5xx responses. Product CPU peaked at
an observed 52%, replicas stayed at 2, database connections stayed at 5, and
pod restarts stayed at zero. This proves bounded-load stability but does not
prove product HPA scale-out because the 60% CPU trigger was not reached.

The four k6 summary JSON files in
`docs/evidence/autoscaling-validation-20260930/` are the raw evidence.

## Dedicated Kafka/KEDA test

Isolated resources used:

- Namespace: `autoscaling-validation`
- Topic: `autoscaling-validation-20260930`, 3 partitions, RF 1
- Group: `autoscaling-validation-consumer-20260930`
- SCRAM user: `autoscaling-validation-20260930`
- ScaledObject: Kafka-only, min 1, max 3, lag threshold 10
- Producer: exactly 300 records, 512 bytes each, 10 records/sec
- Consumer: about 1 committed record/sec per pod

Observed sequence:

1. Consumer connected at one replica with lag 0.
2. Producer completed 300 records at 10.017 records/sec.
3. Total lag rose to roughly 278; ScaledObject became Active.
4. KEDA/HPA increased the deployment from 1 to 2 to 3 replicas.
5. Lag fell through 137 to 0 with zero consumer restarts.
6. ScaledObject became inactive and replicas returned 3 → 2 → 1.

The first producer attempt made zero records because its generated client
configuration omitted `bootstrap.servers`. The Job failed closed, was deleted,
the manifest was corrected, and only the successful 300-record run contributed
data. An earlier pod-affinity attempt also stayed Pending because the broker
node had reached its pod limit; it was removed without producing data.

Kafka broker authorization is disabled in DEV (`authorization` is absent and
the user operator reports ACL admin support false). The test therefore used a
dedicated authenticated SCRAM identity, but broker-enforced least-privilege
ACLs could not be applied without changing shared Kafka configuration. The
temporary additive NetworkPolicy allowed only the test namespace to reach the
TLS listener and did not roll the broker.

## Karpenter and NAT observations

- Initial NodeClaims: 1
- Maximum/final NodeClaims during the test: 2
- New claim: `on-demand-smzqj`, on-demand `m7i-flex.large`
- Created: 06:00:39 UTC; Ready: 06:01:06 UTC
- Test-created node limit: respected (one additional node)
- No Spot capacity and no forced node deletion

After test resources were removed, two Jenkins jobs were running on the new
node. Karpenter correctly retained it; scale-in was therefore not expected and
was not forced. This validates provisioning, while consolidation after complete
workload departure remains unobserved in this run.

The Strimzi image was not cached on the new node. Kubernetes recorded two
concurrent pulls of a 375,539,008-byte image for consumer and producer. The
upper-bound external image transfer attributable to this test is therefore
about 751 MB (actual registry-layer deduplication may reduce it). Public HTTP
test traffic received about 11.69 MB and sent about 0.43 MB. These quantities
are orders of magnitude below 2 TB, but the image pulls are relevant when
reviewing NAT Gateway bytes.

## Cleanup and rerun

Cleanup removed the test namespace, topic, KafkaUser, credential copy,
ScaledObject/HPA, producer/consumer, and temporary Kafka NetworkPolicy. All
service Deployments/StatefulSets were Ready afterward, database connections
were 5/100, and business Kafka offsets/log-end remained unchanged.

The final Argo CD check showed `platform-root` Healthy but OutOfSync only on
the child `alloy` Application object. Its automated sync reported success and
`alloy` itself was Synced/Healthy; no test resource remained. This recurrent
Application-object drift is a separate GitOps follow-up and was not auto-fixed
as part of this validation.

Run the HTTP stages from the repository root:

```bash
scripts/autoscaling-validation/run-http.sh
```

Run the dedicated Kafka/KEDA test and watch the printed commands:

```bash
