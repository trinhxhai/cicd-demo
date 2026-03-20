# How Kubernetes Is Set Up in This Project

A deep dive into every K8s concept used here — what each file does, why it's structured that way, and how the pieces connect.

---

## The Full File Map

```
k8s/
  base/                          ← environment-agnostic configuration
    api-python/
      deployment.yaml
      service.yaml
    api-express/
      deployment.yaml
      service.yaml
    api-nest/
      deployment.yaml
      service.yaml
    web/
      deployment.yaml
      service.yaml
    api-ingress.yaml             ← routes external /api/* traffic
    web-ingress.yaml             ← routes external /* traffic
    kustomization.yaml           ← lists all base resources
  overlays/
    prod/
      kustomization.yaml         ← patches image names with real ECR URIs
```

Each service has exactly two files: a **Deployment** and a **Service**. That's it. This is the minimum needed to run a container in Kubernetes and make it reachable.

---

## Concept 1: Deployment

A Deployment answers: _"How should this container run?"_

Here's `k8s/base/api-nest/deployment.yaml` with every field explained:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-nest          # internal K8s name — used in kubectl commands

spec:
  replicas: 1             # how many pod copies to run (1 = no redundancy)

  selector:
    matchLabels:
      app: api-nest       # this Deployment manages pods with this label

  template:               # blueprint for each pod
    metadata:
      labels:
        app: api-nest     # the label pods get — must match selector above

    spec:
      containers:
        - name: api-nest
          image: api-nest:latest      # placeholder; CI patches this to a real ECR URI
          ports:
            - containerPort: 3000     # what port the process inside listens on

          env:
            - name: EXPRESS_URL
              value: "http://api-express.default.svc.cluster.local:3001"
              # how api-nest finds api-express — K8s internal DNS (explained below)

          readinessProbe:
            httpGet:
              path: /ping
              port: 3000
            initialDelaySeconds: 5    # wait 5s after container starts before probing
            periodSeconds: 10         # check every 10s
            # Pod only receives traffic once this probe passes.
            # During a rolling deploy, old pods stay up until new ones are Ready.

          resources:
            requests:
              cpu: "100m"             # guaranteed minimum (100 millicores = 0.1 CPU)
              memory: "128Mi"         # guaranteed minimum
            limits:
              cpu: "500m"             # hard ceiling (0.5 CPU)
              memory: "256Mi"         # hard ceiling — exceeded = OOMKilled
```

**Key mental model:** A Deployment doesn't run containers directly. It manages a ReplicaSet, which manages Pods. You almost never touch ReplicaSets — the Deployment handles them. When you update the image tag, Kubernetes creates a new ReplicaSet, spins up new pods, waits for them to be Ready, then terminates the old pods. That's a rolling update.

**`requests` vs `limits`:** Requests are used for scheduling — Kubernetes places the pod on a node that has at least this much free. Limits are enforced at runtime — exceed the memory limit and the container is killed (OOMKilled). Setting them both is what lets multiple services share the same nodes without one starving the others.

---

## Concept 2: Service

A Service answers: _"How do other things find this Deployment?"_

Here's `k8s/base/api-nest/service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: api-nest          # the DNS name other pods use to reach this service

spec:
  selector:
    app: api-nest         # routes traffic to pods with this label
  ports:
    - port: 3000          # the port this Service listens on
      targetPort: 3000    # the port on the pod to forward to
