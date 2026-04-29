# Karpenter — Fast Node Autoscaling for EKS

## What is Karpenter?

Karpenter is a **node autoscaler** for Kubernetes that provisions new nodes in **60–90 seconds** (vs 3–5 minutes with Cluster Autoscaler).

### How it's different from Cluster Autoscaler

| Feature | Cluster Autoscaler | Karpenter |
|---|---|---|
| Speed | 3–5 minutes | 60–90 seconds |
| How it works | Scales node groups (fixed instance types) | Launches individual EC2 instances (any type) |
| Flexibility | Limited to predefined node groups | Picks best instance type for the workload |
| Bin packing | Poor (wastes resources) | Excellent (tight packing) |
| Cost | Higher (over-provisioning) | Lower (right-sized instances) |

---

## How Karpenter Works

```
Pod is pending (no node has capacity)
        ↓
Karpenter detects it
        ↓
Karpenter looks at pod requirements:
  - CPU: 2 cores
  - Memory: 4GB
  - Zone: any
        ↓
Karpenter picks the cheapest instance type that fits
  (e.g. t3.medium, t3a.medium, or spot instance)
        ↓
Launches EC2 instance directly (no ASG)
        ↓
Node joins cluster in 60–90 seconds
        ↓
Pod gets scheduled
```

**Key difference:** Karpenter talks directly to EC2 API, bypassing Auto Scaling Groups. This is why it's faster.

---

## Architecture

```
┌─────────────────────────────────────────┐
│         EKS Cluster                     │
│                                         │
│  ┌──────────────┐                       │
│  │ Karpenter    │  watches pending pods │
│  │ Controller   │◄──────────────────────┤
│  └──────┬───────┘                       │
│         │                               │
│         │ calls EC2 API                 │
│         ▼                               │
│  ┌──────────────┐                       │
│  │ EC2 Instance │  joins cluster        │
│  │ (new node)   ├──────────────────────►│
│  └──────────────┘                       │
└─────────────────────────────────────────┘
```

---

## Setup Karpenter on EKS

### Prerequisites

- EKS cluster already running
- `kubectl` and `helm` installed
- AWS CLI configured

---

### Step 1 — Set Environment Variables

```bash
export CLUSTER_NAME=3-tier-app-cluster
export AWS_REGION=ap-south-1
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export KARPENTER_VERSION=1.0.0
```

---

### Step 2 — Create IAM Role for Karpenter Controller

Karpenter needs permission to launch EC2 instances.

```bash
# Create trust policy
cat > karpenter-trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/oidc.eks.${AWS_REGION}.amazonaws.com/id/$(aws eks describe-cluster --name ${CLUSTER_NAME} --query 'cluster.identity.oidc.issuer' --output text | cut -d '/' -f 5)"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.eks.${AWS_REGION}.amazonaws.com/id/$(aws eks describe-cluster --name ${CLUSTER_NAME} --query 'cluster.identity.oidc.issuer' --output text | cut -d '/' -f 5):sub": "system:serviceaccount:kube-system:karpenter",
          "oidc.eks.${AWS_REGION}.amazonaws.com/id/$(aws eks describe-cluster --name ${CLUSTER_NAME} --query 'cluster.identity.oidc.issuer' --output text | cut -d '/' -f 5):aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF

# Create the role
aws iam create-role \
  --role-name KarpenterControllerRole-${CLUSTER_NAME} \
  --assume-role-policy-document file://karpenter-trust-policy.json

# Attach policies
aws iam attach-role-policy \
  --role-name KarpenterControllerRole-${CLUSTER_NAME} \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2FullAccess

aws iam attach-role-policy \
  --role-name KarpenterControllerRole-${CLUSTER_NAME} \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy
```

---

### Step 3 — Create IAM Role for Nodes Launched by Karpenter

```bash
# Trust policy for EC2
cat > node-trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

# Create role
aws iam create-role \
  --role-name KarpenterNodeRole-${CLUSTER_NAME} \
  --assume-role-policy-document file://node-trust-policy.json

# Attach standard EKS node policies
aws iam attach-role-policy \
  --role-name KarpenterNodeRole-${CLUSTER_NAME} \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy

aws iam attach-role-policy \
  --role-name KarpenterNodeRole-${CLUSTER_NAME} \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy

aws iam attach-role-policy \
  --role-name KarpenterNodeRole-${CLUSTER_NAME} \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly

aws iam attach-role-policy \
  --role-name KarpenterNodeRole-${CLUSTER_NAME} \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

# Create instance profile
aws iam create-instance-profile \
  --instance-profile-name KarpenterNodeInstanceProfile-${CLUSTER_NAME}

aws iam add-role-to-instance-profile \
  --instance-profile-name KarpenterNodeInstanceProfile-${CLUSTER_NAME} \
  --role-name KarpenterNodeRole-${CLUSTER_NAME}
```

---

### Step 4 — Tag Subnets for Karpenter

Karpenter needs to know which subnets to use.

```bash
# Get private subnet IDs
SUBNET_IDS=$(aws eks describe-cluster --name ${CLUSTER_NAME} \
  --query 'cluster.resourcesVpcConfig.subnetIds' --output text)

# Tag each subnet
for SUBNET in $SUBNET_IDS; do
  aws ec2 create-tags \
    --resources $SUBNET \
    --tags Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}
done
```

---

### Step 5 — Install Karpenter with Helm

