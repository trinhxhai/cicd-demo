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

### Gaps / Uncertainties

- Environment-based `sub` pattern specifics if deployments are tied to GitHub Environments.
- Best production policy pattern for multiple branches/tags without over-broad trust.
- Whether additional condition keys are needed for this repo's exact branching model.
- Whether this project should tighten trust from `repo:<owner>/<repo>:*` to main/environment-specific subjects.

## Questions Asked

- 2026-03-20: Authenticate to AWS using OIDC, how it works, and setup on GitHub + AWS.
- 2026-03-20: Write the answer based on what this project already implements.
- 2026-03-20: Where are the role name and permissions defined in this project?

## Q&A Log

### Q: Authenticate to AWS using OIDC - how it work and step to set up at each side, github and aws?

A: OIDC lets GitHub Actions exchange a short-lived identity token for temporary AWS credentials, so you do not store long-lived AWS keys in GitHub. Setup is: (1) in AWS, create IAM OIDC provider (`token.actions.githubusercontent.com`, audience `sts.amazonaws.com`), create IAM role with trust policy restricted by `aud` and `sub`, and attach least-privilege permissions; (2) in GitHub workflow, grant `permissions: id-token: write`, run `aws-actions/configure-aws-credentials` with `role-to-assume`, then execute AWS commands. The key security control is strict `sub` matching (repo + branch/tag/environment) in the role trust policy.

- Confidence: high
- Reasoning: This follows the standard GitHub Actions OIDC federation model to AWS STS and aligns with official trust policy patterns (`aud` + `sub` conditions).
- Related concepts: OIDC, JWT, AWS STS, AssumeRoleWithWebIdentity, IAM trust policy, least privilege

### Q: Please write answer based on what this project already implement

A: In this project, OIDC auth is already implemented end-to-end. On GitHub side, the deploy job in `.github/workflows/ci-cd.yml` grants `id-token: write` and uses `aws-actions/configure-aws-credentials@v4` with `role-to-assume: ${{ secrets.AWS_ROLE_ARN }}` and `aws-region: ${{ secrets.AWS_REGION }}`. Deployment only runs on push to `main` or manual dispatch (`workflow_dispatch`). On AWS side, Terraform in `infra/terraform/iam.tf` creates the GitHub OIDC provider (`https://token.actions.githubusercontent.com`, audience `sts.amazonaws.com`), creates role `github-actions-eks`, and sets trust conditions for `aud == sts.amazonaws.com` plus `sub` matching `repo:${var.github_repo}:*`. That means any workflow context in this repository can assume the role, while deploy execution is still gated by workflow logic to main/manual runs. The role then gets permissions for ECR image push/pull, `eks:DescribeCluster`, and EKS cluster access via access entry + admin policy association so `kubectl apply` can deploy to the cluster.

- Confidence: high
- Reasoning: The answer is derived directly from existing repo code: `.github/workflows/ci-cd.yml`, `infra/terraform/iam.tf`, and `infra/terraform/variables.tf`.
- Related concepts: GitHub Actions permissions, OIDC provider, IAM role trust policy, Terraform, ECR, EKS access entries

### Q: Where are the role name and permissions defined in this project?

A: They are defined in `infra/terraform/iam.tf`. The role resource is `aws_iam_role.github_actions` with name `github-actions-eks`. Its permissions are attached in the same file: `aws_iam_role_policy_attachment.github_actions_ecr` (ECR push/pull policy), `aws_iam_policy.github_actions_eks_describe` + attachment (permission for `eks:DescribeCluster`), and EKS access resources (`aws_eks_access_entry.github_actions` and `aws_eks_access_policy_association.github_actions_admin`) that grant cluster access for deployment. In GitHub workflow, that role is consumed via `role-to-assume: ${{ secrets.AWS_ROLE_ARN }}` in `.github/workflows/ci-cd.yml`.

- Confidence: high
- Reasoning: The role definition and policy attachments are explicitly declared in Terraform, and the workflow references the role ARN secret directly.
- Related concepts: IAM role, policy attachment, EKS access entry, role-to-assume

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

- How should trust policy be designed for `main` + release tags while staying least-privilege?
- Should deployment be restricted via GitHub Environments and environment-scoped `sub` claims?
- What CloudTrail events should be monitored for OIDC role usage anomalies?

## Revision History

- 2026-03-20: Created and populated topic file with first OIDC AWS authentication Q&A entry.
- 2026-03-20: Added project-implementation-based OIDC explanation from workflow and Terraform files.
- 2026-03-20: Clarified where role name and permissions are defined; added direct Q&A for lookup.
