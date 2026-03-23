# AWS Setup Review — Phase 4 Report

*Date: 2026-03-23*

## What Was Built in Phase 4

- 3-workflow CI/CD split: `ci.yml` (lint/test/build), `deploy-uat.yml` (build + push + deploy), `deploy-prod.yml` (promote UAT tags + deploy)
- Separate Terraform workspaces for UAT and prod EKS clusters
- ESO + AWS Secrets Manager secret management (`SERVICE_SECRET` per environment)
- NestJS startup log printing `SERVICE_SECRET`
- IAM fix: `eks:DescribeCluster` on wildcard resource for UAT CI role
- Nginx Ingress exposing web frontend on port 80

**URLs:**

- UAT: [http://a81f8a702302c47059c17008d9c2bdc9-1594378028.us-east-1.elb.amazonaws.com](http://a81f8a702302c47059c17008d9c2bdc9-1594378028.us-east-1.elb.amazonaws.com)
- Prod: [http://a32eb2058139b481f8fd7553f14225bb-338487499.us-east-1.elb.amazonaws.com](http://a32eb2058139b481f8fd7553f14225bb-338487499.us-east-1.elb.amazonaws.com)

---

## Readiness Review — Small-to-Mid Company Standard

### What's genuinely production-grade ✅


| Area                  | What exists                                                                                                 |
| --------------------- | ----------------------------------------------------------------------------------------------------------- |
| **CI/CD**             | 3-workflow split, OIDC auth (no long-lived keys), affected-only builds, Trivy scanning blocking on CRITICAL |
| **Secret management** | ESO + AWS Secrets Manager, IRSA-scoped per env, no secrets in git                                           |
| **Promotion model**   | UAT builds images → prod promotes exact SHA tags (no rebuild, exact parity)                                 |
| **Infra as code**     | Full Terraform for VPC, EKS, IAM, ECR, Helm; separate workspaces per env                                    |
| **Autoscaling**       | Cluster Autoscaler + HPA wired up and deployed                                                              |
| **Network**           | Private subnets for nodes, public for NLB, 2 AZs, NAT gateway                                               |
| **k8s hygiene**       | Resource requests/limits, readiness probes, PDB, kustomize overlays                                         |
| **Security**          | ECR scan-on-push, Trivy in CI, IRSA (no node-level IAM)                                                     |


---

### Gaps — High Priority (fix before real production traffic)


| Gap                                 | Risk                                                        | Fix                                                         |
| ----------------------------------- | ----------------------------------------------------------- | ----------------------------------------------------------- |
| No Terraform remote state           | State is local — team conflicts cause drift or corruption   | Add S3 backend + DynamoDB lock table                        |
| **Single NAT Gateway in prod**      | One AZ failure kills all private subnet traffic             | `single_nat_gateway = false` in prod VPC                    |
| **EKS API server is fully public**  | API server exposed to internet (brute-force, zero-day risk) | Set `cluster_endpoint_public_access_cidrs` to office/VPN IP |
| GitHub Actions role = cluster admin | CI compromise = full cluster takeover                       | Scope to namespace-level deploy role, not full admin        |
| **HPA threshold at 5% CPU**         | Scales aggressively, wastes money, creates noise in prod    | Change to 70% for prod                                      |


---

### Gaps — Medium Priority (common at real companies, not immediately blocking)


| Gap                              | Note                                                                                               |
| -------------------------------- | -------------------------------------------------------------------------------------------------- |
| **No observability**             | No CloudWatch Container Insights, no Prometheus/Grafana, no log aggregation — flying blind on prod |
| **No alerting**                  | No alarms on pod crashes, high error rates, or deployment failures                                 |
| **No HPA for nest/python/web**   | Only `api-express` autoscales; others stuck at 1 replica                                           |
| **Metrics Server is manual**     | Documented but not Helm-managed — disappears on cluster rebuild                                    |
| **Hardcoded account ID**         | `cluster-autoscaler.yaml` has `514453840552` hardcoded — breaks on new AWS account                 |
| **ECR image tags are mutable**   | Tags can be overwritten; use `IMMUTABLE` for prod repos                                            |
| `**force_delete = true` on ECR** | Terraform can destroy repos with live images — risky for prod                                      |


---

### Gaps — Nice-to-Have (mid-size company standard)


| Gap                       | Note                                                           |
| ------------------------- | -------------------------------------------------------------- |
| No domain name / TLS      | NLB hostname only, HTTP — needs cert-manager + ACM + Route53   |
| No network policies       | Pods can reach each other freely inside the cluster            |
| No pod security standards | No `restricted` or `baseline` admission enforcement            |
| No multi-region           | Single `us-east-1`                                             |
| No cost tagging strategy  | No `Environment`, `Team`, `Service` tags for AWS Cost Explorer |


---

## Bottom Line

For a **learning project or internal tool** this is solid — top tier skeleton: OIDC, IRSA, secret management, image promotion, autoscaling.

For **real production traffic with paying users**, the three things that matter most:

1. **Remote Terraform state (S3 + DynamoDB)** — without it the infra is fragile and team-hostile
2. **Single NAT Gateway** — one AZ failure takes down prod networking entirely
3. **Observability** — currently no way to know when things break in prod

Everything else is hardening, not survival.