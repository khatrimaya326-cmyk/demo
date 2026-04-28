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
- **Default region** — enter `us-east-1`
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
- Required so that RDS gives a readable hostname (e.g. `3-tier-app-db.xxxx.us-east-1.rds.amazonaws.com`) instead of just an IP.

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
  --cidr-block 10.0.101.0/24 --availability-zone us-east-1a \
  --query 'Subnet.SubnetId' --output text)

PUB_SUBNET_2=$(aws ec2 create-subnet --vpc-id $VPC_ID \
  --cidr-block 10.0.102.0/24 --availability-zone us-east-1b \
  --query 'Subnet.SubnetId' --output text)
```
- Creates 2 **public subnets** — one in `us-east-1a` and one in `us-east-1b`.
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
  --cidr-block 10.0.1.0/24 --availability-zone us-east-1a \
  --query 'Subnet.SubnetId' --output text)

PRIV_SUBNET_2=$(aws ec2 create-subnet --vpc-id $VPC_ID \
  --cidr-block 10.0.2.0/24 --availability-zone us-east-1b \
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
  --instance-types t3.medium \
  --scaling-config minSize=2,maxSize=4,desiredSize=2 \
  --ami-type AL2_x86_64
```
- Creates EC2 worker nodes that run your pods.
- `--instance-types t3.medium` — 2 vCPU, 4GB RAM per node. Enough for this app.
- `--subnets` — nodes go into private subnets (not directly internet accessible).
- `minSize=2,maxSize=4,desiredSize=2` — starts with 2 nodes, can scale up to 4.
- `--ami-type AL2_x86_64` — Amazon Linux 2 image optimized for EKS.

```bash
aws eks wait nodegroup-active --cluster-name 3-tier-app-cluster --nodegroup-name default
```
- Waits until all nodes are ready. **Takes 5–10 minutes.**

---

## Step 6 — Connect kubectl

```bash
aws eks update-kubeconfig --region us-east-1 --name 3-tier-app-cluster
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
  --group-name 3-tier-rds-sg --description "RDS SG" \
  --vpc-id $VPC_ID --query 'GroupId' --output text)
```
- Creates a **Security Group** — a firewall for the RDS instance.

```bash
aws ec2 authorize-security-group-ingress \
  --group-id $RDS_SG --protocol tcp --port 5432 --cidr 10.0.0.0/16
```
- Opens port `5432` (PostgreSQL) only for traffic from within the VPC (`10.0.0.0/16`).
- The backend pods are inside the VPC so they can connect. The internet cannot.

### DB Subnet Group
```bash
aws rds create-db-subnet-group \
  --db-subnet-group-name 3-tier-db-subnet \
  --db-subnet-group-description "3-tier DB subnet" \
  --subnet-ids $PRIV_SUBNET_1 $PRIV_SUBNET_2
```
- Tells RDS which subnets it can use. RDS requires at least 2 subnets in different AZs.
- Uses private subnets so the database is not internet accessible.

### Create RDS Instance
```bash
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
```
- `--db-instance-class db.t3.micro` — smallest RDS size, enough for dev/test.
- `--engine postgres --engine-version 15` — PostgreSQL version 15.
- `--master-username appuser` — database admin username.
- `--master-user-password` — database admin password. **Change this to something strong.**
- `--db-name appdb` — creates a default database named `appdb`.
- `--no-publicly-accessible` — RDS is only reachable from within the VPC.
- `--allocated-storage 20` — 20GB disk space.

```bash
aws rds wait db-instance-available --db-instance-identifier 3-tier-app-db
```
- Waits until RDS is fully ready. **Takes 10–15 minutes.**

```bash
RDS_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier 3-tier-app-db \
  --query 'DBInstances[0].Endpoint.Address' --output text)
echo "RDS Endpoint: $RDS_ENDPOINT"
```
- Gets the RDS hostname (e.g. `3-tier-app-db.xxxx.us-east-1.rds.amazonaws.com`).
- Save this value — you need it in Step 10 for the Kubernetes secret.

---

## Step 8 — Create ECR Repositories

```bash
aws ecr create-repository --repository-name 3-tier-app/frontend --region us-east-1
aws ecr create-repository --repository-name 3-tier-app/backend  --region us-east-1
```
- Creates 2 private Docker image repositories in **ECR** (Elastic Container Registry).
- Your EKS nodes pull images from here. They have permission via the node IAM role (Step 3).

