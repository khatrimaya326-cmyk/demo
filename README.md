# 3-Tier App — CI/CD with GitHub Actions + ArgoCD

## Architecture

```
Developer pushes code to main
        ↓
GitHub Actions CI (ci.yml)
  → builds Docker images
  → pushes to AWS ECR
  → triggers CD workflow
        ↓
GitHub Actions CD (cd.yml)
  → updates k8s manifests in deploy-dev branch
  → commits & pushes
        ↓
ArgoCD watches deploy-dev branch
  → detects change
  → syncs to EKS cluster
        ↓
App deployed
```

---

## Project Structure

```
demo/
├── app/
│   ├── backend/        # Node.js + Express + PostgreSQL
│   │   ├── Dockerfile
│   │   ├── server.js
│   │   └── package.json
│   └── frontend/       # Nginx + HTML
│       ├── Dockerfile
│       ├── index.html
│       └── nginx.conf
├── k8s/                # Kubernetes manifests (on main branch)
│   ├── namespace.yaml
│   ├── backend/deployment.yaml
│   ├── frontend/deployment.yaml
│   └── database/secret.yaml
├── .github/workflows/
│   ├── ci.yml          # Build & push images to ECR
│   └── cd.yml          # Update manifests in deploy-dev
└── terraform/          # AWS infrastructure (optional)
```

**deploy-dev branch** (separate, only manifests):
```
k8s/
├── namespace.yaml
├── backend/deployment.yaml
└── frontend/deployment.yaml
```

---

## Setup

### 1. Prerequisites

- AWS account with EKS cluster running
- ECR repositories created: `demo/backend` and `demo/frontend`
- ArgoCD installed on the cluster

### 2. GitHub Secrets

Add these in **Settings → Secrets → Actions**:

| Secret | Value |
|---|---|
| `AWS_ACCOUNT_ID` | Your 12-digit AWS account ID |
| `AWS_ROLE_ARN` | IAM role ARN for GitHub OIDC (with ECR push permissions) |

### 3. Create deploy-dev Branch

The `deploy-dev` branch already exists with only k8s manifests. ArgoCD watches this branch.

### 4. Configure ArgoCD Application

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: demo-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/your-org/demo.git
    targetRevision: deploy-dev
    path: k8s
  destination:
    server: https://kubernetes.default.svc
    namespace: app
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

---

## How It Works

### When you push code to `main`:

1. **CI workflow (`ci.yml`)** triggers:
   - Builds backend Docker image
   - Builds frontend Docker image
   - Pushes both to ECR with tag = short git SHA (e.g. `a1b2c3d4`)
   - Triggers CD workflow

2. **CD workflow (`cd.yml`)** runs:
   - Checks out `deploy-dev` branch
   - Updates `k8s/backend/deployment.yaml` image tag
   - Updates `k8s/frontend/deployment.yaml` image tag
   - Commits and pushes to `deploy-dev`

3. **ArgoCD** detects the change:
   - Syncs the new manifests
   - Deploys updated images to EKS

---

## Manual Deployment (First Time)

If deploying manually before CI/CD is set up:

```bash
# 1. Login to ECR
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin <account-id>.dkr.ecr.us-east-1.amazonaws.com

# 2. Build & push images
cd app/backend
docker build -t <account-id>.dkr.ecr.us-east-1.amazonaws.com/demo/backend:v1 .
docker push <account-id>.dkr.ecr.us-east-1.amazonaws.com/demo/backend:v1

cd ../frontend
docker build -t <account-id>.dkr.ecr.us-east-1.amazonaws.com/demo/frontend:v1 .
docker push <account-id>.dkr.ecr.us-east-1.amazonaws.com/demo/frontend:v1

# 3. Update manifests in deploy-dev branch
git checkout deploy-dev
# Edit k8s/backend/deployment.yaml and k8s/frontend/deployment.yaml with :v1 tag
git commit -am "deploy: v1"
git push origin deploy-dev

# 4. ArgoCD will sync automatically
```

---

## Troubleshooting

| Issue | Fix |
|---|---|
| CI fails at ECR login | Check `AWS_ROLE_ARN` secret is correct and role has ECR permissions |
| CD fails to push to deploy-dev | Ensure `GITHUB_TOKEN` has write permissions (default should work) |
| ArgoCD not syncing | Check ArgoCD app is pointing to `deploy-dev` branch and `k8s/` path |
| Pods CrashLoopBackOff | Check `db-secret` exists in `app` namespace |

---

## Cost Estimate

| Resource | Cost |
|---|---|
| EKS Cluster | ~$0.10/hour |
| 2× t3.medium nodes | ~$0.08/hour |
| ECR storage | ~$0.10/GB/month |
| **Total** | ~$0.18/hour (~$130/month) |

> Delete resources when not in use to save costs.
