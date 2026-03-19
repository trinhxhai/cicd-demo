# EKS & Kubernetes — From Zero to Deployed

This document explains Kubernetes and Amazon EKS from scratch: what problems they solve, how they work internally, and exactly how they are used in this project. No prior container orchestration knowledge assumed.

---

## 1. The Problem: Why Kubernetes Exists

You built 4 services. You containerized them with Docker. Now you have 4 Docker images. You need to run them somewhere in the cloud.

The naive approach: SSH into an EC2 server, run `docker run` for each service, done.

This works until it doesn't. Here's what breaks:

**Services crash.** Docker doesn't restart a crashed container automatically (by default). You need someone — or something — watching and restarting. At 3am.

**Traffic spikes.** Your `api-nest` gets 10x the normal load. You want to spin up 3 more copies. With raw Docker, you SSH in and run 3 more `docker run` commands — manually, one server at a time.

**Server dies.** Your EC2 instance goes down. Everything running on it is gone. You need to move all containers to another server. Manually.

**Deployments are risky.** You push a new version. If it's broken, you need to roll back. With raw Docker you're juggling running containers by hand.

**Networking is a mess.** Service A needs to talk to Service B. Service B might be on a different server, might have 3 replicas, might move to a new IP. Hardcoding IPs breaks constantly.

Kubernetes solves all of these. It's a **container orchestration system** — a system that manages where containers run, keeps them running, scales them up/down, routes traffic between them, and handles deployments safely.

---

## 2. The Core Mental Model

Before diving into objects and YAML, get this mental model right:

**You describe what you want. Kubernetes makes it happen.**

You don't say "start a container on server 3". You say "I want 2 copies of this container running at all times". Kubernetes figures out which servers have capacity, places the containers, and if one dies, it places a replacement. You declared the desired state. Kubernetes continuously reconciles actual state toward desired state.

This is called **declarative infrastructure**. It's the opposite of imperative scripts that say "do this, then do that".

---

## 3. Kubernetes Architecture

A Kubernetes cluster has two types of machines:

```
┌─────────────────────────────────────────────────┐
│                  CONTROL PLANE                   │
│  (the brain — you don't run your apps here)      │
│                                                  │
│  ┌──────────────┐  ┌────────────┐  ┌──────────┐ │
│  │ API Server   │  │ Scheduler  │  │  etcd    │ │
│  │ (front door) │  │ (placer)   │  │  (state) │ │
│  └──────────────┘  └────────────┘  └──────────┘ │
└─────────────────────────────────────────────────┘

┌───────────────┐  ┌───────────────┐  ┌───────────────┐
│   WORKER NODE │  │   WORKER NODE │  │   WORKER NODE │
│               │  │               │  │               │
│  ┌──────────┐ │  │  ┌──────────┐ │  │  ┌──────────┐ │
│  │  Pod     │ │  │  │  Pod     │ │  │  │  Pod     │ │
│  │ (your    │ │  │  │ (your    │ │  │  │ (your    │ │
│  │  app)    │ │  │  │  app)    │ │  │  │  app)    │ │
│  └──────────┘ │  │  └──────────┘ │  │  └──────────┘ │
│  kubelet      │  │  kubelet      │  │  kubelet      │
└───────────────┘  └───────────────┘  └───────────────┘
```

**Control Plane components:**

- **API Server** — the single entry point for all commands. When you run `kubectl apply`, you're talking to the API server. It validates and stores your desired state.
- **etcd** — a distributed key-value store. This is where Kubernetes stores everything: desired state, actual state, config. If etcd is lost, the cluster is lost.
- **Scheduler** — watches for new Pods that aren't assigned to a node yet, and picks which node to place them on (based on resource availability, constraints, etc).
- **Controller Manager** — runs a collection of controllers. Each controller watches one type of object and reconciles actual state toward desired state. The ReplicaSet controller ensures the right number of Pod replicas are running. The Node controller monitors node health.

**Worker Node components:**

- **kubelet** — an agent running on every worker node. It receives instructions from the control plane ("run this Pod") and makes them happen by telling the container runtime to start containers.
- **kube-proxy** — handles networking rules on each node so that Pods can reach each other across nodes.
- **Container Runtime** — actually runs containers. Usually containerd. This is the layer that calls the equivalent of `docker run`.

