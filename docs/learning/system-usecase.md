# System Use Cases — What This Setup Can Do

Each use case is written as a scenario ("you do X, the system does Y") followed by a short explanation of why it works. Read `docs/learning/system-overview.md` first if you haven't — it establishes the mental model these use cases build on.

---

## Group 1 — Code Changes (the everyday flow)

### 1. Change one service

**Scenario:** You edit a file in `apps/api-express/`. You push to `main`.

The pipeline wakes up. NX compares the current commit against the previous one and finds that only `api-express` changed. It runs tests for `api-express` only, builds and pushes only the `api-express` Docker image to ECR (tagged with the new git SHA), patches the image tag in the K8s overlay, and deploys. `api-nest`, `api-python`, and `web` are completely skipped — no test, no build, no deploy.

**Why this works:** `nx affected` understands the monorepo's dependency graph. It doesn't just look at which files changed — it knows which *projects* those files belong to, and skips everything else. The deploy workflow iterates over services and checks `nx show projects --affected` before doing any Docker work.

---

### 2. Change a shared library

**Scenario:** You fix a bug in `libs/shared-types/`. You push to `main`.

NX sees that `libs/shared-types` changed. It then walks the dependency graph and finds that `api-nest` and `web` both import from it. Both are marked as affected — even though their own source files didn't change. Both get tested, rebuilt, and redeployed. `api-express` and `api-python`, which don't use the shared lib, are skipped.

**Why this works:** NX builds a project graph at workspace level. Every `import` from a lib creates a dependency edge. When a lib changes, all projects downstream of it in the graph are affected. This is the core value of a monorepo — a single change propagates correctly to everything that depends on it, automatically.

---

### 3. Change K8s config only (no code change)

**Scenario:** You need to increase the memory limit on `api-python`. You edit `k8s/base/api-python/deployment.yaml`, change the `resources.limits.memory` value, and push to `main`.

NX runs `nx affected` and finds... nothing. No application source code changed. No Docker images are built or pushed. But the deploy step still runs `kubectl apply -k k8s/overlays/prod`, which applies the updated manifest to the cluster. Kubernetes sees the resource limit change and does a rolling restart of `api-python` pods with the new config.

**Why this works:** The deploy workflow always runs `kubectl apply` on push to `main`, regardless of what `nx affected` returns. Docker build/push is skipped when nothing is affected, but manifest application always happens. The K8s manifest files are tracked in git, so any change to them flows through the same pipeline.

---

### 4. Open a pull request

**Scenario:** You're working on a feature. You push your branch and open a PR targeting `main`.

The CI workflow (`.github/workflows/ci.yml`) triggers on `pull_request`. It runs `nx run-many -t lint test build typecheck` across all projects. If anything fails, the PR is blocked. If everything passes, the PR gets a green check. **Nothing is deployed.** The deploy workflows only trigger on pushes to the `uat` or `prod` branches.

**Why this works:** Three workflows have separate `on:` triggers:
- `ci.yml` triggers on pushes to `main` and all PRs — pure quality gate
- `deploy-uat.yml` triggers on pushes to `uat` — build + deploy to UAT
- `deploy-prod.yml` triggers on pushes to `prod` — promote UAT images to prod

PRs go through CI but not deploy. You must explicitly merge to `uat` to trigger a UAT deploy.

---

### 4b. Promote from UAT to Prod

**Scenario:** You've tested the latest changes in UAT and want to go to production.

```bash
git checkout prod
git merge uat
git push origin prod
```

GitHub Actions triggers `deploy-prod.yml`. Because `environment: production` is set on the job, it pauses immediately and waits for a required reviewer to approve in the GitHub Actions UI. After approval, the workflow reads `k8s/overlays/uat/kustomization.yaml`, copies the exact ECR image URIs and SHAs into `k8s/overlays/prod/kustomization.yaml`, and deploys. No Docker build runs — the same images that ran in UAT go to prod.

**Why this works:** Prod deployment uses an approval gate for human sign-off, and image promotion (not rebuild) ensures the tested artifact is identical to what gets deployed. The UAT overlay committed on the `uat` branch is carried into the `prod` branch by the merge, so `deploy-prod.yml` can always find it.

---

## Group 2 — Ops & Recovery

### 5. Roll back a bad deploy

**Scenario:** You pushed to `main`, the deploy succeeded, but something is broken in prod. You need to revert.

**Option A — Revert and push (recommended):** Run `git revert HEAD` and push to `main`. The pipeline treats it like any other push — it detects the affected services, rebuilds the images from the reverted code, and redeploys. The image in ECR gets a new SHA tag pointing to the reverted state.

**Option B — In-cluster rollback (faster, no rebuild):** Run `kubectl rollout undo deployment/api-express`. Kubernetes immediately switches the deployment back to the previous pod spec (the previous image tag). No pipeline run, no image rebuild — takes seconds. The overlay file in git will be out of sync with what's running, so follow up with a proper revert commit when you can.

**Why this works:** Every deploy uses a unique git SHA as the image tag, so ECR always has the previous image available. Kubernetes keeps the previous `ReplicaSet` around after a rolling update, which is what `rollout undo` switches back to.

---

### 6. Debug a failed rollout

**Scenario:** The deploy workflow's "Wait for rollout" step times out. The workflow fails with `error: timed out waiting for the condition`.

First, check which pods are unhealthy:
```
kubectl get pods
```
Look for pods stuck in `CrashLoopBackOff`, `ImagePullBackOff`, `Pending`, or `Error`. Then dig into the specific pod:
```
kubectl describe pod <pod-name>    # shows events, scheduling issues, image pull errors
kubectl logs <pod-name>            # shows what the app printed before crashing
```

