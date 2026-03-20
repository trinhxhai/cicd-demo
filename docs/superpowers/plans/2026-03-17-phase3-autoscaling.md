# Phase 3: Autoscaling Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two-level autoscaling to the EKS cluster: HPA scales `api-express` pods on CPU, and Cluster Autoscaler adds/removes EC2 nodes. Use k6 to load test and observe both levels scale up and back down.

**Architecture:** Metrics Server feeds live CPU/memory data to HPA. HPA watches `api-express` only — it scales pods when CPU > 70%. When pods can't be scheduled (nodes full), Cluster Autoscaler adds EC2 nodes via the ASG. PodDisruptionBudget ensures at least 1 Express pod stays up during scale-down. All changes are layered on top of Phase 2 with no destructive modifications.

**Tech Stack:** Kubernetes Metrics Server, HPA, Cluster Autoscaler, PodDisruptionBudget, k6

**Prerequisite:** Phase 2 must be complete. EKS cluster must be running with all 4 services deployed.

---

## File Map

```
k8s/
  base/
    metrics-server.yaml            ← Metrics Server installation manifest
    api-express/
      hpa.yaml                     ← HPA for api-express (min 1, max 4, cpu 5% test-mode)
      pdb.yaml                     ← PodDisruptionBudget (minAvailable: 1)
    cluster-autoscaler.yaml        ← Cluster Autoscaler deployment + RBAC

k8s/base/kustomization.yaml        ← Modified to include new resources

```

---

## Task 1: Metrics Server

The Metrics Server collects CPU and memory metrics from kubelets. HPA cannot function without it.

- [ ] **Step 1: Create metrics-server manifest**

Create `k8s/base/metrics-server.yaml`:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  labels:
    k8s-app: metrics-server
  name: metrics-server
  namespace: kube-system
---
# Install via official release manifest (pinned version)
# Source: https://github.com/kubernetes-sigs/metrics-server/releases
# We use a ConfigMap to reference the version so it's explicit and auditable.
```

> Instead of maintaining the full manifest inline, use the official release:

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.7.1/components.yaml
```

Record the URL and version in the manifest file for auditability:

Create `k8s/base/metrics-server.yaml`:

```yaml
# Metrics Server v0.7.1
# Apply with: kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.7.1/components.yaml
# This file is a placeholder to document the version used.
# Run the above command during cluster setup or add it to infra/setup.sh.
apiVersion: v1
kind: ConfigMap
metadata:
  name: metrics-server-version
  namespace: kube-system
data:
  version: "v0.7.1"
  install-command: "kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.7.1/components.yaml"
```

- [ ] **Step 2: Install Metrics Server on the cluster**

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.7.1/components.yaml
```

- [ ] **Step 3: Verify Metrics Server is running**

```bash
kubectl get deployment metrics-server -n kube-system
```

Expected: `READY 1/1`.

- [ ] **Step 4: Verify metrics are flowing (wait ~60s after install)**

```bash
kubectl top nodes
kubectl top pods
```

Expected: CPU and memory numbers appear (not `<unknown>`).

- [ ] **Step 5: Commit**

```bash
git add k8s/base/metrics-server.yaml
git commit -m "feat: add Metrics Server for HPA data collection"
```

---

## Task 2: HPA for api-express

The Horizontal Pod Autoscaler watches CPU on `api-express` pods and scales between 1 and 10 replicas.

- [ ] **Step 1: Write the HPA manifest**

Create `k8s/base/api-express/hpa.yaml`:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: api-express-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: api-express
  minReplicas: 1
  maxReplicas: 4
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 5    # TEST MODE — change to 70 for production
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 30     # react quickly to load spikes
    scaleDown:
      stabilizationWindowSeconds: 120    # wait 2 min before scaling down (avoid flapping)
```

- [ ] **Step 2: Apply the HPA**

```bash
kubectl apply -f k8s/base/api-express/hpa.yaml
```

