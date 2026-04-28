# Manual Deployment Guide — Without Terraform (AWS CLI + kubectl)

All AWS resources are created manually using AWS CLI.

---

## Step 1 — Install Tools

```bash
brew install awscli kubectl helm
```

Configure AWS CLI:
```bash
aws configure
# Enter Access Key, Secret Key, region: us-east-1, output: json
```

Verify:
```bash
aws sts get-caller-identity
```

---

## Step 2 — Create VPC and Networking

```bash
# Create VPC
VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 \
  --query 'Vpc.VpcId' --output text)
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames
aws ec2 create-tags --resources $VPC_ID --tags Key=Name,Value=3-tier-app-vpc
echo "VPC: $VPC_ID"

# Create Internet Gateway
IGW_ID=$(aws ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway --vpc-id $VPC_ID --internet-gateway-id $IGW_ID

# Create public subnets
PUB_SUBNET_1=$(aws ec2 create-subnet --vpc-id $VPC_ID \
  --cidr-block 10.0.101.0/24 --availability-zone us-east-1a \
  --query 'Subnet.SubnetId' --output text)
PUB_SUBNET_2=$(aws ec2 create-subnet --vpc-id $VPC_ID \
  --cidr-block 10.0.102.0/24 --availability-zone us-east-1b \
  --query 'Subnet.SubnetId' --output text)

aws ec2 modify-subnet-attribute --subnet-id $PUB_SUBNET_1 --map-public-ip-on-launch
aws ec2 modify-subnet-attribute --subnet-id $PUB_SUBNET_2 --map-public-ip-on-launch

# Tag subnets for ALB
aws ec2 create-tags --resources $PUB_SUBNET_1 $PUB_SUBNET_2 \
  --tags Key=kubernetes.io/role/elb,Value=1

# Create private subnets
PRIV_SUBNET_1=$(aws ec2 create-subnet --vpc-id $VPC_ID \
  --cidr-block 10.0.1.0/24 --availability-zone us-east-1a \
  --query 'Subnet.SubnetId' --output text)
PRIV_SUBNET_2=$(aws ec2 create-subnet --vpc-id $VPC_ID \
  --cidr-block 10.0.2.0/24 --availability-zone us-east-1b \
  --query 'Subnet.SubnetId' --output text)

aws ec2 create-tags --resources $PRIV_SUBNET_1 $PRIV_SUBNET_2 \
  --tags Key=kubernetes.io/role/internal-elb,Value=1

echo "Public:  $PUB_SUBNET_1  $PUB_SUBNET_2"
echo "Private: $PRIV_SUBNET_1 $PRIV_SUBNET_2"

# Public route table
PUB_RT=$(aws ec2 create-route-table --vpc-id $VPC_ID \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id $PUB_RT \
  --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID
aws ec2 associate-route-table --route-table-id $PUB_RT --subnet-id $PUB_SUBNET_1
aws ec2 associate-route-table --route-table-id $PUB_RT --subnet-id $PUB_SUBNET_2

# NAT Gateway for private subnets
EIP=$(aws ec2 allocate-address --domain vpc --query 'AllocationId' --output text)
NAT_GW=$(aws ec2 create-nat-gateway --subnet-id $PUB_SUBNET_1 \
  --allocation-id $EIP --query 'NatGateway.NatGatewayId' --output text)
echo "Waiting for NAT Gateway..."
aws ec2 wait nat-gateway-available --nat-gateway-ids $NAT_GW

PRIV_RT=$(aws ec2 create-route-table --vpc-id $VPC_ID \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id $PRIV_RT \
  --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $NAT_GW
aws ec2 associate-route-table --route-table-id $PRIV_RT --subnet-id $PRIV_SUBNET_1
aws ec2 associate-route-table --route-table-id $PRIV_RT --subnet-id $PRIV_SUBNET_2
```

---

## Step 3 — Create IAM Roles for EKS

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# EKS Cluster role
aws iam create-role --role-name 3-tier-eks-cluster-role \
  --assume-role-policy-document '{
    "Version":"2012-10-17",
    "Statement":[{"Effect":"Allow","Principal":{"Service":"eks.amazonaws.com"},
    "Action":"sts:AssumeRole"}]}'
aws iam attach-role-policy --role-name 3-tier-eks-cluster-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy

# EKS Node role
aws iam create-role --role-name 3-tier-eks-node-role \
  --assume-role-policy-document '{
    "Version":"2012-10-17",
    "Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},
    "Action":"sts:AssumeRole"}]}'
aws iam attach-role-policy --role-name 3-tier-eks-node-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy
aws iam attach-role-policy --role-name 3-tier-eks-node-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy
aws iam attach-role-policy --role-name 3-tier-eks-node-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
```

---

## Step 4 — Create EKS Cluster

```bash
aws eks create-cluster \
  --name 3-tier-app-cluster \
  --kubernetes-version 1.29 \
  --role-arn arn:aws:iam::${ACCOUNT_ID}:role/3-tier-eks-cluster-role \
  --resources-vpc-config \
    subnetIds=${PRIV_SUBNET_1},${PRIV_SUBNET_2},${PUB_SUBNET_1},${PUB_SUBNET_2},\
endpointPublicAccess=true,endpointPrivateAccess=false