---

## 4. Core Kubernetes Objects

These are the building blocks you'll write YAML for.

### Pod

The smallest deployable unit. A Pod wraps one or more containers that share a network namespace (same IP) and can share storage volumes.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: api-nest-pod
spec:
  containers:
    - name: api-nest
      image: my-registry/api-nest:v1.2.3
      ports:
        - containerPort: 3000
      env:
        - name: EXPRESS_URL
          value: "http://api-express-svc:3001"
```

**You almost never create Pods directly.** If a Pod dies, it stays dead — nothing recreates it. You use a Deployment instead, which manages Pods for you.

---

### Deployment

Manages a set of identical Pods. You tell it: "run 3 replicas of this Pod spec". It creates a ReplicaSet, which creates the actual Pods. If a Pod crashes, the ReplicaSet controller creates a replacement.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-nest
spec:
  replicas: 3
  selector:
    matchLabels:
      app: api-nest
  template:
    metadata:
      labels:
        app: api-nest
    spec:
      containers:
        - name: api-nest
          image: my-registry/api-nest:v1.2.3
          ports:
            - containerPort: 3000
```

**Rolling updates.** When you update the image tag, Kubernetes spins up new Pods with the new image one at a time, waits for them to become ready, then terminates old Pods. Zero downtime by default.

**Rollback.** `kubectl rollout undo deployment/api-nest` — Kubernetes keeps the previous ReplicaSet around specifically to enable this.

---

### Service

Pods are ephemeral — they get new IPs when recreated. A Service is a stable network endpoint that routes traffic to matching Pods.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: api-nest-svc
spec:
  selector:
    app: api-nest       # routes to all Pods with this label
  ports:
    - port: 3000
      targetPort: 3000
  type: ClusterIP       # only reachable within the cluster
```

Service types:
- **ClusterIP** (default) — a stable virtual IP only reachable inside the cluster. Inter-service communication uses this.
- **NodePort** — exposes the service on a port on every node's IP. Useful for debugging, not for production.
- **LoadBalancer** — provisions a cloud load balancer (an AWS ELB in our case) with a public IP. Used for services that need to receive external traffic.

**DNS.** Kubernetes runs a DNS server inside the cluster (CoreDNS). Every Service gets a DNS name: `<service-name>.<namespace>.svc.cluster.local`. The short form `<service-name>` works within the same namespace. This is why you can set `EXPRESS_URL=http://api-express-svc:3001` and it just works.

---

### Namespace

A logical partition within a cluster. Objects in different namespaces are isolated from each other (by default). Useful for separating environments (staging/production) or teams on a shared cluster.

```
default       ← where objects go if you don't specify
kube-system   ← Kubernetes system components
kube-public   ← publicly readable data
```

---

### ConfigMap & Secret

**ConfigMap** — stores non-sensitive configuration as key-value pairs. Mounted into Pods as env vars or files.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
data:
  EXPRESS_URL: "http://api-express-svc:3001"
  PYTHON_URL: "http://api-python-svc:8000"
```

**Secret** — same structure but base64-encoded and treated with more care (separate RBAC, not logged). Used for passwords, API keys, TLS certs.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-credentials
type: Opaque
data:
  password: c3VwZXJzZWNyZXQ=   # base64 encoded
```

> Note: base64 is encoding, not encryption. Secrets are only as secure as your cluster's RBAC policies. For real secret management, use AWS Secrets Manager or HashiCorp Vault and inject at runtime.

---

### Ingress

An HTTP routing layer that sits in front of multiple Services. One external load balancer, many services routed by hostname or path.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: main-ingress
spec:
  rules:
    - host: api.example.com
      http:
        paths:
          - path: /nest
            pathType: Prefix
            backend:
              service:
                name: api-nest-svc
                port:
                  number: 3000
          - path: /express
            pathType: Prefix
            backend:
              service:
                name: api-express-svc
                port:
                  number: 3001
