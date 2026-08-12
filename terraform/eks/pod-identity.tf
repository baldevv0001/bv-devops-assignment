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
  aws_ebs_csi_kms_arns = [aws_kms_key.ebs.arn]

  # The association is declared on the addon in eks.tf, because the addon must
  # exist before its service account can be bound to a role.
  associations = {}

  tags = local.tags
}

# A dedicated key for EBS volume encryption, separate from the cluster secrets
# key the EKS module creates, so the two can be rotated independently.
resource "aws_kms_key" "ebs" {
  description             = "${local.name} EBS volume encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = merge(local.tags, {
    Name = "${local.name}-ebs"
  })
}

resource "aws_kms_alias" "ebs" {
  name          = "alias/${local.name}-ebs"
  target_key_id = aws_kms_key.ebs.key_id
}

data "aws_iam_policy_document" "ebs_key" {
  # Lets IAM policies in this account grant use of the key. Without a statement
  # allowing the account root, the key can only ever be used by principals
  # named explicitly in this policy, and the CSI driver's IAM permissions would
  # have no effect.
  statement {
    sid       = "AllowAccountAdministration"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  # EBS volumes attached by an Auto Scaling group are encrypted through the
  # autoscaling service-linked role. Omitting this grant makes node launches
  # fail with an access-denied that points nowhere useful.
  statement {
    sid    = "AllowServiceLinkedRoleUse"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
      "kms:CreateGrant",
    ]
    resources = ["*"]

    principals {
      type = "AWS"
      identifiers = [
        "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling",
      ]
    }
  }
}

resource "aws_kms_key_policy" "ebs" {
  key_id = aws_kms_key.ebs.id
  policy = data.aws_iam_policy_document.ebs_key.json
}
