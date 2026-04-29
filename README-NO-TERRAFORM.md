# README — 3-Tier App Deployment (Without Terraform)

Every command explained in detail — what it does, why it is needed, and what to expect.

---

## Step 1 — Install Tools

```bash
brew install awscli kubectl helm
```
- **awscli** — AWS Command Line Interface. Used to create all AWS resources (VPC, EKS, RDS, ECR) from your terminal.
- **kubectl** — Kubernetes CLI. Used to deploy apps, check pod status, and manage the cluster.
- **helm** — Kubernetes package manager. Used to install the AWS Load Balancer Controller.

```bash
aws configure
```
Connects your terminal to your AWS account. You will be asked for:
- **AWS Access Key ID** — from your IAM user credentials
- **AWS Secret Access Key** — from your IAM user credentials
- **Default region** — enter `ap-south-1`
- **Default output format** — enter `json`

```bash
aws sts get-caller-identity
```
Verifies your credentials are working. Returns your AWS Account ID, User ID, and ARN.
If this fails, your Access Key or Secret Key is wrong.

---

## Step 2 — Create VPC and Networking

### Create VPC
```bash
VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 \
  --query 'Vpc.VpcId' --output text)
```
- Creates a **Virtual Private Cloud** — your isolated private network on AWS.
- `--cidr-block 10.0.0.0/16` — defines the IP address range. This gives you 65,536 IP addresses (10.0.0.0 to 10.0.255.255).
- `--query 'Vpc.VpcId' --output text` — extracts just the VPC ID (e.g. `vpc-0abc123`) from the JSON response and saves it to `$VPC_ID`.

```bash
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames
```
- Enables DNS hostnames inside the VPC.
- Required so that RDS gives a readable hostname (e.g. `3-tier-app-db.xxxx.ap-south-1.rds.amazonaws.com`) instead of just an IP.

```bash
aws ec2 create-tags --resources $VPC_ID --tags Key=Name,Value=3-tier-app-vpc
```
- Adds a `Name` tag to the VPC so it shows as `3-tier-app-vpc` in the AWS Console.
- Tags are just labels — they don't affect functionality but help you identify resources.

---

### Create Internet Gateway
```bash
IGW_ID=$(aws ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text)
```
- Creates an **Internet Gateway** — the door between your VPC and the public internet.
- Without this, nothing in your VPC can reach the internet or be reached from it.

```bash
aws ec2 attach-internet-gateway --vpc-id $VPC_ID --internet-gateway-id $IGW_ID
```
- Attaches the Internet Gateway to your VPC.
- A gateway exists but does nothing until attached to a VPC.

---

### Create Public Subnets
```bash
PUB_SUBNET_1=$(aws ec2 create-subnet --vpc-id $VPC_ID \
  --cidr-block 10.0.101.0/24 --availability-zone ap-south-1a \
  --query 'Subnet.SubnetId' --output text)

PUB_SUBNET_2=$(aws ec2 create-subnet --vpc-id $VPC_ID \
  --cidr-block 10.0.102.0/24 --availability-zone ap-south-1b \
  --query 'Subnet.SubnetId' --output text)
```
- Creates 2 **public subnets** — one in `ap-south-1a` and one in `ap-south-1b`.
- Public subnets are where the **ALB (load balancer)** lives — it needs to be internet-facing.
- Two subnets in different AZs are required by AWS ALB for high availability.
- `10.0.101.0/24` gives 256 IPs. `10.0.102.0/24` gives another 256 IPs.

```bash
aws ec2 modify-subnet-attribute --subnet-id $PUB_SUBNET_1 --map-public-ip-on-launch
aws ec2 modify-subnet-attribute --subnet-id $PUB_SUBNET_2 --map-public-ip-on-launch
```
- Any EC2 instance launched in these subnets automatically gets a public IP.
- Required for the ALB to be reachable from the internet.

```bash
aws ec2 create-tags --resources $PUB_SUBNET_1 $PUB_SUBNET_2 \
  --tags Key=kubernetes.io/role/elb,Value=1
```
- Tags the public subnets so the **AWS Load Balancer Controller** knows to place the ALB here.
- Without this tag, the controller cannot find the right subnets and ALB creation fails.

---

