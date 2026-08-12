#!/usr/bin/env bash
#
# Creates an encrypted gp3 StorageClass and makes it the cluster default.
#
# This is applied after the cluster exists rather than from Terraform. Pointing
# the kubernetes provider at a cluster created in the same apply gives you a
# configuration that cannot be applied from scratch in one pass and cannot be
# destroyed cleanly once the cluster is gone.
#
# EKS ships a "gp2" StorageClass marked default, and it is not encrypted. Any
# PersistentVolumeClaim that names no class lands there, which is a quiet way
# to end up with unencrypted data. This script demotes it.
#
# Usage: scripts/apply-storage-class.sh [kms-key-arn]
#        (the ARN defaults to the Terraform output)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform/eks"

KMS_ARN="${1:-}"
if [[ -z "$KMS_ARN" ]]; then
  echo "==> Reading the KMS key ARN from Terraform"
  KMS_ARN="$(cd "$TF_DIR" && terraform output -raw ebs_kms_key_arn 2>/dev/null || true)"
fi

if [[ -z "$KMS_ARN" || "$KMS_ARN" == "null" ]]; then
  echo "Could not determine the EBS KMS key ARN." >&2
  echo "Either pass it as an argument, or run this from a checkout where" >&2
  echo "terraform/eks has state with enable_ebs_csi_driver = true." >&2
  exit 1
fi
echo "    key: $KMS_ARN"

echo "==> Creating the gp3 StorageClass"
kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
# WaitForFirstConsumer stops a volume being created in one zone while the pod
# that needs it is scheduled into another, which leaves the pod permanently
# unschedulable with a misleading "volume node affinity conflict".
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
reclaimPolicy: Delete
parameters:
  type: gp3
  encrypted: "true"
  kmsKeyId: "${KMS_ARN}"
EOF

if kubectl get storageclass gp2 >/dev/null 2>&1; then
  echo "==> Demoting the built-in gp2 class so nothing defaults to an unencrypted volume"
  kubectl patch storageclass gp2 \
    -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
fi

echo
echo "==> Storage classes"
kubectl get storageclass

DEFAULTS="$(kubectl get storageclass \
  -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' | grep -c . || true)"
if [[ "$DEFAULTS" -ne 1 ]]; then
  echo
  echo "WARNING: ${DEFAULTS} storage classes are marked default. Kubernetes picks" >&2
  echo "arbitrarily among them, so a PVC could still land on an unencrypted class." >&2
  exit 1
fi

echo
echo "gp3 is the default storage class, encrypted with the customer-managed key."
