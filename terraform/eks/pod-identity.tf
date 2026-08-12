# EKS Pod Identity roles and the keys they use. A role trusts
# pods.eks.amazonaws.com and is bound to a service account, so there is no OIDC
# provider. Only the EBS CSI driver needs one; the app calls no AWS APIs.

module "ebs_csi_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.8"

  count = var.enable_ebs_csi_driver ? 1 : 0

  name = "${local.name}-ebs-csi"

  attach_aws_ebs_csi_policy = true

  # Scoped to this key rather than every key in the account.
  aws_ebs_csi_kms_arns = [aws_kms_key.ebs[0].arn]

  # The association is declared on the addon in eks.tf.
  associations = {}

  tags = local.tags
}

# Encrypts PersistentVolumes from the EBS CSI driver, separate from the cluster
# secrets key. No explicit key policy: the default delegates to IAM, and granting
# the autoscaling service-linked role fails in accounts that never used it.
resource "aws_kms_key" "ebs" {
  # Tied to the driver, since an orphaned key still bills monthly.
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