```

Requires an **Ingress Controller** — a Pod that watches Ingress objects and configures a load balancer accordingly. On EKS, the AWS Load Balancer Controller does this and provisions ALBs.

---

### HorizontalPodAutoscaler (HPA)

Automatically scales the number of Pod replicas based on CPU/memory usage (or custom metrics).

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: api-nest-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: api-nest
  minReplicas: 2
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
```

When average CPU across all `api-nest` Pods exceeds 70%, HPA adds more replicas. When it drops, HPA scales back down (respecting `minReplicas`).

---

## 5. What EKS Is

**EKS (Elastic Kubernetes Service)** is Kubernetes with the control plane managed by AWS.

Running Kubernetes yourself means managing etcd, the API server, the controller manager, their upgrades, their HA setup, their backups. That's a serious operational burden.

EKS removes that burden: AWS runs the control plane for you, across multiple availability zones, with automatic upgrades available. You pay ~$0.10/hour for the control plane, then pay for the EC2 instances (worker nodes) that run your workloads.

```
┌──────────────────────────────────────────────────────┐
│                    AWS ACCOUNT                        │
│                                                       │
│  ┌─────────────────────────────────────────────────┐  │
│  │              EKS CONTROL PLANE (AWS managed)    │  │
│  │   API Server  |  Scheduler  |  etcd             │  │
│  └─────────────────────────────────────────────────┘  │
│                          │                            │
│  ┌─────────────────────────────────────────────────┐  │
│  │                    VPC                          │  │
│  │                                                 │  │
│  │  ┌──────────────┐    ┌──────────────┐           │  │
│  │  │  Worker Node │    │  Worker Node │           │  │
│  │  │  (EC2)       │    │  (EC2)       │           │  │
│  │  └──────────────┘    └──────────────┘           │  │
│  └─────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────┘
```

**Node Groups.** EKS worker nodes are grouped into Node Groups — sets of EC2 instances with the same type and configuration. You can have multiple node groups (e.g., one for general workloads, one with GPU instances for ML).

**Fargate.** Instead of managing EC2 instances, you can use EKS Fargate: AWS provisions the exact compute needed for each Pod on demand, billed per second. No node management at all. Trade-off: less control, higher per-unit cost, some Kubernetes features don't apply.

---

## 6. Key AWS Integrations

EKS isn't just "Kubernetes in AWS" — it integrates deeply with AWS services.

### IAM for Service Accounts (IRSA)

Pods often need to call AWS APIs (read from S3, publish to SQS, etc). The traditional approach is to put AWS credentials in a Secret — fragile and a security risk.

IRSA lets you attach an IAM role to a Kubernetes ServiceAccount. Pods using that ServiceAccount automatically receive short-lived AWS credentials via the Pod's token. No hardcoded credentials.

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: s3-reader
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::123456789:role/s3-read-role
```

### AWS Load Balancer Controller

When you create a Service of type `LoadBalancer` or an Ingress, the AWS Load Balancer Controller provisions actual AWS load balancers (NLB for Services, ALB for Ingress) and keeps them in sync with your Kubernetes objects.

### EBS CSI Driver

Allows Pods to use Amazon EBS volumes as PersistentVolumes. Databases (Postgres, Redis) running on EKS use this to persist data.

### VPC CNI

The networking plugin that gives each Pod a real VPC IP address. Pods are first-class citizens in your VPC — no overlay network, no NAT. Pods can be directly addressed from other VPC resources.

---

## 7. kubectl — The CLI

`kubectl` is the command-line tool for interacting with Kubernetes. It talks to the API server.

```bash
# Apply a manifest (create or update)
kubectl apply -f deployment.yaml
kubectl apply -f k8s/          # apply all files in a directory

# View objects
kubectl get pods
kubectl get pods -n kube-system         # in a specific namespace
kubectl get deployments
kubectl get all                          # everything in the current namespace

# Describe an object (detailed info + events)
kubectl describe pod api-nest-abc123

# Logs
kubectl logs api-nest-abc123
kubectl logs -f api-nest-abc123          # follow (like tail -f)
kubectl logs -f deployment/api-nest      # logs from any pod in the deployment

# Exec into a running container
kubectl exec -it api-nest-abc123 -- /bin/sh

