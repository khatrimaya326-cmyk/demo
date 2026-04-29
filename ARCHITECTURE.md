# Architecture — 3-Tier App on AWS EKS

## Step 1 — User Makes a Request

```
User (Browser)
     │
     │  https://deepenrich.com
     ▼
  Internet
```

- User opens the app in a browser.
- DNS resolves the domain to the AWS ALB hostname.

---

## Step 2 — Traffic Hits the ALB

```
  Internet
     │
     ▼
┌─────────────────────────────────┐
│  AWS Application Load Balancer  │
│  (internet-facing, port 80/443) │
│  Public Subnets — AZ-a & AZ-b   │
└────────────────┬────────────────┘
```

- ALB lives in the **public subnets** so it is reachable from the internet.
- Created automatically by the **AWS Load Balancer Controller** when the Kubernetes Ingress is applied.
- Routes all `/*` traffic to the frontend service.

---

## Step 3 — ALB Routes to Frontend Pod

```
AWS ALB
  │
  │  Ingress rule: /* → frontend-svc:80
  ▼
┌──────────────────┐
│  frontend-svc    │  (ClusterIP)
│  port 80         │
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│  frontend pod    │
│  nginx           │
│  serves HTML/JS  │
└──────────────────┘
```

- `frontend-svc` is a ClusterIP service — internal only, not exposed to internet directly.
- The pod runs **nginx** serving the static `index.html` and assets.
- All pods run inside **private subnets** — not directly reachable from internet.

---

## Step 4 — Browser Calls the Backend API

```
User Browser (JS)
  │
  │  GET /api/items  →  ALB
  ▼
AWS ALB
  │
  │  Ingress rule: /api/* → backend-svc:3000
  ▼
┌──────────────────┐
│  backend-svc     │  (ClusterIP)
│  port 3000       │
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│  backend pod     │
│  Node.js Express │
│  /api/items      │
│  /health         │
└──────────────────┘
```

- The frontend JavaScript makes API calls to `/api/*`.
- ALB routes these to the **backend service** → **backend pod**.
- Backend reads DB credentials from a Kubernetes Secret (`db-secret`).

---

## Step 5 — Backend Queries the Database

```
backend pod
  │
  │  DB_HOST  → from Kubernetes Secret
  │  DB_PASSWORD → from Kubernetes Secret
  │
  │  SQL query (port 5432)
  ▼
┌──────────────────────────┐
│  RDS PostgreSQL 15        │
│  db.t3.micro              │
│  Private Subnet           │
│  database: appdb          │
│  user: appuser            │
└──────────────────────────┘
```

- RDS is in a **private subnet** — no public internet access.
- Only pods inside the VPC can connect to it.
- Credentials are stored as a Kubernetes Secret, never hardcoded.

---

## Step 6 — Nodes Pull Images from ECR

```
EKS Worker Node
  │
  │  (on pod start — pulls image)
  │  via NAT Gateway → internet → ECR
  ▼
┌──────────────────────────────────┐
│  Amazon ECR                      │
│  3-tier-app/frontend:v1          │
│  3-tier-app/backend:v1           │
└──────────────────────────────────┘
```

- Nodes are in **private subnets** — they use the **NAT Gateway** to reach ECR.
- Images must be built with `--platform linux/amd64` to match the node architecture.

---

## Step 7 — IAM Controls All Permissions

```
┌──────────────────────────────────────────────────┐
│  IAM                                             │
│                                                  │
│  3-tier-eks-cluster-role  →  EKS control plane   │
│  3-tier-eks-node-role     →  EC2 worker nodes    │
│  AmazonEKSLoadBalancerControllerRole             │
│    └─ IRSA (bound to k8s service account)        │
│    └─ allows ALB Controller to create/manage ALB │
└──────────────────────────────────────────────────┘
```

- **IRSA** (IAM Roles for Service Accounts) — the ALB Controller gets its own IAM role via the OIDC provider, not the node role.
- Without IRSA, the controller cannot create or manage the ALB.

---

## Full Picture

```
User
 │
 ▼
Internet
 │
 ▼
┌─────────────────────────────────────────────────────┐
│  VPC  10.0.0.0/16                                   │
│                                                     │
│  Public Subnets (10.0.101.0/24 | 10.0.102.0/24)    │
│  ┌──────────────────────┐  ┌─────────────────────┐  │
│  │  AWS ALB             │  │  NAT Gateway        │  │
│  └──────────┬───────────┘  └──────────┬──────────┘  │
│             │                         │ (outbound)   │
│  Private Subnets (10.0.1.0/24 | 10.0.2.0/24)        │
│  ┌──────────▼───────────────────────────────────┐   │
│  │  EKS Cluster                                 │   │
│  │                                              │   │
│  │  ┌─────────────┐      ┌─────────────────┐   │   │
│  │  │ frontend pod│      │  backend pod    │   │   │
│  │  │ (nginx)     │      │  (Node.js)      │   │   │
│  │  └─────────────┘      └────────┬────────┘   │   │
│  │                                │             │   │
│  └────────────────────────────────┼─────────────┘   │
│                                   │                  │
│  ┌────────────────────────────────▼─────────────┐   │
│  │  RDS PostgreSQL (private subnet)             │   │
│  └──────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────┘
         │                    │
         ▼                    ▼
       ECR                  IAM
  (container images)    (roles & policies)
```

---

## Component Summary

| Component | Details |
|---|---|
| ALB | internet-facing, port 80/443, managed by ALB Controller |
| frontend pod | nginx, 1 replica, serves static HTML/JS |
| backend pod | Node.js Express, 1 replica, `/api/items`, `/health` |
| RDS | PostgreSQL 15, db.t3.micro, private subnet |
| ECR | `3-tier-app/frontend:v1`, `3-tier-app/backend:v1` |
| EKS | Kubernetes 1.29, 3× t3.small nodes, `app` namespace |
| NAT Gateway | outbound internet for private subnet nodes |
| IRSA | ALB Controller IAM role bound via OIDC to k8s service account |
