# ---------------------------------------------------------------------------
# Cluster access
# ---------------------------------------------------------------------------

output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Kubernetes API server endpoint."
  value       = module.eks.cluster_endpoint
}

output "cluster_version" {
  description = "Kubernetes version running on the control plane."
  value       = module.eks.cluster_version
}

output "region" {
  description = "Region the cluster is deployed in."
  value       = var.region
}

output "configure_kubectl" {
  description = "Command to write a kubeconfig entry for this cluster."
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------

output "vpc_id" {
  description = "VPC ID."
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs, one per availability zone. Nodes run here."
  value       = module.vpc.private_subnets
}

output "public_subnet_ids" {
  description = "Public subnet IDs. Load balancers and NAT gateways only."
  value       = module.vpc.public_subnets
}

output "availability_zones" {
  description = "Availability zones in use. The workload's topology spread constraint spreads replicas across these."
  value       = local.azs
}

output "nat_gateway_count" {
  description = "Number of NAT gateways. One is a cost trade-off that makes outbound internet access zone-dependent."
  value       = var.single_nat_gateway ? 1 : var.az_count
}

# ---------------------------------------------------------------------------
# Consumed by later steps
# ---------------------------------------------------------------------------

output "ebs_kms_key_arn" {
  description = "KMS key for EBS volume encryption. Referenced by the gp3 StorageClass applied after the cluster is up. Null when the EBS CSI driver is disabled."
  value       = one(aws_kms_key.ebs[*].arn)
}

output "cluster_security_group_id" {
  description = "Security group attached to the control plane's cross-account ENIs."
  value       = module.eks.cluster_security_group_id
}

output "node_security_group_id" {
  description = "Security group attached to the managed node group."
  value       = module.eks.node_security_group_id
}

output "oidc_provider_arn" {
  description = "OIDC provider ARN. Null by design: this cluster uses EKS Pod Identity rather than IRSA, so no OIDC provider is created."
  value       = try(module.eks.oidc_provider_arn, null)
}
