# Phase 2 Report — Anti-Patterns & Real-World Gaps

This report reflects the current state of the project as of the latest update.
Items marked ✅ were previously flagged and have since been fixed.

---

## ✅ Fixed Since Last Audit

| Area | What Was Fixed |
|------|---------------|
| CI/CD | Base SHA now reads from last successful deploy run via `gh run list` (no longer falls back blindly to `origin/main~1`) |
| CI/CD | `workflow_dispatch` with `force_all` input added for manual full rebuilds |
| Kubernetes | Service-to-service URLs now use correct K8s DNS (`http://api-express.default.svc.cluster.local:3001`) |
| Docker | Non-root user (`nodejs` / `appuser`) added to all service images |
| Kubernetes | `web` deployment memory limit raised to 512Mi |

---

## Still Present

### 1. CI/CD

#### Auto-push image tags to `main` (`ci-cd.yml`)
```yaml
git pull --rebase origin main
git push
```
CI commits updated image tags back to `main` on every deploy. If `[skip ci]` is ever missed this creates an infinite loop. It also races with developer pushes.

**Production pattern:** Store image tags outside the main branch — a dedicated unprotected `gitops` branch, an SSM Parameter Store value, or a Helm values file in a separate repo.

#### Hardcoded AWS account ID (`k8s/overlays/prod/kustomization.yaml`)
```yaml
newName: <ECR_REGISTRY>/api-python
```
Account ID is sensitive and committed to version control.

**Production pattern:** Use a GitHub secret (`ECR_REGISTRY`) substituted at deploy time. CI already has this variable — the static placeholder in kustomization.yaml should never contain a real account ID.

#### No image vulnerability scanning
Docker images are built and pushed with no security scan. A compromised package ships directly to EKS.

**Production pattern:** Add a Trivy or Grype step between `docker push` and `kustomize edit set image`:
```yaml
- name: Scan image
  uses: aquasecurity/trivy-action@master
  with:
    image-ref: "${{ env.ECR_REGISTRY }}/${{ env.SVC }}:${{ env.IMAGE_TAG }}"
    exit-code: '1'
    severity: 'CRITICAL,HIGH'
```

---

### 2. Kubernetes

#### Single replica everywhere (`k8s/base/*/deployment.yaml`)
```yaml
replicas: 1
```
Any pod crash means full service downtime until K8s reschedules (~30–60s).

**Production pattern:** `replicas: 2` minimum. Add a `PodDisruptionBudget` with `minAvailable: 1` so node drains during cluster upgrades don't kill the only running pod.

#### Missing `livenessProbe` (all deployments)
Only `readinessProbe` is defined. A pod that starts successfully but later deadlocks stays "Running" forever and never gets restarted — it just drops all requests silently.

**Production pattern:** Add a `livenessProbe` with a slightly higher `failureThreshold` than readiness so it doesn't kill pods too aggressively:
```yaml
livenessProbe:
  httpGet:
    path: /ping
    port: 3001
  initialDelaySeconds: 15
  periodSeconds: 20
  failureThreshold: 3
```

#### No `securityContext` (all deployments)
Pods run with default privileges even though the containers already create non-root users.

**Production pattern:**
```yaml
securityContext:
  runAsNonRoot: true
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: ["ALL"]
```

#### No `NetworkPolicy`
Every pod in the cluster can talk to every other pod freely. The architecture is a strict chain (web → nest → express → python) but nothing enforces it.

**Production pattern:** Default-deny ingress per namespace, then explicit allow rules matching the actual call graph.

#### Memory limits too low for Node services (`k8s/base/api-express`, `api-nest`)
```yaml
limits:
  memory: "256Mi"
```
NestJS and Express apps under real load easily exceed 256Mi. OOMKilled pods restart in a loop.

**Production pattern:** Load test first, set limits at ~2× observed peak. 512Mi is a safer starting point for Node APIs.

#### `ImplementationSpecific` pathType in Ingress (`k8s/base/api-ingress.yaml`)
```yaml
pathType: ImplementationSpecific
```
Required here for the regex rewrite to work with NGINX, but this is non-portable — it silently breaks on other ingress controllers (ALB, Traefik). The trade-off should be documented.

---

### 3. Docker

#### Python image not pinned to patch version (`apps/api-python/Dockerfile`)
```dockerfile
FROM python:3.12-slim
```
Floats on every rebuild. Two builds a week apart may have different patch versions.

**Production pattern:** Pin to `python:3.12.5-slim` and update deliberately via Dependabot or a manual review cycle.

#### Inconsistent NX project name prefix in Dockerfiles
```dockerfile
# api-express/Dockerfile
npx nx run @org/api-express:prune

# api-nest/Dockerfile
npx nx run api-nest:prune   ← missing @org/ prefix
```
If either naming convention changes one will break silently. Should be consistent.

---

### 4. Application Code

#### No graceful shutdown in Node services (`apps/api-express/src/main.ts`, `apps/api-nest/src/main.ts`)
```typescript
app.listen(port, () => console.log(`listening on port ${port}`));
// No SIGTERM handler
```
K8s sends SIGTERM 30s before force-killing a pod. Without a handler, in-flight requests are dropped on every rolling deploy.

**Production pattern:**
```typescript
const server = app.listen(port);
process.on('SIGTERM', () => {
  server.close(() => process.exit(0));
});
```

#### No fetch timeout (`apps/api-express/src/app.ts`)
```typescript
await fetch(`${pythonUrl}/ping`)  // hangs indefinitely if python is slow
```
A slow or stuck downstream service blocks the Node event loop thread.

**Production pattern:**
```typescript
fetch(url, { signal: AbortSignal.timeout(5000) })
```

#### Silent error handlers with no logging (`apps/api-express/src/app.ts`, `apps/api-nest`)
```typescript
} catch {
  res.status(502).json({ ... });  // error swallowed, nothing logged
}
```
No way to know what failed or why. In production, debugging a 502 with no logs is very painful.

**Production pattern:** `console.error(err)` at minimum, or a structured logger (pino, winston). Log the error before responding.

---

### 5. Missing Production Concerns

| Area | What's Missing |
|------|---------------|
| Observability | No Prometheus metrics, no distributed tracing, no structured logging |
| TLS | Ingress serves plain HTTP — no cert-manager, no HTTPS |
| Rate limiting | No ingress rate-limit annotations |
| RBAC | Pods use the default ServiceAccount with full cluster API access |
| Autoscaling | No `HorizontalPodAutoscaler` — traffic spikes can't be absorbed |
| Resilience | No `PodDisruptionBudget` — cluster upgrades can kill all pods simultaneously |
| Namespace isolation | Everything in `default` — no dev/staging/prod separation |
| Dependency pinning | `^` and `~` in `package.json` allow silent minor version updates |
| Python tests | `pytest` is installed but no tests exist for `api-python` |

---

## Summary

The project has improved meaningfully — service discovery URLs are correct, all images run as non-root, and the CI base SHA logic is now reliable. The remaining gaps are typical of a phase-2 project: the infrastructure runs, but it's fragile under failure conditions (single replicas, no liveness probes, no graceful shutdown) and would need another hardening pass before handling real traffic.