```bash
helm repo add karpenter https://charts.karpenter.sh
helm repo update

helm install karpenter karpenter/karpenter \
  --namespace kube-system \
  --set settings.clusterName=${CLUSTER_NAME} \
  --set settings.interruptionQueue=${CLUSTER_NAME} \
  --set controller.resources.requests.cpu=1 \
  --set controller.resources.requests.memory=1Gi \
  --set controller.resources.limits.cpu=1 \
  --set controller.resources.limits.memory=1Gi \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=arn:aws:iam::${AWS_ACCOUNT_ID}:role/KarpenterControllerRole-${CLUSTER_NAME} \
  --version ${KARPENTER_VERSION} \
  --wait
```

Verify:
```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter
```

You should see 2 `karpenter` pods running.

---

### Step 6 — Create a NodePool (Karpenter's "Node Group")

A **NodePool** defines what types of nodes Karpenter can launch.

```bash
cat > nodepool.yaml <<EOF
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: default
spec:
  template:
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["t", "c", "m"]
        - key: karpenter.k8s.aws/instance-generation
          operator: Gt
          values: ["2"]
  limits:
    cpu: "100"
    memory: 100Gi
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 1m
---
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: default
spec:
  amiFamily: AL2
  role: KarpenterNodeRole-${CLUSTER_NAME}
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: ${CLUSTER_NAME}
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: ${CLUSTER_NAME}
  userData: |
    #!/bin/bash
    /etc/eks/bootstrap.sh ${CLUSTER_NAME}
EOF

kubectl apply -f nodepool.yaml
```

**What this does:**
- Allows Karpenter to launch `t`, `c`, or `m` instance families (t3, c5, m5, etc.)
- Only generation 3+ (no old t2 instances)
- On-demand instances only (no spot for now)
- Max 100 CPUs total across all Karpenter nodes
- Consolidates underutilized nodes after 1 minute

---

### Step 7 — Tag Security Groups

```bash
# Get cluster security group
CLUSTER_SG=$(aws eks describe-cluster --name ${CLUSTER_NAME} \
  --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)

aws ec2 create-tags \
  --resources $CLUSTER_SG \
  --tags Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}
```

---

### Step 8 — Test Karpenter

Deploy a pod that requires more resources than your current nodes have:

```bash
cat > test-pod.yaml <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: inflate
spec:
  containers:
  - name: inflate
    image: public.ecr.aws/eks-distro/kubernetes/pause:3.7
    resources:
      requests:
        cpu: 10
        memory: 10Gi
EOF

kubectl apply -f test-pod.yaml
```

Watch Karpenter provision a new node:
```bash
kubectl logs -f -n kube-system -l app.kubernetes.io/name=karpenter
```

You'll see logs like:
```
INFO    controller.provisioner  found provisionable pod(s)
INFO    controller.provisioner  computed new node(s) to fit pod(s)
INFO    controller.provisioner  launching node with 10 CPU, 10Gi memory
```

Check nodes:
```bash
kubectl get nodes
```

A new node should appear in **60–90 seconds**.

Delete the test pod:
```bash
kubectl delete pod inflate
```

After 1 minute, Karpenter will **automatically delete** the underutilized node.

---

## How Karpenter Saves Money

### 1. Right-sizing
Cluster Autoscaler only scales node groups with fixed instance types. If you have a `t3.medium` node group and need 8GB RAM, it launches a `t3.medium` (4GB) — wasting resources.

Karpenter picks the **cheapest instance** that fits. If you need 8GB, it might launch a `t3a.large` (8GB) which is cheaper than 2× `t3.medium`.

### 2. Consolidation
Karpenter automatically moves pods to fewer nodes and deletes empty ones. Cluster Autoscaler only scales down after 10 minutes of being empty.

### 3. Spot Instances
Karpenter can mix on-demand and spot instances. Spot is 70% cheaper but can be interrupted. Karpenter handles interruptions gracefully.

To enable spot:
```yaml
- key: karpenter.sh/capacity-type
  operator: In
  values: ["on-demand", "spot"]  # add spot here
```

---

## Karpenter vs Cluster Autoscaler — Summary

| Scenario | Cluster Autoscaler | Karpenter |
|---|---|---|
| Pod needs 2 CPU, 4GB RAM | Launches t3.medium (2 CPU, 4GB) in 3–5 mins | Launches t3.medium in 60–90 secs |
| Pod needs 8 CPU, 16GB RAM | Launches 4× t3.medium (wastes resources) | Launches 1× c5.2xlarge (exact fit) |
| Node becomes empty | Waits 10 mins, then deletes | Deletes after 1 min |
| Cost optimization | Manual tuning needed | Automatic |

---

## When NOT to Use Karpenter

- You need **predictable, fixed capacity** (e.g. always 10 nodes)
- You're running **stateful workloads** that can't tolerate node churn
- Your cluster is **very small** (< 5 nodes) — overhead not worth it

For most production workloads, Karpenter is better.

---

## Cleanup

To remove Karpenter:

```bash
kubectl delete -f nodepool.yaml
helm uninstall karpenter -n kube-system

aws iam remove-role-from-instance-profile \
  --instance-profile-name KarpenterNodeInstanceProfile-${CLUSTER_NAME} \
  --role-name KarpenterNodeRole-${CLUSTER_NAME}

aws iam delete-instance-profile \
  --instance-profile-name KarpenterNodeInstanceProfile-${CLUSTER_NAME}

aws iam delete-role --role-name KarpenterNodeRole-${CLUSTER_NAME}
aws iam delete-role --role-name KarpenterControllerRole-${CLUSTER_NAME}
```

---

## Further Reading

- Official docs: https://karpenter.sh
- Best practices: https://aws.github.io/aws-eks-best-practices/karpenter/
- Cost savings calculator: https://karpenter.sh/preview/getting-started/migrating-from-cas/#cost-savings