### Create Private Subnets
```bash
PRIV_SUBNET_1=$(aws ec2 create-subnet --vpc-id $VPC_ID \
  --cidr-block 10.0.1.0/24 --availability-zone ap-south-1a \
  --query 'Subnet.SubnetId' --output text)

PRIV_SUBNET_2=$(aws ec2 create-subnet --vpc-id $VPC_ID \
  --cidr-block 10.0.2.0/24 --availability-zone ap-south-1b \
  --query 'Subnet.SubnetId' --output text)
```
- Creates 2 **private subnets** — where EKS worker nodes and RDS live.
- Private subnets have no direct internet access — more secure for your app and database.

```bash
aws ec2 create-tags --resources $PRIV_SUBNET_1 $PRIV_SUBNET_2 \
  --tags Key=kubernetes.io/role/internal-elb,Value=1
```
- Tags private subnets for internal load balancers (if needed in future).

---

### Create Public Route Table
```bash
PUB_RT=$(aws ec2 create-route-table --vpc-id $VPC_ID \
  --query 'RouteTable.RouteTableId' --output text)
```
- A **route table** is a set of rules that decides where network traffic goes.
- This one is for the public subnets.

```bash
aws ec2 create-route --route-table-id $PUB_RT \
  --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID
```
- Adds a rule: all traffic going to `0.0.0.0/0` (anywhere on the internet) should go through the Internet Gateway.
- This is what makes a subnet "public".

```bash
aws ec2 associate-route-table --route-table-id $PUB_RT --subnet-id $PUB_SUBNET_1
aws ec2 associate-route-table --route-table-id $PUB_RT --subnet-id $PUB_SUBNET_2
```
- Applies the public route table to both public subnets.

---

### Create NAT Gateway
```bash
EIP=$(aws ec2 allocate-address --domain vpc --query 'AllocationId' --output text)
```
- Allocates an **Elastic IP** (a static public IP address).
- The NAT Gateway needs a fixed public IP to send outbound traffic through.

```bash
NAT_GW=$(aws ec2 create-nat-gateway --subnet-id $PUB_SUBNET_1 \
  --allocation-id $EIP --query 'NatGateway.NatGatewayId' --output text)
```
- Creates a **NAT Gateway** in the public subnet.
- NAT Gateway allows private subnet resources (EKS nodes) to reach the internet (e.g. pull Docker images from ECR) but blocks all inbound traffic from the internet.

```bash
aws ec2 wait nat-gateway-available --nat-gateway-ids $NAT_GW
```
- Waits until the NAT Gateway is fully ready before continuing. Takes ~1 minute.

```bash
PRIV_RT=$(aws ec2 create-route-table --vpc-id $VPC_ID \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id $PRIV_RT \
  --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $NAT_GW
aws ec2 associate-route-table --route-table-id $PRIV_RT --subnet-id $PRIV_SUBNET_1
aws ec2 associate-route-table --route-table-id $PRIV_RT --subnet-id $PRIV_SUBNET_2
```
- Creates a private route table: all outbound traffic from private subnets goes through the NAT Gateway.
- Associates it with both private subnets.

---

## Step 3 — Create IAM Roles for EKS

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
```
- Gets your AWS Account ID (a 12-digit number like `123456789012`) and saves it to `$ACCOUNT_ID`.
- Needed to build IAM role ARNs in later commands.

### EKS Cluster Role
```bash
aws iam create-role --role-name 3-tier-eks-cluster-role \
  --assume-role-policy-document '{
    "Version":"2012-10-17",
    "Statement":[{"Effect":"Allow","Principal":{"Service":"eks.amazonaws.com"},
    "Action":"sts:AssumeRole"}]}'
```
- Creates an IAM role that the **EKS control plane** (API server, scheduler) uses.
- The trust policy `"Principal":{"Service":"eks.amazonaws.com"}` means only the EKS service can assume this role.

```bash
aws iam attach-role-policy --role-name 3-tier-eks-cluster-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy
```
- Attaches `AmazonEKSClusterPolicy` — gives EKS permission to manage EC2, networking, and autoscaling on your behalf.

### EKS Node Role
```bash
aws iam create-role --role-name 3-tier-eks-node-role \
  --assume-role-policy-document '{
    "Version":"2012-10-17",
    "Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},
    "Action":"sts:AssumeRole"}]}'