echo "Waiting for EKS cluster (10-15 mins)..."
aws eks wait cluster-active --name 3-tier-app-cluster
echo "Cluster ready!"
```

---

## Step 5 — Create Node Group

```bash
aws eks create-nodegroup \
  --cluster-name 3-tier-app-cluster \
  --nodegroup-name default \
  --node-role arn:aws:iam::${ACCOUNT_ID}:role/3-tier-eks-node-role \
  --subnets $PRIV_SUBNET_1 $PRIV_SUBNET_2 \
  --instance-types t3.medium \
  --scaling-config minSize=2,maxSize=4,desiredSize=2 \
  --ami-type AL2_x86_64

echo "Waiting for nodes (5-10 mins)..."
aws eks wait nodegroup-active --cluster-name 3-tier-app-cluster --nodegroup-name default
echo "Nodes ready!"
```

---

## Step 6 — Connect kubectl

```bash
aws eks update-kubeconfig --region us-east-1 --name 3-tier-app-cluster
kubectl get nodes   # should show 2 Ready nodes
```

---

## Step 7 — Create RDS PostgreSQL

```bash
# Security group for RDS
RDS_SG=$(aws ec2 create-security-group \
  --group-name 3-tier-rds-sg --description "RDS SG" \
  --vpc-id $VPC_ID --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress \
  --group-id $RDS_SG --protocol tcp --port 5432 --cidr 10.0.0.0/16

# Subnet group
aws rds create-db-subnet-group \
  --db-subnet-group-name 3-tier-db-subnet \
  --db-subnet-group-description "3-tier DB subnet" \
  --subnet-ids $PRIV_SUBNET_1 $PRIV_SUBNET_2

# Create RDS instance
aws rds create-db-instance \
  --db-instance-identifier 3-tier-app-db \
  --db-instance-class db.t3.micro \
  --engine postgres \
  --engine-version 15 \
  --master-username appuser \
  --master-user-password YourStrongPassword123! \
  --db-name appdb \
  --db-subnet-group-name 3-tier-db-subnet \
  --vpc-security-group-ids $RDS_SG \
  --no-publicly-accessible \
  --allocated-storage 20

echo "Waiting for RDS (10-15 mins)..."
aws rds wait db-instance-available --db-instance-identifier 3-tier-app-db

RDS_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier 3-tier-app-db \
  --query 'DBInstances[0].Endpoint.Address' --output text)
echo "RDS Endpoint: $RDS_ENDPOINT"
```

---

## Step 8 — Create ECR Repositories

```bash
aws ecr create-repository --repository-name 3-tier-app/frontend --region us-east-1
aws ecr create-repository --repository-name 3-tier-app/backend  --region us-east-1
```

---

## Step 9 — Build & Push Docker Images

```bash
ECR_REGISTRY=${ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com

aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin $ECR_REGISTRY

# Backend
cd ~/Desktop/3-tier-app/app/backend
docker build -t $ECR_REGISTRY/3-tier-app/backend:v1 .
docker push $ECR_REGISTRY/3-tier-app/backend:v1

# Frontend
cd ~/Desktop/3-tier-app/app/frontend
docker build -t $ECR_REGISTRY/3-tier-app/frontend:v1 .
docker push $ECR_REGISTRY/3-tier-app/frontend:v1
```

---

## Step 10 — Create Namespace and DB Secret

```bash
kubectl apply -f ~/Desktop/3-tier-app/k8s/namespace.yaml

kubectl create secret generic db-secret \
  --from-literal=host=$RDS_ENDPOINT \
  --from-literal=password=YourStrongPassword123! \
  -n app
```

---

## Step 11 — Install AWS Load Balancer Controller

```bash
helm repo add eks https://aws.github.io/eks-charts && helm repo update

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=3-tier-app-cluster \
  --set serviceAccount.create=true \
  --set region=us-east-1 \
  --set vpcId=$VPC_ID
```

---

## Step 12 — Deploy to EKS

```bash
ECR_REGISTRY=${ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com

sed -i '' "s|BACKEND_IMAGE|$ECR_REGISTRY/3-tier-app/backend:v1|g" \
  ~/Desktop/3-tier-app/k8s/backend/deployment.yaml
sed -i '' "s|FRONTEND_IMAGE|$ECR_REGISTRY/3-tier-app/frontend:v1|g" \
  ~/Desktop/3-tier-app/k8s/frontend/deployment.yaml

kubectl apply -f ~/Desktop/3-tier-app/k8s/backend/deployment.yaml
kubectl apply -f ~/Desktop/3-tier-app/k8s/frontend/deployment.yaml

kubectl rollout status deployment/backend  -n app
kubectl rollout status deployment/frontend -n app
```

---

## Step 13 — Initialize Database Table

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

---

## Step 14 — Access the App

```bash
# Wait 2-3 mins for ALB, then:
ALB=$(kubectl get ingress -n app -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}')
echo "App URL: http://$ALB"
curl http://$ALB/api/items
```

---

## Teardown

```bash
# K8s resources
kubectl delete namespace app

# EKS
aws eks delete-nodegroup --cluster-name 3-tier-app-cluster --nodegroup-name default
aws eks wait nodegroup-deleted --cluster-name 3-tier-app-cluster --nodegroup-name default
aws eks delete-cluster --name 3-tier-app-cluster

# RDS
aws rds delete-db-instance --db-instance-identifier 3-tier-app-db --skip-final-snapshot

# ECR
aws ecr delete-repository --repository-name 3-tier-app/frontend --force
aws ecr delete-repository --repository-name 3-tier-app/backend  --force

# NAT Gateway & EIP (costs money if left running)
aws ec2 delete-nat-gateway --nat-gateway-id $NAT_GW
aws ec2 release-address --allocation-id $EIP
```