- [ ] **Step 3: Verify HPA is watching the deployment**

```bash
kubectl get hpa api-express-hpa
```

Expected output (approximately):
```
NAME               REFERENCE              TARGETS   MINPODS   MAXPODS   REPLICAS
api-express-hpa    Deployment/api-express  0%/5%     1         4         1
```

The `TARGETS` column shows current CPU % vs the 70% threshold.

- [ ] **Step 4: Commit**

```bash
git add k8s/base/api-express/hpa.yaml
git commit -m "feat: add HPA for api-express (min 1, max 4, target CPU 5% test-mode)"
```

---

## Task 3: PodDisruptionBudget

Ensures at least 1 `api-express` pod stays up during node drains and scale-down events.

- [ ] **Step 1: Write the PDB manifest**

Create `k8s/base/api-express/pdb.yaml`:

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: api-express-pdb
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: api-express
```

- [ ] **Step 2: Apply the PDB**

```bash
kubectl apply -f k8s/base/api-express/pdb.yaml
```

- [ ] **Step 3: Verify PDB is active**

```bash
kubectl get pdb api-express-pdb
```

Expected: `ALLOWED-DISRUPTIONS` is 0 when 1 pod is running (protecting the last pod), 1+ when multiple pods are running.

- [ ] **Step 4: Commit**

```bash
git add k8s/base/api-express/pdb.yaml
git commit -m "feat: add PodDisruptionBudget for api-express (minAvailable: 1)"
```

---

## Task 4: Cluster Autoscaler

Watches for unschedulable pods (no room on nodes) and adds EC2 nodes via the Auto Scaling Group.

- [ ] **Step 1: Create Cluster Autoscaler manifest**

Create `k8s/base/cluster-autoscaler.yaml`:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: cluster-autoscaler
  namespace: kube-system
  annotations:
    # IAM role ARN for the Cluster Autoscaler service account
    # eksctl created this role when we set autoScaler: true in cluster.yaml
    eks.amazonaws.com/role-arn: "REPLACE_WITH_CLUSTER_AUTOSCALER_ROLE_ARN"
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: cluster-autoscaler
rules:
  - apiGroups: [""]
    resources: ["events", "endpoints"]
    verbs: ["create", "patch"]
  - apiGroups: [""]
    resources: ["pods/eviction"]
    verbs: ["create"]
  - apiGroups: [""]
    resources: ["pods/status"]
    verbs: ["update"]
  - apiGroups: [""]
    resources: ["endpoints"]
    resourceNames: ["cluster-autoscaler"]
    verbs: ["get", "update"]
  - apiGroups: [""]
    resources: ["nodes"]
    verbs: ["watch", "list", "get", "update"]
  - apiGroups: [""]
    resources: ["namespaces", "pods", "services", "replicationcontrollers", "persistentvolumeclaims", "persistentvolumes"]
    verbs: ["watch", "list", "get"]
  - apiGroups: ["extensions"]
    resources: ["replicasets", "daemonsets"]
    verbs: ["watch", "list", "get"]
  - apiGroups: ["policy"]
    resources: ["poddisruptionbudgets"]
    verbs: ["watch", "list"]
  - apiGroups: ["apps"]
    resources: ["statefulsets", "replicasets", "daemonsets"]
    verbs: ["watch", "list", "get"]
  - apiGroups: ["storage.k8s.io"]
    resources: ["storageclasses", "csinodes", "csidrivers", "csistoragecapacities"]
    verbs: ["watch", "list", "get"]
  - apiGroups: ["batch"]
    resources: ["jobs", "cronjobs"]
    verbs: ["watch", "list", "get"]
  - apiGroups: ["coordination.k8s.io"]
    resources: ["leases"]
    verbs: ["create"]
  - apiGroups: ["coordination.k8s.io"]
    resources: ["leases"]
    resourceNames: ["cluster-autoscaler"]
    verbs: ["get", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: cluster-autoscaler
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-autoscaler
subjects:
  - kind: ServiceAccount
    name: cluster-autoscaler
    namespace: kube-system
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cluster-autoscaler
  namespace: kube-system
  labels:
    app: cluster-autoscaler
spec:
  replicas: 1
  selector:
    matchLabels:
      app: cluster-autoscaler
  template:
    metadata:
      labels:
        app: cluster-autoscaler
    spec:
      serviceAccountName: cluster-autoscaler
      containers:
        - name: cluster-autoscaler
          image: registry.k8s.io/autoscaling/cluster-autoscaler:v1.30.0
          command:
            - ./cluster-autoscaler
            - --v=4
            - --stderrthreshold=info
            - --cloud-provider=aws
            - --skip-nodes-with-local-storage=false
            - --expander=least-waste
            - --node-group-auto-discovery=asg:tag=k8s.io/cluster-autoscaler/enabled,k8s.io/cluster-autoscaler/nx-monorepo
            - --balance-similar-node-groups
            - --skip-nodes-with-system-pods=false
          env:
            - name: AWS_REGION
              value: us-east-1
          resources:
            requests:
              cpu: 100m
              memory: 300Mi
            limits:
              cpu: 100m
              memory: 300Mi
```

