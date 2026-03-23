# Topic: `CI/CD Security`

## Current Understanding

### Foundations

- GitHub Actions can authenticate to AWS without static IAM keys by using OpenID Connect (OIDC).
- GitHub issues a short-lived JWT token to a workflow when `id-token: write` permission is granted.
- AWS IAM trusts GitHub's OIDC provider and allows role assumption only when token claims match trust policy conditions.

### Detailed Mechanics

- In a workflow, `aws-actions/configure-aws-credentials` requests a GitHub OIDC token from `token.actions.githubusercontent.com`.
- The action calls AWS STS `AssumeRoleWithWebIdentity` using that token.
- AWS validates:
  - OIDC provider configured in IAM (`https://token.actions.githubusercontent.com`)
  - `aud` claim (typically `sts.amazonaws.com`)
  - `sub` claim (for example `repo:ORG/REPO:ref:refs/heads/main`)
- If claims match, AWS returns temporary credentials scoped by this project's IAM role `github-actions-eks` (defined in `infra/terraform/iam.tf`) and its attached permissions.
- Security benefit: no long-lived AWS access key/secret stored in GitHub.

### My Interest Focus

- Practical setup steps on both sides (GitHub and AWS).
- How to correctly write trust policy conditions, especially `sub` patterns.
- How to avoid common CI auth failures during OIDC rollout.
- How this repo currently balances convenience vs strict least-privilege in OIDC trust.

### Current State (Updated 2026-03-23)

- **Separate roles per environment**: `github-actions-uat` and `github-actions-prod` — each environment only has access to its own cluster and ECR.
- **Least-privilege permissions**: CI role no longer uses the EKS cluster admin policy. Instead it has `AmazonEKSEditPolicy` scoped to the `default` namespace only, plus ECR push/pull.
- **ESO RBAC managed by Terraform**: A `ClusterRole` and binding are created in Terraform for the `ci-deployers` group, granting ESO the permissions it needs without manual kubectl steps.

## Questions Asked

- 2026-03-20: Authenticate to AWS using OIDC, how it works, and setup on GitHub + AWS.
- 2026-03-20: Write the answer based on what this project already implements.
- 2026-03-20: Where are the role name and permissions defined in this project?
- 2026-03-23: What changed with least-privilege and multi-env separation?

## Q&A Log

### Q: Authenticate to AWS using OIDC - how it work and step to set up at each side, github and aws?

A: OIDC lets GitHub Actions exchange a short-lived identity token for temporary AWS credentials, so you do not store long-lived AWS keys in GitHub. Setup is: (1) in AWS, create IAM OIDC provider (`token.actions.githubusercontent.com`, audience `sts.amazonaws.com`), create IAM role with trust policy restricted by `aud` and `sub`, and attach least-privilege permissions; (2) in GitHub workflow, grant `permissions: id-token: write`, run `aws-actions/configure-aws-credentials` with `role-to-assume`, then execute AWS commands. The key security control is strict `sub` matching (repo + branch/tag/environment) in the role trust policy.

- Confidence: high
- Reasoning: This follows the standard GitHub Actions OIDC federation model to AWS STS and aligns with official trust policy patterns (`aud` + `sub` conditions).
- Related concepts: OIDC, JWT, AWS STS, AssumeRoleWithWebIdentity, IAM trust policy, least privilege

### Q: Please write answer based on what this project already implement

A: In this project, OIDC auth is implemented end-to-end with separate roles per environment. On GitHub side, `deploy-uat.yml` uses `role-to-assume: ${{ secrets.UAT_AWS_ROLE_ARN }}` and `deploy-prod.yml` uses `role-to-assume: ${{ secrets.PROD_AWS_ROLE_ARN }}`. Both grant `id-token: write`. `ci.yml` (which runs on `main` and PRs) does not authenticate to AWS at all — no deployment happens there. On AWS side, Terraform in `infra/terraform/uat/iam.tf` and `infra/terraform/prod/iam.tf` each create their own GitHub OIDC provider and role. The trust policy matches `repo:${var.github_repo}:*` while workflow-level conditions (separate branch triggers) prevent cross-environment deployment. Each role uses `AmazonEKSEditPolicy` scoped to the `default` namespace — not cluster-admin — giving CI only the permissions it needs to apply manifests. ESO RBAC (ClusterRole + binding for `ci-deployers`) is also managed by Terraform in `iam.tf`.

