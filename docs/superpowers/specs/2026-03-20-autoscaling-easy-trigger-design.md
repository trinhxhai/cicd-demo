# Design: Easy-Trigger Autoscaling for Phase 3

**Date:** 2026-03-20
**Status:** Approved
**Updates:** `docs/superpowers/plans/2026-03-17-phase3-autoscaling.md`

## Goal

Replace the k6 load test in Phase 3 with simple `kubectl` one-liners that trigger HPA pod scaling and Cluster Autoscaler node scaling on demand. No external tools, no real traffic, no NLB address needed. Purpose is to observe the mechanics end-to-end.

## Approach: Low-threshold HPA + kubectl stress pods

Two changes to the existing plan:

1. **Lower HPA threshold to 5%** (from 70%) so any cluster-internal traffic triggers scale-up
2. **Replace k6 with two `kubectl run` commands** — one for HPA, one for CA

---

## Section 1: HPA Manifest Change (Task 2)

Set `averageUtilization: 5` with a comment marking it as test mode. All other HPA settings unchanged (min 1, max 4, stabilization windows).

```yaml
# averageUtilization: 5  ← TEST MODE (change to 70 for production)
averageUtilization: 5
```

---

## Section 2: HPA Trigger (replaces Task 5 k6 load test)

**Scale-up** — busybox pod inside the cluster hammers `/ping` in a tight loop:
```bash
kubectl run load-gen \
  --image=busybox --restart=Never \
  -- sh -c "while true; do wget -q -O- http://api-express.default.svc.cluster.local:3001/ping; sleep 0.01; done"
```

With 5% threshold and 100m CPU request, HPA fires within ~30s. Pods scale 1 → 4.

**Scale-down** — delete the pod, HPA scales back to 1 after 120s stabilization:
```bash
kubectl delete pod load-gen
```

**Live watch** (separate terminal — install with `brew install watch` if missing):
```bash
watch -n 3 "kubectl get hpa api-express-hpa && echo && kubectl get pods -l app=api-express && echo && kubectl get nodes"
```

Or without `watch`:
```bash
while true; do clear; kubectl get hpa api-express-hpa && echo && kubectl get pods -l app=api-express && echo && kubectl get nodes; sleep 3; done
```

---

## Section 3: Cluster Autoscaler Trigger (replaces k6 CA observation)

Deploy 2 resource-hog pods each requesting 1800m CPU. On t3.medium (2 vCPU), only 1 fits per node. With 2 nodes partially in use, the second pod goes Pending → CA adds a node (~2-3 min).

**Scale-up:**
```bash
kubectl run resource-hog-1 --image=busybox --restart=Never --requests='cpu=1800m' -- sleep 600
kubectl run resource-hog-2 --image=busybox --restart=Never --requests='cpu=1800m' -- sleep 600
```

The 1800m CPU *request* (not usage) causes the scheduler to fail placement when a node has < 200m free — making the pod Pending. CA sees Pending pods and adds a node (~2-3 min).

**Scale-down** (CA removes idle node after ~10 min cooldown):
```bash
kubectl delete pod resource-hog-1 resource-hog-2
```

---

## What Changes in the Plan

| Section | Before | After |
|---------|--------|-------|
| File Map comment | `max 10` | `max 4` (fix stale comment) |
| Task 2 Step 1 (HPA manifest) | `averageUtilization: 70` | `averageUtilization: 5` + test-mode comment |
| Task 5 (entire section) | k6 load test, NLB address, 7-min stages | `kubectl run` one-liners, watch loop, CA trigger |

Everything else (Metrics Server, PDB, CA deployment, kustomization) stays identical.

**Commit replacing Task 5 Steps 9-10:**
```bash
git add load-tests/ k8s/base/api-express/hpa.yaml
git commit -m "chore: phase 3 complete — autoscaling verified with kubectl stress pods"
```