# Port forward (access a Pod locally without exposing it externally)
kubectl port-forward pod/api-nest-abc123 3000:3000
kubectl port-forward svc/api-nest-svc 3000:3000

# Rollout management
kubectl rollout status deployment/api-nest
kubectl rollout undo deployment/api-nest
kubectl rollout history deployment/api-nest

# Scale manually
kubectl scale deployment api-nest --replicas=5

# Delete
kubectl delete -f deployment.yaml
kubectl delete pod api-nest-abc123
```

**Contexts.** kubectl uses "contexts" to know which cluster to talk to. A context bundles a cluster, a user, and a namespace.

```bash
kubectl config get-contexts          # list all contexts
kubectl config use-context my-eks    # switch to a context
```

EKS configures your kubeconfig automatically:
```bash
aws eks update-kubeconfig --region us-east-1 --name my-cluster
```

---

## 8. How Deployments Work In This Project

The project's CI/CD pipeline (GitHub Actions) automates the full deploy flow:

```
Code pushed to main
        │
        ▼
GitHub Actions triggers
        │
        ▼
Build Docker images for changed services (NX affected)
        │
        ▼
Push images to Amazon ECR (Elastic Container Registry)
   my-account.dkr.ecr.us-east-1.amazonaws.com/api-nest:git-sha
        │
        ▼
Update Kubernetes Deployment manifests with new image tag
        │
        ▼
kubectl apply (or Helm upgrade) to EKS
        │
        ▼
Kubernetes rolling update: new pods up, old pods down
        │
        ▼
Health checks pass → deployment complete
```

**Image tagging strategy.** Images are tagged with the git commit SHA (`v1.2.3-abc1234`). This makes every deployed version traceable back to exact source code. Never use `latest` in production — it makes rollbacks ambiguous.

---

## 9. Resource Requests and Limits

Every container should declare how much CPU and memory it needs.

```yaml
containers:
  - name: api-nest
    image: my-registry/api-nest:v1
    resources:
      requests:
        memory: "128Mi"
        cpu: "250m"       # 250 millicores = 0.25 CPU cores
      limits:
        memory: "256Mi"
        cpu: "500m"
```

**Requests** — the amount the scheduler uses to decide where to place the Pod. A node with 1 CPU can fit 4 Pods each requesting 250m.

**Limits** — the maximum the container can use. If it tries to use more CPU than its limit, it gets throttled. If it uses more memory than its limit, it gets killed (OOMKilled) and restarted.

Setting neither means the container can consume all available resources on the node — starving other Pods. Always set both.

---

## 10. Health Checks: Liveness and Readiness Probes

Kubernetes needs to know if your app is healthy.

```yaml
containers:
  - name: api-nest
    image: my-registry/api-nest:v1
    livenessProbe:
      httpGet:
        path: /health
        port: 3000
      initialDelaySeconds: 10
      periodSeconds: 15
    readinessProbe:
      httpGet:
        path: /ready
        port: 3000
      initialDelaySeconds: 5
      periodSeconds: 10
```

**Liveness probe** — "Is this container still alive?" If it fails repeatedly, Kubernetes restarts the container. Use for detecting deadlocks or infinite loops.

**Readiness probe** — "Is this container ready to receive traffic?" If it fails, the Pod is removed from the Service's endpoint list (no more traffic). The container is NOT restarted. Use for startup time and dependency checks (database not ready yet, etc).

**Startup probe** — optional third probe for slow-starting apps. Disables liveness/readiness until the app has started. Prevents premature restarts during boot.

---

## 11. Common Failure Patterns and How to Debug

### CrashLoopBackOff

The container starts, crashes, Kubernetes restarts it, it crashes again. Kubernetes adds exponential backoff delays between restarts.

```bash
kubectl describe pod <pod-name>   # look at the Events section
kubectl logs <pod-name> --previous  # logs from the crashed container
```

Usual causes: bad env var, missing dependency, uncaught exception on startup.

### ImagePullBackOff / ErrImagePull

Kubernetes can't pull the container image.

```bash
kubectl describe pod <pod-name>   # look at Events for the exact error
```

Usual causes: wrong image name/tag, ECR auth not configured, image doesn't exist.

### Pending Pod

Pod is created but not scheduled to any node.

```bash
kubectl describe pod <pod-name>   # look for "Insufficient cpu" or similar
```

Usual causes: not enough resources on any node, node selector/affinity rules don't match any node, too many Pods for your node group.

### OOMKilled

Container exceeded its memory limit and was killed.

```bash
kubectl describe pod <pod-name>   # look for "OOMKilled" in Last State
```

Fix: increase the memory limit, or find and fix the memory leak.

---

## 12. Helm — Kubernetes Package Manager

Kubernetes manifests are verbose. Deploying 4 services means writing nearly identical YAML for each one — Deployment, Service, HPA, ConfigMap, etc. Helm templatizes this.

A **Helm Chart** is a directory of YAML templates with a `values.yaml` file:

```
my-service/
├── Chart.yaml          # chart metadata
├── values.yaml         # default values
└── templates/
    ├── deployment.yaml
    ├── service.yaml
    └── hpa.yaml
