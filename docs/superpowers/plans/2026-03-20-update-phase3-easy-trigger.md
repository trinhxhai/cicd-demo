# Phase 3 Easy-Trigger Update Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Update `docs/superpowers/plans/2026-03-17-phase3-autoscaling.md` to replace the k6 load test with simple `kubectl` one-liners that trigger HPA and Cluster Autoscaler scaling on demand.

**Architecture:** Three targeted edits to the existing plan — fix a stale File Map comment, lower the HPA threshold to 5% (test mode), and replace Task 5 (k6 load test) with a kubectl-based trigger section.

**Spec:** `docs/superpowers/specs/2026-03-20-autoscaling-easy-trigger-design.md`

**Tech Stack:** kubectl, busybox image, Kubernetes HPA, Cluster Autoscaler

---

## File Map

```
docs/superpowers/plans/
  2026-03-17-phase3-autoscaling.md    ← Modify: 3 targeted edits
```

---

## Task 1: Fix File Map comment (stale max replica count)

**Files:**

- Modify: `docs/superpowers/plans/2026-03-17-phase3-autoscaling.md`

- [ ] **Step 1: Fix the File Map comment on line 22**

Find this line in the File Map section:

```
    hpa.yaml                     ← HPA for api-express (min 1, max 10, cpu 70%)
```

Replace with:

```
    hpa.yaml                     ← HPA for api-express (min 1, max 4, cpu 5% test-mode)
```

- [ ] **Step 2: Remove the load-tests entry from the File Map**

Find and delete this block from the File Map section:

```
load-tests/
  ping-load.js                     ← k6 script: ramp up traffic to api-express
```

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/plans/2026-03-17-phase3-autoscaling.md
git commit -m "docs: fix stale File Map in phase 3 plan (remove k6/load-tests, fix max replica)"
```

---

## Task 2: Lower HPA threshold to test-mode 5%

**Files:**

- Modify: `docs/superpowers/plans/2026-03-17-phase3-autoscaling.md` (Task 2, Step 1)

- [ ] **Step 1: Update the HPA manifest in Task 2 Step 1**

Find this block in the HPA manifest:

```yaml
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
  behavior:
```

Replace with:

```yaml
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 5    # TEST MODE — change to 70 for production
  behavior:
```

- [ ] **Step 2: Update the verify step expected output in Task 2 Step 3**

Find:

```
NAME               REFERENCE              TARGETS   MINPODS   MAXPODS   REPLICAS
api-express-hpa    Deployment/api-express  5%/70%    1         4         1
```

Replace with:

```
NAME               REFERENCE              TARGETS   MINPODS   MAXPODS   REPLICAS
api-express-hpa    Deployment/api-express  0%/5%     1         4         1
```

- [ ] **Step 3: Update the commit message in Task 2 Step 4**

Find:

```bash
git commit -m "feat: add HPA for api-express (min 1, max 4, target CPU 70%)"
```

Replace with:

```bash
git commit -m "feat: add HPA for api-express (min 1, max 4, target CPU 5% test-mode)"
```

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/plans/2026-03-17-phase3-autoscaling.md
git commit -m "docs: update HPA threshold to 5% test-mode in phase 3 plan"
```

---

## Task 3: Replace Task 5 (k6) with kubectl easy-trigger section

**Files:**

- Modify: `docs/superpowers/plans/2026-03-17-phase3-autoscaling.md` (Task 5, entire section)

- [ ] **Step 1: Delete the entire Task 5 section**

Remove everything from the `## Task 5: k6 Load Test + Observe Autoscaling` heading down to (but not including) `## Phase 3 Done ✓`.

- [ ] **Step 2: Insert the new Task 5 section in its place**

Insert the following content between the `---` after Task 4 and the `## Phase 3 Done ✓` heading:

````markdown
## Task 5: Trigger and Observe Autoscaling

No external tools needed. All commands run against the cluster directly.

### Part A: HPA scale-up and scale-down

- [ ] **Step 1: Open a watch window in a separate terminal**

```bash
# Install watch if missing (macOS): brew install watch
watch -n 3 "kubectl get hpa api-express-hpa && echo && kubectl get pods -l app=api-express && echo && kubectl get nodes"
```

Or without `watch`:
```bash
while true; do clear; kubectl get hpa api-express-hpa && echo && kubectl get pods -l app=api-express && echo && kubectl get nodes; sleep 3; done
```

This updates every 3 seconds and shows HPA targets, pod count, and node count live.

