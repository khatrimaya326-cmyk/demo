#!/bin/bash
# Run this ONCE before terraform init to create the S3 state bucket
set -e

REGION="us-east-1"
BUCKET="3-tier-app-tfstate"

echo "Creating S3 bucket for Terraform state..."
aws s3api create-bucket --bucket $BUCKET --region $REGION
aws s3api put-bucket-versioning --bucket $BUCKET \
  --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket $BUCKET \
  --server-side-encryption-configuration '{
    "Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]
  }'

echo "Done. Bucket: $BUCKET"
