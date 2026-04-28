# 3-Tier App on AWS EKS

## Architecture

```
Internet
   │
   ▼
AWS ALB (Ingress)
   │
   ▼
Frontend (Nginx) ──► Backend (Node.js) ──► RDS PostgreSQL
   EKS Pod              EKS Pod              Private Subnet
```

**AWS Resources created by Terraform:**
- VPC with public/private subnets across 2 AZs
- EKS cluster (managed node group, t3.medium × 2)
- RDS PostgreSQL (db.t3.micro, private subnet)
- ECR repositories (frontend + backend)
- IAM OIDC provider + GitHub Actions role (no long-lived keys)
- S3 bucket for Terraform state

---

## Setup Steps

### 1. Prerequisites
```bash
brew install terraform awscli kubectl
```

### 2. Configure AWS credentials
```bash
aws configure
# Enter your Access Key ID and Secret Access Key
```

### 3. Create Terraform state bucket (once)
```bash
cd terraform
chmod +x bootstrap.sh && ./bootstrap.sh
```

### 4. Deploy infrastructure
```bash
cd terraform
terraform init
terraform plan
terraform apply
```

### 5. Get outputs
```bash
terraform output github_actions_role_arn   # → add to GitHub secret AWS_ROLE_ARN
terraform output rds_endpoint              # → use for db-secret below
```

### 6. Create DB secret in EKS
```bash
aws eks update-kubeconfig --region us-east-1 --name 3-tier-app-cluster

kubectl apply -f k8s/namespace.yaml

kubectl create secret generic db-secret \
  --from-literal=host=$(terraform output -raw rds_endpoint) \
  --from-literal=password=ChangeMe123! \
  -n app
```

### 7. Add GitHub Secrets
In your GitHub repo → Settings → Secrets → Actions:
| Secret | Value |
|--------|-------|
| `AWS_ROLE_ARN` | output from `terraform output github_actions_role_arn` |

### 8. Push to main → auto deploys
```bash
git add . && git commit -m "initial" && git push origin main
```

---

## Folder Structure
```
3-tier-app/
├── terraform/          # AWS infrastructure (EKS, RDS, ECR, IAM)
├── app/
│   ├── frontend/       # Nginx + HTML
│   └── backend/        # Node.js + Express + PostgreSQL
├── k8s/
│   ├── namespace.yaml
│   ├── frontend/       # Deployment + Service + Ingress
│   ├── backend/        # Deployment + Service
│   └── database/       # Secret reference
└── .github/workflows/  # CI/CD pipeline
```
