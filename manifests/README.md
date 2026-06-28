# manifests/ — what you must produce

This is a **checklist, not an answer key.** The K8s lesson's reference manifests
(`cicd_dockerized/k8s-lesson/manifests/`) target a single-node laptop cluster. Here you
re-author them for real multi-node infra and add the hardening the brief requires.

Produce (raw YAML, a Helm chart, or kustomize overlays — your call):

**App**
- [x] `namespace`
- [x] `ConfigMap` (non-secret) + `Secret` (secret, NOT committed in plaintext — see gitops/ + Sealed Secrets stretch)
- [x] Postgres `StatefulSet` + headless `Service` + PVC on the cluster's storage class
- [x] backend `Deployment` (2+ replicas) + `Service` named **`backend`** (the frontend proxies `/api` → `backend:5000`)
- [x] frontend `Deployment` (2+ replicas) + `Service`
- [x] migration `Job` (run-once) — replicas must NOT migrate
- [x] `Ingress` (+ `api.` host or `/api` path) with cert-manager TLS on your real domain

**Make it production, not a demo**
- [x] `topologySpreadConstraints` / pod anti-affinity so replicas land on different nodes
- [x] probes (startup/readiness/liveness) + `resources.requests`/`limits` on every container
- [x] `strategy.rollingUpdate.maxUnavailable: 0`
- [x] pinned image tags (no `:latest`)
- [x] ≥3 Advanced: HPA / NetworkPolicy / PDB+graceful-shutdown / observability / securityContext

**Platform (install once, document how):**
- [x] ingress controller, cert-manager + ClusterIssuer, metrics-server, Argo CD

Every box you tick must have matching evidence in `docs/EVIDENCE/`.