---

## Step 9 — Build & Push Docker Images

```bash
ECR_REGISTRY=${ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com
```
- Builds the ECR registry URL from your account ID. Format: `<account-id>.dkr.ecr.<region>.amazonaws.com`.

```bash
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin $ECR_REGISTRY
```
- Gets a temporary ECR auth token and logs Docker into ECR.
- The token is valid for 12 hours. Re-run if you get auth errors later.

```bash
cd ~/Desktop/3-tier-app/app/backend
docker build -t $ECR_REGISTRY/3-tier-app/backend:v1 .
docker push $ECR_REGISTRY/3-tier-app/backend:v1
```
- `docker build` — builds the backend Docker image from `app/backend/Dockerfile`.
- `-t $ECR_REGISTRY/3-tier-app/backend:v1` — tags it with the ECR URL and version `v1`.
- `docker push` — uploads the image to ECR.

```bash
cd ~/Desktop/3-tier-app/app/frontend
docker build -t $ECR_REGISTRY/3-tier-app/frontend:v1 .
docker push $ECR_REGISTRY/3-tier-app/frontend:v1
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

```bash
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=3-tier-app-cluster \
  --set serviceAccount.create=true \
  --set region=us-east-1 \
  --set vpcId=$VPC_ID
```
- Installs the **AWS Load Balancer Controller** into the `kube-system` namespace.
- This controller watches for Kubernetes `Ingress` resources and automatically creates an AWS ALB.
- Without this, the Ingress in `k8s/frontend/deployment.yaml` does nothing.
- `--set vpcId=$VPC_ID` — tells the controller which VPC to create the ALB in.

---

## Step 12 — Deploy to EKS

```bash
sed -i '' "s|BACKEND_IMAGE|$ECR_REGISTRY/3-tier-app/backend:v1|g" \
  ~/Desktop/3-tier-app/k8s/backend/deployment.yaml
sed -i '' "s|FRONTEND_IMAGE|$ECR_REGISTRY/3-tier-app/frontend:v1|g" \
  ~/Desktop/3-tier-app/k8s/frontend/deployment.yaml
```
- Replaces the placeholder text `BACKEND_IMAGE` / `FRONTEND_IMAGE` in the YAML files with the actual ECR image URLs.
- `sed -i ''` — edits the file in-place (macOS syntax).

```bash
kubectl apply -f ~/Desktop/3-tier-app/k8s/backend/deployment.yaml
kubectl apply -f ~/Desktop/3-tier-app/k8s/frontend/deployment.yaml
```
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
- Gets the ALB DNS hostname assigned by AWS (e.g. `k8s-app-xxxx.us-east-1.elb.amazonaws.com`).
- Wait **2–3 minutes** after Step 12 for the ALB to be fully provisioned before running this.

```bash
curl http://$ALB/api/items
```
- Tests the backend API. Should return `[]` (empty array) on first run.

Open `http://$ALB` in your browser to see the full app.

---

## Teardown

```bash
kubectl delete namespace app
```
- Deletes all Kubernetes resources (pods, services, ingress, secrets) in the `app` namespace.

```bash
aws eks delete-nodegroup --cluster-name 3-tier-app-cluster --nodegroup-name default
aws eks wait nodegroup-deleted --cluster-name 3-tier-app-cluster --nodegroup-name default
aws eks delete-cluster --name 3-tier-app-cluster
```
- Deletes the node group first (must delete nodes before the cluster).
- Waits for nodes to be deleted, then deletes the cluster.

```bash
aws rds delete-db-instance --db-instance-identifier 3-tier-app-db --skip-final-snapshot
```
- Deletes the RDS instance. `--skip-final-snapshot` skips creating a backup — use only if you don't need the data.

```bash
aws ecr delete-repository --repository-name 3-tier-app/frontend --force
aws ecr delete-repository --repository-name 3-tier-app/backend  --force
```
- Deletes ECR repositories and all images inside them. `--force` skips the confirmation.

```bash
aws ec2 delete-nat-gateway --nat-gateway-id $NAT_GW
aws ec2 release-address --allocation-id $EIP
```
- Deletes the NAT Gateway and releases the Elastic IP.
- > ⚠️ NAT Gateway costs ~$0.045/hour even when idle. Always delete when not in use.
