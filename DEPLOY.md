# Manual Deployment Guide — 3-Tier App on AWS EKS

---

## Prerequisites

Install these tools before starting:

```bash
brew install terraform awscli kubectl helm
```

Verify:
```bash
terraform -v
aws --version
kubectl version --client
```

---

## Step 1 — Configure AWS CLI

```bash
aws configure
```

Enter when prompted:
- **AWS Access Key ID** → your access key
- **AWS Secret Access Key** → your secret key
- **Default region** → `us-east-1`
- **Default output format** → `json`

Verify it works:
```bash
aws sts get-caller-identity
```

---

## Step 2 — Create S3 Bucket for Terraform State

```bash
cd ~/Desktop/3-tier-app/terraform
chmod +x bootstrap.sh
./bootstrap.sh
```

This creates an S3 bucket `3-tier-app-tfstate` with versioning and encryption.

---

## Step 3 — Update terraform.tfvars

Open `terraform/terraform.tfvars` and fill in your values:

```hcl
aws_region   = "us-east-1"
project_name = "3-tier-app"
db_password  = "YourStrongPassword123!"   # change this
github_org   = "your-github-username"
github_repo  = "3-tier-app"
```

---

## Step 4 — Deploy Infrastructure with Terraform

```bash
cd ~/Desktop/3-tier-app/terraform

terraform init
terraform plan
terraform apply
```

Type `yes` when prompted. This takes **10–15 minutes** (EKS cluster creation).

When done, save the outputs:
```bash
terraform output
```

Note down:
- `cluster_name`
- `ecr_frontend_url`
- `ecr_backend_url`
- `rds_endpoint`
- `github_actions_role_arn`

---

## Step 5 — Connect kubectl to EKS

```bash
aws eks update-kubeconfig --region us-east-1 --name 3-tier-app-cluster
```

Verify connection:
```bash
kubectl get nodes
```

You should see 2 nodes in `Ready` state.

---

## Step 6 — Create Namespace and DB Secret

```bash
kubectl apply -f ~/Desktop/3-tier-app/k8s/namespace.yaml
```

Create the database secret (replace values with your RDS endpoint and password):
```bash
kubectl create secret generic db-secret \
  --from-literal=host=$(cd ~/Desktop/3-tier-app/terraform && terraform output -raw rds_endpoint) \
  --from-literal=password=YourStrongPassword123! \
  -n app
```

Verify:
```bash
kubectl get secret db-secret -n app
```

---

## Step 7 — Install AWS Load Balancer Controller

The ALB Ingress requires this controller:

```bash
# Add Helm repo
helm repo add eks https://aws.github.io/eks-charts
helm repo update

# Install controller
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=3-tier-app-cluster \
  --set serviceAccount.create=true \
  --set region=us-east-1 \
  --set vpcId=$(aws eks describe-cluster --name 3-tier-app-cluster \
    --query "cluster.resourcesVpcConfig.vpcId" --output text)
```

---

## Step 8 — Build and Push Docker Images

Get your ECR registry URL:
```bash
ECR_REGISTRY=$(aws sts get-caller-identity --query Account --output text).dkr.ecr.us-east-1.amazonaws.com
echo $ECR_REGISTRY
```

Login to ECR:
```bash
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin $ECR_REGISTRY
```

Build and push **backend**:
```bash
cd ~/Desktop/3-tier-app/app/backend
docker build -t $ECR_REGISTRY/3-tier-app/backend:v1 .
docker push $ECR_REGISTRY/3-tier-app/backend:v1
```

Build and push **frontend**:
```bash
cd ~/Desktop/3-tier-app/app/frontend
docker build -t $ECR_REGISTRY/3-tier-app/frontend:v1 .
docker push $ECR_REGISTRY/3-tier-app/frontend:v1
```

---

## Step 9 — Update K8s Manifests with Image URLs

Replace the placeholder image tags in the manifests:

```bash
# Backend
sed -i '' "s|BACKEND_IMAGE|$ECR_REGISTRY/3-tier-app/backend:v1|g" \
  ~/Desktop/3-tier-app/k8s/backend/deployment.yaml

# Frontend
sed -i '' "s|FRONTEND_IMAGE|$ECR_REGISTRY/3-tier-app/frontend:v1|g" \
  ~/Desktop/3-tier-app/k8s/frontend/deployment.yaml
```

---

## Step 10 — Deploy to EKS

```bash
kubectl apply -f ~/Desktop/3-tier-app/k8s/backend/deployment.yaml
kubectl apply -f ~/Desktop/3-tier-app/k8s/frontend/deployment.yaml
```

Wait for rollout:
```bash
kubectl rollout status deployment/backend  -n app
kubectl rollout status deployment/frontend -n app
```

---

## Step 11 — Verify Everything is Running

```bash
# Check pods
kubectl get pods -n app

# Check services
kubectl get svc -n app

# Check ingress (wait 2-3 mins for ALB to provision)
kubectl get ingress -n app
```

The `ADDRESS` column of the ingress will show your ALB DNS name.

---

## Step 12 — Initialize the Database Table

Exec into the backend pod to create the table:

```bash
POD=$(kubectl get pod -n app -l app=backend -o jsonpath='{.items[0].metadata.name}')

kubectl exec -it $POD -n app -- node -e "
const { Pool } = require('pg');
const pool = new Pool({
  host: process.env.DB_HOST,
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
  database: process.env.DB_NAME
});
pool.query('CREATE TABLE IF NOT EXISTS items (id SERIAL PRIMARY KEY, name TEXT NOT NULL)')
  .then(() => { console.log('Table created'); process.exit(0); })
  .catch(e => { console.error(e); process.exit(1); });
"
```

---

## Step 13 — Access the App

```bash
ALB=$(kubectl get ingress -n app -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}')
echo "App URL: http://$ALB"
```

Open `http://$ALB` in your browser.

Test the API:
```bash
curl http://$ALB/api/items
```

---

## Teardown

```bash
# Delete K8s resources first
kubectl delete namespace app

# Destroy all AWS infrastructure
cd ~/Desktop/3-tier-app/terraform
terraform destroy
```

> ⚠️ This permanently deletes EKS, RDS, ECR images, and VPC.