```

**Why Services exist:** Pods are ephemeral — they come and go, their IP addresses change. A Service gives you a stable IP and DNS name that outlives any individual pod. When you scale from 1 to 3 replicas, the Service automatically load-balances across all 3.

**The default type is `ClusterIP`** — the Service is only reachable from inside the cluster. This is intentional. The APIs should not be directly exposed to the internet; only the Ingress controller (nginx) has a public IP.

---

## Concept 3: Kubernetes DNS — How Services Talk to Each Other

When `api-nest` needs to call `api-express`, it uses this URL:

```
http://api-express.default.svc.cluster.local:3001
```

This is the full Kubernetes DNS name. Breaking it down:

| Part | Meaning |
|------|---------|
| `api-express` | the Service name (from `metadata.name`) |
| `default` | the namespace (all services here are in the `default` namespace) |
| `svc.cluster.local` | K8s DNS suffix — always the same |
| `:3001` | the port defined in the Service |

Kubernetes has a built-in DNS server (CoreDNS). When a pod makes a DNS query for `api-express.default.svc.cluster.local`, CoreDNS responds with the Service's ClusterIP, and traffic routes to a healthy pod.

**In practice:** Within the same namespace you can often use just the short name (`http://api-express:3001`). The full name is used here for explicitness — it works across namespaces too.

**The echo chain in DNS terms:**

```
web  →  http://api-nest.default.svc.cluster.local:3000
           └─ api-nest  →  http://api-express.default.svc.cluster.local:3001
                               └─ api-express  →  http://api-python.default.svc.cluster.local:8000
```

Each service name exactly matches the `metadata.name` in that service's `service.yaml`.

---

## Concept 4: Ingress

Services with `ClusterIP` are invisible from outside the cluster. Ingress is how external HTTP traffic gets in.

This project uses **Nginx Ingress Controller** — a pod running nginx that watches for Ingress resources and automatically reconfigures itself as a reverse proxy.

There are **two separate Ingress objects** in this project:

### `api-ingress.yaml` — for the three APIs

```yaml
metadata:
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /$2   # strips the prefix

spec:
  ingressClassName: nginx
  rules:
    - http:
        paths:
          - path: /api/nest(/|$)(.*)       # matches /api/nest, /api/nest/, /api/nest/ping
            pathType: ImplementationSpecific
            backend:
              service:
                name: api-nest
                port:
                  number: 3000
```

**How the prefix stripping works:**

The path regex `/api/nest(/|$)(.*)` has two capture groups:
- `$1` = the slash after `nest` (or empty string)
- `$2` = everything after that (e.g. `ping`, `echo/hello`, or empty)

The annotation `rewrite-target: /$2` rewrites the URL before forwarding. So:

| Incoming URL | Forwarded to api-nest as |
|-------------|--------------------------|
| `/api/nest/ping` | `/ping` |
| `/api/nest/` | `/` |
| `/api/nest` | `/` |

The API services don't know they're behind a prefix — they just see normal paths.

### `web-ingress.yaml` — for the web frontend

```yaml
spec:
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix    # catches everything not matched above
            backend:
              service:
                name: web
                port:
                  number: 4000
```

No annotation, no rewrite. The web app receives the full original path (`/`, `/about`, `/contact`).

**Why two separate Ingress objects instead of one?**

The `rewrite-target` annotation applies to every rule in an Ingress object. If web and the APIs were in the same object, the rewrite would corrupt web paths: `/about` → `//about`. Keeping them separate means each gets its own annotation behavior.

**How traffic flows from the internet to a pod:**

```
Browser
  └─ DNS → NLB (AWS Network Load Balancer)   ← auto-created by Nginx Ingress on EKS
                └─ Nginx Ingress Controller pod
                        ├─ /api/nest/* → rewrites URL → api-nest Service → api-nest pod
                        ├─ /api/express/* → rewrites URL → api-express Service → api-express pod
                        ├─ /api/python/* → rewrites URL → api-python Service → api-python pod
                        └─ /* → web Service → web pod
```

---

## Concept 5: Kustomize — Base and Overlay

Kustomize is a tool for managing YAML configuration across environments without duplication.

### The base (`k8s/base/kustomization.yaml`)

```yaml
resources:
  - api-python/deployment.yaml
  - api-python/service.yaml
  - api-express/deployment.yaml
  # ... etc
```

Just a list of all the base files. No modifications — pure shared config.

### The prod overlay (`k8s/overlays/prod/kustomization.yaml`)