```

`deployment.yaml` template:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Values.name }}
spec:
  replicas: {{ .Values.replicas }}
  template:
    spec:
      containers:
        - name: {{ .Values.name }}
          image: {{ .Values.image.repository }}:{{ .Values.image.tag }}
```

Install/upgrade:
```bash
helm install api-nest ./my-service -f values-api-nest.yaml
helm upgrade api-nest ./my-service --set image.tag=abc1234
```

Helm also tracks release history, enabling:
```bash
helm rollback api-nest 1    # roll back to revision 1
```

---

## 13. Terminology Cheatsheet

| Term | What it is |
|------|-----------|
| **Cluster** | The whole Kubernetes system: control plane + worker nodes |
| **Node** | A single server (EC2 instance) in the cluster |
| **Pod** | One or more containers that share a network and storage |
| **Deployment** | Manages a set of identical Pods, handles rolling updates |
| **ReplicaSet** | Ensures N copies of a Pod are running (usually managed by Deployment) |
| **Service** | Stable DNS name + IP that routes traffic to a set of Pods |
| **Ingress** | HTTP routing rules (host/path → Service) |
| **ConfigMap** | Non-sensitive config key-value pairs |
| **Secret** | Sensitive config (passwords, tokens) — base64 encoded |
| **Namespace** | Logical partition within a cluster |
| **HPA** | Automatically scales replica count based on metrics |
| **PersistentVolume** | A piece of storage provisioned in the cluster |
| **PersistentVolumeClaim** | A Pod's request for storage |
| **ServiceAccount** | An identity for a Pod (used for IRSA / AWS IAM) |
| **Node Group** | A set of EC2 instances with the same config in EKS |
| **ECR** | Amazon Elastic Container Registry — Docker image storage |
| **ALB** | Application Load Balancer — HTTP/HTTPS load balancer in AWS |
| **IRSA** | IAM Roles for Service Accounts — AWS auth for Pods |
| **kubeconfig** | Local file that tells kubectl which cluster to connect to |
| **kubectl** | The CLI for interacting with a Kubernetes cluster |
| **Helm** | Kubernetes package manager — templates for manifests |
| **etcd** | The distributed database where Kubernetes stores all state |
| **kubelet** | The agent on each worker node that runs Pods |

---

## 14. Learning Path: What to Do Next

1. **Run it locally first.** Install [minikube](https://minikube.sigs.k8s.io/) or [kind](https://kind.sigs.k8s.io/). Deploy a simple app. `kubectl get pods` and watch it come alive.

2. **Read the Kubernetes docs on Deployments and Services.** The official docs are excellent and beginner-friendly: https://kubernetes.io/docs/concepts/

3. **Study this project's k8s manifests.** Look in the `k8s/` directory. Every file corresponds to a concept in this guide.

4. **Follow the Phase 2 plan.** See `docs/superpowers/plans/2026-03-17-phase2-cicd-eks.md` for how EKS is used in this project end-to-end.

5. **Break things on purpose.** Kill a Pod (`kubectl delete pod ...`) and watch it come back. Scale a Deployment to 0. Trigger a rollback. Learning Kubernetes by watching it recover is the fastest path to understanding it.

---

*Last updated: 2026-03-19*