Common causes: bad environment variable (app crashes on startup), image pull failure (wrong ECR tag, IAM permissions), resource limits too low (OOMKilled), readiness probe failing (app not ready in time).

**Why this works:** `kubectl rollout status` blocks the workflow until all pods are healthy, which means a bad deploy fails loudly in CI rather than silently. The previous pods stay running during a rolling update — Kubernetes only terminates old pods after new ones pass their readiness probe — so a crash doesn't take down the service entirely.

---

### 7. Scale manually

**Scenario:** You're about to demo the app and want more `api-express` pods running for headroom. No code change needed.

```
kubectl scale deployment/api-express --replicas=4
```

Done. Kubernetes schedules 3 additional pods immediately. When you're done:
```
kubectl scale deployment/api-express --replicas=1
```

**Why this works:** `kubectl scale` directly updates the deployment's replica count in the cluster. It's temporary — the next `kubectl apply` (triggered by your next push to `main`) will reset replicas back to whatever the K8s manifest says. For permanent changes, edit `k8s/base/api-express/deployment.yaml` and push.

---

## Group 3 — Infrastructure Lifecycle

### 8. First-time setup from scratch

**Scenario:** You've cloned the repo on a new machine (or AWS account). Nothing exists in AWS yet.

1. Install prerequisites: `terraform`, `kubectl`, AWS CLI, configured with your account.
2. Provision UAT:
   ```
   cd infra/terraform/uat
   cp terraform.tfvars.example terraform.tfvars  # fill in github_repo
   terraform init && terraform apply
   ```
3. Provision prod:
   ```
   cd infra/terraform/prod
   cp terraform.tfvars.example terraform.tfvars
   terraform init && terraform apply
   ```
4. Each Terraform run creates: VPC, EKS cluster, 2× EC2 worker nodes, 4 ECR repos, IAM/OIDC role, Nginx Ingress, cluster-autoscaler, Metrics Server.
5. Add outputs as GitHub Environment secrets (UAT env: `UAT_AWS_ROLE_ARN`, `UAT_ECR_REGISTRY`, `UAT_EKS_CLUSTER_NAME`; prod env: `PROD_AWS_ROLE_ARN`, `PROD_EKS_CLUSTER_NAME`). Add `AWS_REGION` as a repo-level secret.
6. Add a required reviewer to the `production` GitHub Environment.
7. Merge to `uat` → deploy-uat deploys all services to UAT.
8. Merge `uat` → `prod` → approve in GitHub Actions UI → prod goes live.

**Why this works:** Terraform declares each AWS environment as code. `terraform apply` creates everything in the correct dependency order. The branch strategy (main → uat → prod) enforces a safe promotion path.

---

### 9. Tear down completely

**Scenario:** You're done for the week. Each cluster costs ~$150/month — you don't want them running while you're not using it.

```
cd infra/terraform/uat
terraform destroy

cd infra/terraform/prod
terraform destroy
```

Terraform removes everything it created per environment: EKS cluster, EC2 nodes, NLB, ECR repos, VPC, IAM roles. Nothing left billing.

**Why this works:** Terraform tracks every resource it created in a state file (`terraform.tfstate`). `terraform destroy` reads that state and deletes each resource in reverse dependency order. Don't try to delete resources manually through the AWS console — Terraform won't know about it and `destroy` will error or leave orphans.

---

### 10. Bring it back up

**Scenario:** You tore it down last week. Time to start again.

```
cd infra/terraform
terraform apply
```

Everything is recreated fresh — new cluster, new nodes, new NLB with a new public IP. The ECR repos are recreated but empty (images were deleted with `destroy`). Push to `main` and the pipeline rebuilds and pushes all images, then deploys all services.

**Why this works:** Terraform is declarative — `apply` always drives the real world toward the declared state. Whether the resources exist or not, `apply` creates what's missing. The git repo is the only persistent state you need between teardown and bring-up.

---

### 11. Change infrastructure

**Scenario:** The `t3.medium` nodes are too small. You want `t3.large`.

Edit `infra/terraform/eks.tf`, change `instance_types = ["t3.medium"]` to `["t3.large"]`. Then:

```
terraform plan    # shows: "will replace node group t3.medium → t3.large"
terraform apply   # performs rolling node replacement
```

Terraform drains the old nodes, provisions new `t3.large` nodes, and migrates pods onto them. Your services stay running throughout (assuming enough replicas to tolerate one node going down at a time).

**Why this works:** Terraform computes a diff between the current state (from `terraform.tfstate`) and the desired state (your `.tf` files). `plan` shows you exactly what will change — create, modify, or destroy — before anything happens. This is the core safety guarantee of infrastructure-as-code.

---

### 12. Add a new service

**Scenario:** You want to add a 5th service, `api-go`, to the mesh.

Follow the existing pattern:

1. `nx generate @nx/node:app api-go` — scaffold the app in `apps/api-go/`
2. Add a `/ping` endpoint that calls the next service in the chain
3. Write `apps/api-go/Dockerfile`
4. Add a `docker-build` target to `apps/api-go/project.json`
5. Add K8s manifests: `k8s/base/api-go/deployment.yaml` + `service.yaml`
6. Add a routing rule to `k8s/base/api-ingress.yaml`
7. Add the ECR repo: new `resource "aws_ecr_repository" "api_go"` block in `infra/terraform/ecr.tf` → `terraform apply`
8. Add `"api-go"` to the `SERVICES` array in `.github/workflows/deploy.yml`
9. Push. NX detects the new project as affected, the pipeline builds and deploys it.

**Why this works:** Every part of this system is pattern-based. NX, Terraform, Kustomize, and the deploy workflow are all built around repeatable units. Adding a service means adding one instance of each pattern — no special-casing required.