```
- Creates an IAM role for the **EC2 worker nodes** (the machines that run your pods).

```bash
aws iam attach-role-policy --role-name 3-tier-eks-node-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy
```
- Allows nodes to connect to the EKS cluster and register themselves.

```bash
aws iam attach-role-policy --role-name 3-tier-eks-node-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy
```
- Allows nodes to manage pod networking (assign IPs to pods from the VPC CIDR).

```bash
aws iam attach-role-policy --role-name 3-tier-eks-node-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
```
- Allows nodes to pull Docker images from ECR (your private container registry).

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
```
- Creates the EKS **control plane** (Kubernetes API server, etcd, scheduler).
- `--kubernetes-version 1.29` — Kubernetes version to use.
- `--role-arn` — the cluster role created in Step 3.
- `subnetIds` — all 4 subnets (public + private) so EKS can place resources correctly.
- `endpointPublicAccess=true` — allows you to run `kubectl` from your laptop.

```bash
aws eks wait cluster-active --name 3-tier-app-cluster
```
- Waits until the cluster is fully ready. **Takes 10–15 minutes.** Do not skip this.

---

## Step 5 — Create Node Group

```bash
aws eks create-nodegroup \
 --cluster-name 3-tier-app-cluster \
 --nodegroup-name default \
 --node-role arn:aws:iam::${ACCOUNT_ID}:role/3-tier-eks-node-role \
 --subnets $PRIV_SUBNET_1 $PRIV_SUBNET_2 \
 --instance-types t3.small \
 --scaling-config minSize=2,maxSize=4,desiredSize=3 \
 --ami-type AL2_x86_64 \
 --region ap-south-1
```
- Creates EC2 worker nodes that run your pods.
- `--instance-types t3.small` — use at least `t3.small`. `t3.micro` only allows 4 pods/node which fills up with system pods (coredns, aws-node, kube-proxy, aws-load-balancer-controller), leaving no room for your app pods.
- `--subnets` — nodes go into private subnets (not directly internet accessible).
- `minSize=2,maxSize=4,desiredSize=3` — starts with 3 nodes to ensure enough pod capacity.
- `--ami-type AL2_x86_64` — Amazon Linux 2 image optimized for EKS. Must match your Docker image build platform (see Step 9).

```bash
aws eks wait nodegroup-active --cluster-name 3-tier-app-cluster --nodegroup-name default
```
- Waits until all nodes are ready. **Takes 5–10 minutes.**

---

## Step 6 — Connect kubectl

```bash
aws eks update-kubeconfig --region ap-south-1 --name 3-tier-app-cluster
```
- Downloads the cluster credentials and adds them to `~/.kube/config`.
- After this, all `kubectl` commands target your EKS cluster.

```bash
kubectl get nodes
```
- Lists all worker nodes. You should see 2 nodes with status `Ready`.
- If nodes show `NotReady`, wait a minute and retry.

---


## Step 7 — Create RDS PostgreSQL

### Security Group for RDS

```bash
RDS_SG=$(aws ec2 create-security-group \
  --group-name 3-tier-rds-sg \
  --description "RDS SG" \
  --vpc-id $VPC_ID \
  --query 'GroupId' \
  --output text)

aws ec2 authorize-security-group-ingress \
  --group-id $RDS_SG \
  --protocol tcp \
  --port 5432 \
  --cidr 10.0.0.0/16
```

### DB Subnet Group

```bash
aws rds create-db-subnet-group \
  --db-subnet-group-name tier-app-db-subnet \
  --db-subnet-group-description "3-tier DB subnet" \
  --subnet-ids $PRIV_SUBNET_1 $PRIV_SUBNET_2
```

### Create RDS Instance

```bash
aws rds create-db-instance \
  --db-instance-identifier tier-app-db \
  --db-instance-class db.t3.micro \
  --engine postgres \
  --engine-version 15 \
  --master-username appuser \
  --master-user-password YourStrongPassword123! \
  --db-name appdb \
  --db-subnet-group-name tier-app-db-subnet \
  --vpc-security-group-ids $RDS_SG \
  --no-publicly-accessible \
  --allocated-storage 20
```