```yaml
resources:
  - ../../base      # inherit everything from base

images:
  - name: api-nest
    newName: 123456789.dkr.ecr.us-east-1.amazonaws.com/api-nest
    newTag: abc1234   # git SHA — patched by CI on every deploy
```

The overlay patches the `image:` field in every Deployment that uses `api-nest:latest`, replacing it with the real ECR URI and commit SHA.

**The `kustomize edit set image` command** (run by CI) updates this file:

```bash
kustomize edit set image "api-nest=$ECR_REGISTRY/api-nest:$IMAGE_TAG"
```

After CI runs, `kustomization.yaml` might look like:

```yaml
images:
  - name: api-nest
    newName: 123456789.dkr.ecr.us-east-1.amazonaws.com/api-nest
    newTag: a3f91bc
  - name: api-express
    newName: 123456789.dkr.ecr.us-east-1.amazonaws.com/api-express
    newTag: a3f91bc   # same SHA if both were affected
  - name: api-python
    newName: 123456789.dkr.ecr.us-east-1.amazonaws.com/api-python
    newTag: 7d2e441   # older SHA — api-python wasn't changed this push
```

Notice `api-python` has an older SHA. Kustomize doesn't touch what CI didn't update. The base manifest says `api-python:latest` but the overlay patches it to the last-deployed ECR image.

**Deploying with Kustomize:**

```bash
kubectl apply -k k8s/overlays/prod
```

Kustomize renders the base + overlay into full Kubernetes YAML in memory, then sends it to the cluster. You never apply the base directly — always go through the overlay.

---

## How a Deploy Actually Changes a Running Pod

When you push to `main` and CI updates an image tag, here's what Kubernetes does internally:

1. `kubectl apply -k k8s/overlays/prod` sends the new Deployment spec to the API server
2. The Deployment controller sees the image changed — creates a **new ReplicaSet**
3. New ReplicaSet starts 1 new pod with the new image
4. Kubernetes waits for the `readinessProbe` to pass on the new pod (`GET /ping` returns 200)
5. Once the new pod is Ready, the old pod is terminated
6. Old ReplicaSet is scaled to 0 (kept for rollback history)

This is a **rolling update** — zero downtime if the new pod becomes healthy. If the readiness probe never passes (bad image, app crash), the old pod stays running and the deploy stalls rather than replacing healthy pods with broken ones.

---

## Resource Summary

| File | Kind | Purpose |
|------|------|---------|
| `*/deployment.yaml` | Deployment | Runs the container, defines replicas/resources/health checks |
| `*/service.yaml` | Service | Stable internal DNS name + load balances across pods |
| `api-ingress.yaml` | Ingress | Routes `/api/*` external traffic, strips prefix |
| `web-ingress.yaml` | Ingress | Routes `/*` external traffic, no rewrite |
| `base/kustomization.yaml` | Kustomization | Lists all base resources |
| `overlays/prod/kustomization.yaml` | Kustomization | Patches image tags to real ECR URIs |

---

## What's Intentionally Not Here (and Why)

| Missing | Why it's absent |
|---------|----------------|
| `livenessProbe` | Only `readinessProbe` is defined — a pod that crashes gets restarted by K8s, but a deadlocked pod stays "Running" forever. Production would add a liveness probe. |
| `replicas: 2+` | Single replica = full downtime on pod crash (~30s to reschedule). Fine for learning, not for production. |
| `securityContext` | No `runAsNonRoot`, `readOnlyRootFilesystem`, etc. The Dockerfiles already create non-root users but K8s doesn't enforce it. |
| `NetworkPolicy` | All pods can talk to all pods. The architecture enforces a strict chain (web → nest → express → python) but nothing in K8s prevents other paths. |
| `HorizontalPodAutoscaler` | Fixed replica count — no auto-scaling on load. |
| Namespace isolation | Everything runs in `default`. A real setup would have separate namespaces per environment. |