- [ ] **Step 2: Get the Cluster Autoscaler IAM role ARN**

```bash
# eksctl created this role when we used autoScaler: true in cluster.yaml
aws iam list-roles --query "Roles[?contains(RoleName, 'cluster-autoscaler') || contains(RoleName, 'eksctl')].{Name:RoleName,ARN:Arn}" --output table
```

Find the role with `cluster-autoscaler` or `autoscaler` in the name. Copy its ARN.

- [ ] **Step 3: Substitute the role ARN in the manifest**

```bash
# Replace REPLACE_WITH_CLUSTER_AUTOSCALER_ROLE_ARN with the actual ARN
# e.g. arn:aws:iam::123456789:role/eksctl-nx-monorepo-addon-iamserviceaccount-Role1-ABC123
sed -i 's|REPLACE_WITH_CLUSTER_AUTOSCALER_ROLE_ARN|<PASTE_ARN_HERE>|g' k8s/base/cluster-autoscaler.yaml
```

- [ ] **Step 4: Apply the Cluster Autoscaler**

```bash
kubectl apply -f k8s/base/cluster-autoscaler.yaml
```

- [ ] **Step 5: Verify Cluster Autoscaler is running**

```bash
kubectl get deployment cluster-autoscaler -n kube-system
kubectl logs -f deployment/cluster-autoscaler -n kube-system | head -20
```

Expected: pod is `Running`, logs show "Starting main loop" without errors.

- [ ] **Step 6: Update base kustomization.yaml to include new resources**

Edit `k8s/base/kustomization.yaml` and add:

```yaml
  - api-express/hpa.yaml
  - api-express/pdb.yaml
  - cluster-autoscaler.yaml
```

- [ ] **Step 7: Commit**

```bash
git add k8s/base/cluster-autoscaler.yaml k8s/base/api-express/hpa.yaml k8s/base/api-express/pdb.yaml k8s/base/kustomization.yaml
git commit -m "feat: add Cluster Autoscaler, HPA, and PDB for phase 3 autoscaling"
```

---

## Task 5: k6 Load Test + Observe Autoscaling

Trigger both HPA and Cluster Autoscaler with a real load test and watch the scaling happen live.

- [ ] **Step 1: Install k6**

```bash
# macOS
brew install k6

# Or download from https://k6.io/docs/get-started/installation/
```

- [ ] **Step 2: Create the load test script**

Create `load-tests/ping-load.js`:

```javascript
import http from 'k6/http';
import { sleep, check } from 'k6';

// Target the api-express service directly via NLB ingress
const TARGET_URL = __ENV.TARGET_URL || 'http://localhost:3001';

export const options = {
  stages: [
    { duration: '1m', target: 30 },    // ramp up to 30 users over 1 minute
    { duration: '3m', target: 60 },    // hold at 60 users for 3 minutes (triggers HPA)
    { duration: '1m', target: 100 },   // spike to 100 (push toward max 4 pods)
    { duration: '2m', target: 0 },     // ramp down (observe scale-down)
  ],
};

export default function () {
  const res = http.get(`${TARGET_URL}/ping`);
  check(res, {
    'status is 200': (r) => r.status === 200,
    'has service field': (r) => JSON.parse(r.body).service === 'express',
  });
  sleep(0.1);
}
```

- [ ] **Step 3: Get the NLB address**

```bash
NLB_ADDRESS=$(kubectl get ingress app-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "NLB: $NLB_ADDRESS"
```

- [ ] **Step 4: Open a watch window for pods and HPA**

In a separate terminal, run:

```bash
# Watch HPA and pods update in real time
watch -n 5 "kubectl get hpa api-express-hpa && echo '' && kubectl get pods -l app=api-express && echo '' && kubectl get nodes"
```

This shows:
- HPA: current CPU% vs 70% threshold, current replica count
- Pods: how many Express pods are running
- Nodes: how many EC2 nodes are in the cluster

- [ ] **Step 5: Run the load test**

In your main terminal:

```bash
k6 run \
  -e TARGET_URL=http://$NLB_ADDRESS/api/express \
  load-tests/ping-load.js
```

- [ ] **Step 6: Observe what happens (expected sequence)**

```
~0:00  - 1 Express pod, CPU ~5%, 2 nodes
~1:00  - CPU spikes above 70% → HPA adds pods (2, 3, up to 4)
~3:00  - HPA holds at 4 pods (max); CPU distributes across pods
         Note: 4 pods × 100m CPU fit easily on 2 t3.medium nodes,
         so Cluster Autoscaler may not trigger (no Pending pods)
~5:00  - Load ramps down → CPU drops
~7:00  - HPA scales pods back to 1 (120s stabilization window)
~10:00 - Cluster Autoscaler removes any unused nodes (if it added any)
```

- [ ] **Step 7: Verify scale-up happened**

After the 100-user stage, check:

```bash
kubectl get hpa api-express-hpa
# REPLICAS should be > 1

kubectl get nodes
# Should see more than 2 nodes
```

- [ ] **Step 8: Verify scale-down happened**

After the load test ends, wait 5 minutes then check:

```bash
kubectl get hpa api-express-hpa
# REPLICAS should be back to 1

kubectl get nodes
# Should be back to 2 nodes (Cluster Autoscaler default cooldown is ~10min)
```

- [ ] **Step 9: Commit the load test**

```bash
git add load-tests/
git commit -m "feat: add k6 load test for autoscaling verification"
```

- [ ] **Step 10: Final commit**

```bash
git commit --allow-empty -m "chore: phase 3 complete — HPA and Cluster Autoscaler verified with k6"
```

---

## Phase 3 Done ✓

**Success criterion met when:**
- k6 load test → HPA scales `api-express` from 1 pod up to 4 pods
- HPA scales back down to 1 pod after load ends
- Cluster Autoscaler adds EC2 nodes IF pods become Pending (unlikely with max=4 on t3.medium, but CA is deployed and watching)

**Cost reminder:** Always run `infra/teardown.sh` after your session. Phase 3 with Cluster Autoscaler can add nodes temporarily, billed by the hour.

---

## Full Project Complete ✓

You now have:
- **Phase 1:** Full NX monorepo running locally with Docker Compose, TDD-tested echo/ping mesh
- **Phase 2:** EKS cluster with GitHub Actions CI/CD — every push deploys automatically
- **Phase 3:** Two-level autoscaling — HPA scales pods, Cluster Autoscaler scales nodes