### Wait for RDS to be ready (~10–15 min)

```bash
aws rds wait db-instance-available --db-instance-identifier tier-app-db
```

### Get RDS Endpoint

```bash
RDS_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier tier-app-db \
  --query 'DBInstances[0].Endpoint.Address' \
  --output text)
echo "RDS Endpoint: $RDS_ENDPOINT"
```


## Step 8 — Create ECR Repositories

```bash
aws ecr create-repository --repository-name 3-tier-app/frontend --region ap-south-1
aws ecr create-repository --repository-name 3-tier-app/backend  --region ap-south-1
```
- Creates 2 private Docker image repositories in **ECR** (Elastic Container Registry).
- Your EKS nodes pull images from here. They have permission via the node IAM role (Step 3).

---

## Step 9 — Build & Push Docker Images

```bash
ECR_REGISTRY=${ACCOUNT_ID}.dkr.ecr.ap-south-1.amazonaws.com
```
- Builds the ECR registry URL from your account ID. Format: `<account-id>.dkr.ecr.<region>.amazonaws.com`.

```bash
aws ecr get-login-password --region ap-south-1 | \
  docker login --username AWS --password-stdin $ECR_REGISTRY
```
- Gets a temporary ECR auth token and logs Docker into ECR.
- The token is valid for 12 hours. Re-run if you get auth errors later.

```bash
cd ~/Desktop/demo/app/backend
docker buildx build --platform linux/amd64 -t $ECR_REGISTRY/3-tier-app/backend:v1 --push .
```
- `--platform linux/amd64` — **required** if you are building on an Apple Silicon Mac (M1/M2/M3). EKS nodes run on `amd64`. Without this flag, the image will be built for `arm64` and pods will crash with `exec format error`.
- `--push` — builds and pushes in one step.

```bash
cd ~/Desktop/demo/app/frontend
docker buildx build --platform linux/amd64 -t $ECR_REGISTRY/3-tier-app/frontend:v1 --push .
```
- Same for the frontend image.

---

## Step 10 — Create Namespace and DB Secret

```bash
kubectl apply -f ~/Desktop/3-tier-app/k8s/namespace.yaml
```
- Creates the `app` namespace in Kubernetes.
- A namespace isolates your app's resources from other workloads in the cluster.

```bash
kubectl create secret generic db-secret \
  --from-literal=host=$RDS_ENDPOINT \
  --from-literal=password=YourStrongPassword123! \
  -n app
```
- Creates a Kubernetes **Secret** named `db-secret` in the `app` namespace.
- Stores the RDS hostname and password as encrypted key-value pairs.
- The backend pod reads these as environment variables `DB_HOST` and `DB_PASSWORD`.
- > ⚠️ Never put real passwords in YAML files in git. Always use `kubectl create secret`.

---

## Step 11 — Install AWS Load Balancer Controller

```bash
helm repo add eks https://aws.github.io/eks-charts && helm repo update
```
- Adds the official AWS EKS Helm chart repository and updates the local cache.

### Create IAM Policy for the Controller

```bash
curl -o /tmp/alb-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.1/docs/install/iam_policy.json

aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file:///tmp/alb-policy.json
```
- Downloads and creates the IAM policy with all permissions the controller needs.

```bash
# Add DescribeListenerAttributes which is missing from the base policy
cat > /tmp/extra-policy.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "elasticloadbalancing:DescribeListenerAttributes",
      "elasticloadbalancing:ModifyListenerAttributes"
    ],
    "Resource": "*"
  }]
}
EOF

aws iam create-policy \
  --policy-name AWSLoadBalancerControllerExtraPolicy \
  --policy-document file:///tmp/extra-policy.json
```
- The base policy is missing `DescribeListenerAttributes` which causes reconcile errors. This extra policy covers it.

### Enable OIDC Provider (required for IRSA)

```bash
eksctl utils associate-iam-oidc-provider \
  --cluster 3-tier-app-cluster \
  --region ap-south-1 \
  --approve
```
- Registers the cluster's OIDC provider in IAM. **Required** for IAM Roles for Service Accounts (IRSA) to work.
- Without this, the controller falls back to the node role which lacks the right permissions.

