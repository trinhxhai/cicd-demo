## Interview Focus for Your Project

Since your project is an Nx monorepo with multiple services and planned AWS deployment, interviewers will usually test 3 things:

- Do you understand CI/CD mechanics (build, test, deploy, rollback)?
- Do you understand deployment architecture (containers, Kubernetes/EKS, networking, scaling)?
- Can you explain your tradeoffs and decisions clearly from your own project?

## Good Interview Questions (Practice These)

### CI/CD Fundamentals

- What is the difference between CI and CD?
- What stages are in your pipeline, and why that order?
- How do you prevent broken code from reaching production?
- What is the difference between build once, deploy many vs rebuilding per environment?
- How do you handle secrets in CI/CD safely?

### Monorepo + Nx Questions

- Why did you choose a monorepo for this system?
- How does Nx help speed up CI (affected projects, caching, parallelism)?
- How do you avoid running all tests for every PR?
- What are the risks of monorepo CI and how do you mitigate them?

### Docker + Kubernetes / EKS

- How do you package each service for deployment?
- What is the difference between Deployment, Service, Ingress in Kubernetes?
- How do services communicate inside the cluster?
- How do you do health checks (liveness vs readiness)?
- How do you handle rolling updates and zero-downtime deploys?

### Reliability / Operations

- How do you monitor app health after deployment?
- What metrics matter most (latency, error rate, saturation, throughput)?
- How do you do rollback if deployment fails?
- What is your strategy for incident response?
- What causes cascading failure in microservices, and how do you reduce it?

### Security

- How do you secure container images and dependencies?
- Where are secrets stored (not in repo), and how are they injected?
- How do you control access (IAM roles, least privilege)?
- How do you secure service-to-service traffic and API endpoints?

### Cost & Scaling

- When do you scale horizontally vs vertically?
- How does autoscaling work in your setup?
- What are common EKS cost drivers, and how do you optimize them?
- How do you choose request/limit values for pods?

## Concepts You Must Understand Deeply

- Pipeline design: lint, test, build, image scan, deploy, smoke test, promote
- Artifact strategy: immutable Docker image tags, traceability to commit SHA
- Environment strategy: dev/staging/prod parity, config via env vars, not code changes
- K8s basics: pods, deployments, services, configmaps, secrets, ingress
- Progressive delivery: rolling updates, canary/blue-green basics
- Observability: logs, metrics, traces, alerting thresholds
- Failure handling: retries, timeouts, circuit breaker concepts, rollback triggers
- GitOps/IaC thinking: Terraform state, reproducible infra, drift awareness
- Nx-specific CI optimization: affected graph, remote cache, run-many/affected
- Testing in CI: unit, integration, e2e, smoke tests after deploy

## Project-Specific Story You Should Prepare

You should be able to explain this clearly in 2-3 minutes:

- System has multiple services (web -> nest -> express -> python), why this design
- How requests flow end-to-end, where failures can happen
- How CI validates changes in a monorepo without wasting time
- How CD deploys each service safely to EKS
- What happened when something failed, and what you changed after learning

Interviewers love concrete examples more than theory.

## High-Impact Questions You Can Ask Interviewers

- How do you structure deployment approvals for production?
- What does your rollback process look like in practice?
- How do you measure CI/CD effectiveness (lead time, failure rate, MTTR)?
- How do you balance fast delivery with reliability and compliance?
- What are your biggest current pain points in deployment?

## Quick Prep Checklist (Before Interview)

- Be ready to draw your architecture in 60 seconds
- Be ready to explain one deployment failure and your fix
- Know 3 KPIs: deployment frequency, change failure rate, MTTR
- Know one security improvement and one cost optimization from your setup
- Practice answering with: problem -> decision -> tradeoff -> result

If you want, I can run a mock interview with 10 realistic CI/CD + EKS questions and then grade your answers like an interviewer.
