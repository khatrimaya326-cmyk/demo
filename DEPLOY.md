# Deployment Guide

---

## Automated Deployment (CI/CD)

Push code to `main` — everything happens automatically.

```bash
git add .
git commit -m "your changes"
git push origin main
```

**What happens:**
1. `ci.yml` builds backend + frontend images → pushes to ECR with git SHA tag
2. `cd.yml` updates `deploy-dev` branch manifests with new image tag
3. ArgoCD detects the change → syncs → deploys to EKS

---

## First-Time Setup

### 1. Install Tools

```bash
brew install awscli kubectl helm
```

### 2. Configure AWS CLI

```bash
aws configure
# Enter Access Key ID, Secret Access Key, region: us-east-1, output: json
```

### 3. Connect kubectl to EKS

```bash
aws eks update-kubeconfig --region us-east-1 --name <your-cluster-name>
kubectl get nodes
```

### 4. Create ECR Repositories

```bash
aws ecr create-repository --repository-name demo/frontend --region us-east-1
aws ecr create-repository --repository-name demo/backend  --region us-east-1
```

### 5. Create Namespace and DB Secret

```bash
kubectl apply -f k8s/namespace.yaml

kubectl create secret generic db-secret \
  --from-literal=host=<RDS_ENDPOINT> \
  --from-literal=password=<DB_PASSWORD> \
  -n app
```

### 6. Install AWS Load Balancer Controller

```bash
helm repo add eks https://aws.github.io/eks-charts && helm repo update

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=<your-cluster-name> \
  --set serviceAccount.create=true \
  --set region=us-east-1 \
  --set vpcId=$(aws eks describe-cluster --name <your-cluster-name> \
    --query "cluster.resourcesVpcConfig.vpcId" --output text)
```

### 7. Add GitHub Secrets

Go to **GitHub repo → Settings → Secrets → Actions** and add:

| Secret | Value |
|---|---|
| `AWS_ACCOUNT_ID` | Your 12-digit AWS account ID |
| `AWS_ROLE_ARN` | IAM role ARN with ECR push + EKS access |

### 8. Setup ArgoCD Application

```bash
kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: demo-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/<your-org>/demo.git
    targetRevision: deploy-dev
    path: k8s
  destination:
    server: https://kubernetes.default.svc
    namespace: app
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF
```

### 9. Initialize Database Table (once)

```bash
POD=$(kubectl get pod -n app -l app=backend -o jsonpath='{.items[0].metadata.name}')

kubectl exec -it $POD -n app -- node -e "
const { Pool } = require('pg');
const pool = new Pool({
  host: process.env.DB_HOST, user: process.env.DB_USER,
  password: process.env.DB_PASSWORD, database: process.env.DB_NAME
});
pool.query('CREATE TABLE IF NOT EXISTS items (id SERIAL PRIMARY KEY, name TEXT NOT NULL)')
  .then(() => { console.log('Table created'); process.exit(0); })
  .catch(e => { console.error(e); process.exit(1); });
"
```

### 10. Access the App

```bash
ALB=$(kubectl get ingress -n app -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}')
echo "App URL: http://$ALB"
```

---

## Teardown

```bash
kubectl delete namespace app

aws ecr delete-repository --repository-name demo/frontend --force
aws ecr delete-repository --repository-name demo/backend  --force
```