### Create IAM Role for the Controller (IRSA)

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
OIDC_ID=$(aws eks describe-cluster --name 3-tier-app-cluster \
  --query 'cluster.identity.oidc.issuer' --output text | cut -d'/' -f5)

cat > /tmp/trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/oidc.eks.ap-south-1.amazonaws.com/id/${OIDC_ID}"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "oidc.eks.ap-south-1.amazonaws.com/id/${OIDC_ID}:sub": "system:serviceaccount:kube-system:aws-load-balancer-controller",
        "oidc.eks.ap-south-1.amazonaws.com/id/${OIDC_ID}:aud": "sts.amazonaws.com"
      }
    }
  }]
}
EOF

aws iam create-role \
  --role-name AmazonEKSLoadBalancerControllerRole \
  --assume-role-policy-document file:///tmp/trust-policy.json

aws iam attach-role-policy \
  --role-name AmazonEKSLoadBalancerControllerRole \
  --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy

aws iam attach-role-policy \
  --role-name AmazonEKSLoadBalancerControllerRole \
  --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerExtraPolicy
```

### Install the Controller with IRSA

```bash
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=3-tier-app-cluster \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=arn:aws:iam::${ACCOUNT_ID}:role/AmazonEKSLoadBalancerControllerRole \
  --set region=ap-south-1 \
  --set vpcId=$VPC_ID
```
- Installs the **AWS Load Balancer Controller** with the IRSA role annotation on the service account.
- `serviceAccount.annotations` — binds the IAM role to the Kubernetes service account so the controller has AWS permissions.
- Without the IRSA annotation, the controller uses the node role which doesn't have ELB permissions.

---

## Step 12 — Deploy to EKS

```bash
sed -i '' "s|BACKEND_IMAGE|$ECR_REGISTRY/3-tier-app/backend:v1|g" \
  ~/Desktop/demo/k8s/backend/deployment.yaml
sed -i '' "s|FRONTEND_IMAGE|$ECR_REGISTRY/3-tier-app/frontend:v1|g" \
  ~/Desktop/demo/k8s/frontend/deployment.yaml
```
- Replaces the placeholder image names with the actual ECR image URLs.
- `sed -i ''` — edits the file in-place (macOS syntax). On Linux use `sed -i` without the empty quotes.

```bash
kubectl apply -f ~/Desktop/demo/k8s/namespace.yaml
kubectl apply -f ~/Desktop/demo/k8s/backend/deployment.yaml
kubectl apply -f ~/Desktop/demo/k8s/frontend/deployment.yaml
```
- Creates the `app` namespace.
- Deploys the backend and frontend to Kubernetes.
- Creates: Deployments (pods), Services (internal networking), and Ingress (ALB).

```bash
kubectl rollout status deployment/backend  -n app
kubectl rollout status deployment/frontend -n app
```
- Waits and confirms that all pods started successfully.
- If a pod fails, this command will show the error.

---

## Step 13 — Initialize Database Table

```bash
POD=$(kubectl get pod -n app -l app=backend -o jsonpath='{.items[0].metadata.name}')
```
- Gets the name of a running backend pod (e.g. `backend-7d9f8b-xkp2q`).
- `-l app=backend` — filters pods by the label `app=backend`.

```bash
kubectl exec -it $POD -n app -- node -e "..."
```
- Runs a Node.js command inside the backend pod.
- Creates the `items` table in PostgreSQL if it doesn't exist.
- Only needed **once** on first deployment.

---

## Step 14 — Access the App

```bash
ALB=$(kubectl get ingress -n app -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}')
echo "App URL: http://$ALB"
```
- Gets the ALB DNS hostname assigned by AWS (e.g. `k8s-app-xxxx.ap-south-1.elb.amazonaws.com`).
- Wait **2–3 minutes** after Step 12 for the ALB to be fully provisioned before running this.

```bash
curl http://$ALB/api/items
```
- Tests the backend API. Should return `[]` (empty array) on first run.

Open `http://$ALB` in your browser to see the full app.

---

## Teardown

Run these steps in order. Each step must complete before the next.

### 1. Delete Kubernetes app resources (removes the ALB)
```bash
kubectl delete namespace app --ignore-not-found
```
- Deletes all Kubernetes resources (pods, services, ingress, secrets) in the `app` namespace.
- Deleting the Ingress triggers the ALB controller to remove the AWS Load Balancer automatically.