- [ ] **Step 2: Trigger HPA scale-up**

In your main terminal, run a busybox pod inside the cluster that hammers `/ping` in a tight loop:

```bash
kubectl run load-gen \
  --image=busybox --restart=Never \
  -- sh -c "while true; do wget -q -O- http://api-express.default.svc.cluster.local:3001/ping; sleep 0.01; done"
```

- [ ] **Step 3: Observe HPA scale-up**

Watch the watch window. Within ~30 seconds:
- `TARGETS` column on HPA climbs above 5%
- `REPLICAS` increases from 1 → 2 → up to 4

Expected HPA output during load:
```
NAME               REFERENCE              TARGETS    MINPODS   MAXPODS   REPLICAS
api-express-hpa    Deployment/api-express  45%/5%    1         4         4
```

- [ ] **Step 4: Trigger HPA scale-down**

```bash
kubectl delete pod load-gen
```

CPU drops to 0%. After the 120s stabilization window, HPA scales back to 1 pod.

- [ ] **Step 5: Verify scale-down**

```bash
kubectl get hpa api-express-hpa
# REPLICAS should return to 1
```

---

### Part B: Cluster Autoscaler scale-up and scale-down

- [ ] **Step 6: Deploy resource-hog pods to force Pending**

Each pod requests 1800m CPU. A t3.medium has ~1930m allocatable — with existing system pods using ~400-600m per node, a second hog pod cannot be scheduled and goes Pending. CA sees it and adds a node.

```bash
kubectl run resource-hog-1 --image=busybox --restart=Never --requests='cpu=1800m' -- sleep 600
kubectl run resource-hog-2 --image=busybox --restart=Never --requests='cpu=1800m' -- sleep 600
```

- [ ] **Step 7: Observe CA adding a node**

```bash
kubectl get pods -o wide | grep resource-hog
# One pod: Running. One pod: Pending
```

```bash
kubectl get nodes
# After ~2-3 minutes, a new node appears (STATUS: Ready)
```

- [ ] **Step 8: Trigger CA scale-down**

```bash
kubectl delete pod resource-hog-1 resource-hog-2
```

The new node becomes idle. CA removes it after its default ~10 minute cooldown.

```bash
kubectl get nodes
# After ~10 minutes, node count returns to original
```

- [ ] **Step 9: Commit**

```bash
git commit --allow-empty -m "chore: phase 3 complete — HPA and Cluster Autoscaler verified with kubectl stress pods"
```
````

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/plans/2026-03-17-phase3-autoscaling.md
git commit -m "docs: replace k6 load test with kubectl easy-trigger in phase 3 plan"
```

---

## Task 4: Remove remaining k6 references from header and success criteria

**Files:**

- Modify: `docs/superpowers/plans/2026-03-17-phase3-autoscaling.md`

- [ ] **Step 1: Update Tech Stack line in the plan header**

Find:

```
**Tech Stack:** Kubernetes Metrics Server, HPA, Cluster Autoscaler, PodDisruptionBudget, k6
```

Replace with:

```
**Tech Stack:** Kubernetes Metrics Server, HPA, Cluster Autoscaler, PodDisruptionBudget, kubectl/busybox
```

- [ ] **Step 2: Update Phase 3 Done success criteria**

Find the `## Phase 3 Done ✓` section and replace the success criteria block:

```
**Success criterion met when:**
- k6 load test → HPA scales `api-express` from 1 pod up to 4 pods
- HPA scales back down to 1 pod after load ends
- Cluster Autoscaler adds EC2 nodes IF pods become Pending (unlikely with max=4 on t3.medium, but CA is deployed and watching)
```

Replace with:

```
**Success criterion met when:**
- `kubectl run load-gen` → HPA scales `api-express` from 1 pod up to 4 pods within ~30 seconds
- HPA scales back down to 1 pod after `load-gen` pod is deleted (120s stabilization window)
- `resource-hog` pods → one goes Pending → Cluster Autoscaler adds an EC2 node within ~3 minutes
- Node removed after `resource-hog` pods deleted (~10 min CA cooldown)
```

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/plans/2026-03-17-phase3-autoscaling.md
git commit -m "docs: remove remaining k6 references from phase 3 plan header and success criteria"
```

---

## Done ✓

`2026-03-17-phase3-autoscaling.md` now has:

- Corrected File Map comment (max 4, cpu 5%)
- HPA in test-mode (5% threshold, comment explains production value)
- Task 5 replaced with kubectl one-liners for both HPA and CA scaling
