#!/bin/bash
# Run this ONCE before terraform init to create the S3 state bucket
set -e

REGION="ap-south-1"
BUCKET="tier-app-tfstate"

echo "Creating S3 bucket for Terraform state..."
aws s3api create-bucket --bucket $BUCKET --region $REGION \
  --create-bucket-configuration LocationConstraint=$REGION
aws s3api put-bucket-versioning --bucket $BUCKET \
  --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket $BUCKET \
  --server-side-encryption-configuration '{
    "Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]
  }'

echo "Done. Bucket: $BUCKET"