### 2. Delete EKS nodegroup and cluster
```bash
aws eks delete-nodegroup --cluster-name 3-tier-app-cluster --nodegroup-name default
aws eks wait nodegroup-deleted --cluster-name 3-tier-app-cluster --nodegroup-name default
aws eks delete-cluster --name 3-tier-app-cluster
aws eks wait cluster-deleted --name 3-tier-app-cluster
```
- Must delete the nodegroup before the cluster. The `wait` commands block until deletion is complete.

### 3. Delete ECR repositories
```bash
aws ecr delete-repository --repository-name 3-tier-app/backend  --force
aws ecr delete-repository --repository-name 3-tier-app/frontend --force
```
- `--force` removes all images inside before deleting the repository.

### 4. Delete RDS (if created)
```bash
aws rds delete-db-instance --db-instance-identifier tier-app-db --skip-final-snapshot
aws rds wait db-instance-deleted --db-instance-identifier tier-app-db
```
- `--skip-final-snapshot` skips the backup — only use if you don't need the data.

### 5. Delete OIDC provider
```bash
OIDC_ARN=$(aws iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[0].Arn' --output text)
aws iam delete-open-id-connect-provider --open-id-connect-provider-arn $OIDC_ARN
```

### 6. Delete IAM roles and policies
```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

for ROLE in 3-tier-eks-cluster-role 3-tier-eks-node-role AmazonEKSLoadBalancerControllerRole; do
  for POLICY_ARN in $(aws iam list-attached-role-policies --role-name $ROLE --query 'AttachedPolicies[*].PolicyArn' --output text 2>/dev/null); do
    aws iam detach-role-policy --role-name $ROLE --policy-arn $POLICY_ARN
  done
  aws iam delete-role --role-name $ROLE
done

aws iam delete-policy --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy
aws iam delete-policy --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerExtraPolicy
```
- Policies must be detached from all roles before the role or policy can be deleted.

### 7. Delete NAT Gateway and release Elastic IP
```bash
NAT_GW=$(aws ec2 describe-nat-gateways --filter Name=vpc-id,Values=$VPC_ID \
  --query 'NatGateways[?State!=`deleted`].NatGatewayId' --output text)
aws ec2 delete-nat-gateway --nat-gateway-id $NAT_GW
echo "Waiting 60s for NAT gateway to delete..."
sleep 60

EIP=$(aws ec2 describe-addresses --filters Name=domain,Values=vpc \
  --query 'Addresses[?AssociationId==null].AllocationId' --output text)
aws ec2 release-address --allocation-id $EIP
```
- > ⚠️ NAT Gateway costs ~$0.045/hour even when idle. Always delete when not in use.
- Must wait for NAT Gateway to finish deleting before releasing the Elastic IP.

### 8. Delete VPC and all networking
```bash
# Subnets
for SUBNET in $(aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC_ID \
  --query 'Subnets[*].SubnetId' --output text); do
  aws ec2 delete-subnet --subnet-id $SUBNET
done

# Non-main route tables
for RT in $(aws ec2 describe-route-tables --filters Name=vpc-id,Values=$VPC_ID \
  --query 'RouteTables[?!Associations[?Main==`true`]].RouteTableId' --output text); do
  aws ec2 delete-route-table --route-table-id $RT
done

# Internet Gateway
IGW=$(aws ec2 describe-internet-gateways --filters Name=attachment.vpc-id,Values=$VPC_ID \
  --query 'InternetGateways[0].InternetGatewayId' --output text)
aws ec2 detach-internet-gateway --internet-gateway-id $IGW --vpc-id $VPC_ID
aws ec2 delete-internet-gateway --internet-gateway-id $IGW

# Security groups (non-default)
for SG in $(aws ec2 describe-security-groups --filters Name=vpc-id,Values=$VPC_ID \
  --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text); do
  aws ec2 delete-security-group --group-id $SG
done

# VPC
aws ec2 delete-vpc --vpc-id $VPC_ID
echo "VPC deleted."
```
- Must delete subnets, route tables, IGW, and security groups before the VPC can be deleted.