- Confidence: high
- Reasoning: Derived from `.github/workflows/deploy-uat.yml`, `.github/workflows/deploy-prod.yml`, and `infra/terraform/prod/iam.tf` / `infra/terraform/uat/iam.tf`.
- Related concepts: GitHub Actions permissions, OIDC provider, IAM role trust policy, Terraform, ECR, EKS access entries, least privilege

### Q: Where are the role names and permissions defined in this project?

A: They are defined separately in `infra/terraform/uat/iam.tf` and `infra/terraform/prod/iam.tf`. Each file creates: the GitHub OIDC provider, a CI role (e.g. `github-actions-uat`), ECR push/pull policy attachment, `eks:DescribeCluster` permission, and an EKS access entry with `AmazonEKSEditPolicy` scoped to the `default` namespace. It also creates a `ClusterRole` and `ClusterRoleBinding` for the `ci-deployers` group to support ESO RBAC. In the workflows, UAT uses `secrets.UAT_AWS_ROLE_ARN` and prod uses `secrets.PROD_AWS_ROLE_ARN`.

- Confidence: high
- Reasoning: Role definitions are in per-environment Terraform files; workflow references are in `deploy-uat.yml` and `deploy-prod.yml`.
- Related concepts: IAM role, policy attachment, EKS access entry, AmazonEKSEditPolicy, ESO RBAC, least privilege

### Q: What changed with least-privilege and multi-env separation?

A: Phase 4 introduced environment separation. Previously there was one `github-actions-eks` role with EKS cluster admin access used for all deployments. Now there are two roles (`github-actions-uat`, `github-actions-prod`), each scoped to their own cluster and namespace. The EKS access policy was downgraded from cluster admin to `AmazonEKSEditPolicy` restricted to the `default` namespace — CI can manage workloads there but cannot touch cluster-level resources. ESO RBAC was also moved from manual kubectl to Terraform-managed `ClusterRole` + `ClusterRoleBinding` for the `ci-deployers` group.

- Confidence: high
- Reasoning: Derived from git history (commits `a48dd19`, `3a42158`, `9a86e0f`) and current Terraform files.
- Related concepts: least privilege, AmazonEKSEditPolicy, namespace scoping, ESO RBAC, ClusterRole

## Key Concepts

- OpenID Connect (OIDC)
- `token.actions.githubusercontent.com`
- `sts:AssumeRoleWithWebIdentity`
- `token.actions.githubusercontent.com:aud`
- `token.actions.githubusercontent.com:sub`
- Temporary credentials
- Least-privilege IAM policy
- `repo:${var.github_repo}:*` trust pattern
- deploy gating in workflow conditions

## Examples

- Command/example:
  - GitHub workflow permissions:
    - `permissions: { id-token: write, contents: read }`
  - Trust policy condition example:
    - `"token.actions.githubusercontent.com:sub": "repo:ORG/REPO:ref:refs/heads/main"`
  - Verification command in workflow:
    - `aws sts get-caller-identity`
  - This project's trust pattern in Terraform:
    - `values = ["repo:${var.github_repo}:*"]`
  - This project's deploy condition in workflow:
    - `if: (github.ref == 'refs/heads/main' && github.event_name == 'push') || github.event_name == 'workflow_dispatch'`

## Misconceptions Corrected

- "GitHub must store permanent AWS keys for deployments" -> OIDC removes that need by using short-lived role credentials.
- "Any workflow in the repo can assume the role" -> Only workflows whose token claims match trust policy conditions can assume it.

## Open Questions / Next Questions

- What CloudTrail events should be monitored for OIDC role usage anomalies?
- Should trust policies be tightened further to environment-specific `sub` claims (e.g. `repo:ORG/REPO:environment:uat`)?

## Revision History

- 2026-03-20: Created and populated topic file with first OIDC AWS authentication Q&A entry.
- 2026-03-20: Added project-implementation-based OIDC explanation from workflow and Terraform files.
- 2026-03-20: Clarified where role name and permissions are defined; added direct Q&A for lookup.
- 2026-03-23: Updated to reflect multi-environment separation (UAT/prod), least-privilege AmazonEKSEditPolicy, ESO RBAC via Terraform. Answered previously open questions about least-privilege and environment separation.
