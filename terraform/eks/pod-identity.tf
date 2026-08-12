# EKS Pod Identity roles and the keys they use.
#
# Pod Identity replaces IRSA. Instead of creating an OIDC provider and writing
# a trust policy that matches a service account subject string, a role simply
# trusts pods.eks.amazonaws.com and is bound to a service account by an
# association object. Fewer moving parts, and the binding is a first-class API
# resource that can be listed and audited.
#
# Only the EBS CSI driver needs a role. The hello-world workload calls no AWS
# APIs at all, which is why its ServiceAccount has no role attached and no
# token mounted.
#
# This file deliberately contains no Kubernetes resources. Pointing the
# kubernetes provider at a cluster created in the same apply is a well-known
# way to get a configuration that cannot be applied from scratch in one pass,
# and that cannot be destroyed cleanly once the cluster is gone. Cluster-level
# objects such as the StorageClass are applied after the cluster exists.

module "ebs_csi_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.8"

  count = var.enable_ebs_csi_driver ? 1 : 0

  name = "${local.name}-ebs-csi"

  attach_aws_ebs_csi_policy = true

  # Scope the KMS grant to the key that actually encrypts the volumes, rather
  # than letting the driver use any key in the account.
  aws_ebs_csi_kms_arns = [aws_kms_key.ebs[0].arn]

  # The association is declared on the addon in eks.tf, because the addon must
  # exist before its service account can be bound to a role.
  associations = {}

  tags = local.tags
}

# A dedicated key for EBS volume encryption, separate from the cluster secrets
# key the EKS module creates, so the two can be rotated independently.
#
# This key encrypts PersistentVolumes created by the EBS CSI driver, which are
# referenced by the gp3 StorageClass. Node root volumes are a separate matter:
# they set encrypted = true with no key, so they use the AWS-managed aws/ebs
# key rather than this one.
#
# No aws_kms_key_policy is attached, deliberately. The default key policy
# already delegates to IAM for principals in this account, which is what lets
# the CSI driver's role use the key via aws_ebs_csi_kms_arns above. Writing an
# explicit policy here would add two problems and solve none: a malformed
# policy can lock the key out of its own account, and granting the autoscaling
# service-linked role — the usual reflex — fails outright with
# "MalformedPolicyDocument: invalid principals" in any account that has never
# used Auto Scaling, because the role does not exist until first use.
resource "aws_kms_key" "ebs" {
  # Tied to the driver that uses it: with no CSI driver there are no
  # PersistentVolumes to encrypt, and an orphaned CMK still bills monthly.
  count = var.enable_ebs_csi_driver ? 1 : 0

  description             = "${local.name} EBS volume encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = merge(local.tags, {
    Name = "${local.name}-ebs"
  })
}

resource "aws_kms_alias" "ebs" {
  count = var.enable_ebs_csi_driver ? 1 : 0

  name          = "alias/${local.name}-ebs"
  target_key_id = aws_kms_key.ebs[0].key_id
}
