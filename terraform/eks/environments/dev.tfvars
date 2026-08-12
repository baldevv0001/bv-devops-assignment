# Development environment. Apply with:
#   terraform apply -var-file=environments/dev.tfvars

region      = "ap-south-1"
project     = "bv-devops"
environment = "dev"

# Network
vpc_cidr           = "10.0.0.0/16"
az_count           = 3
single_nat_gateway = true  # ~Rs 5/hour saved versus one per zone
enable_flow_logs   = false # CloudWatch ingestion cost, not needed for a demo

# Cluster
kubernetes_version     = "1.34"
endpoint_public_access = true

# Replace with your own address before applying: curl -s https://checkip.amazonaws.com
endpoint_public_access_cidrs   = ["0.0.0.0/0"]
allow_public_api_from_anywhere = true

cluster_log_types          = ["api", "audit", "authenticator"]
cluster_log_retention_days = 7

# Three t3.medium, one per zone.
node_instance_types = ["t3.medium"]
node_capacity_type  = "ON_DEMAND"
node_desired_size   = 3
node_min_size       = 3
node_max_size       = 6
node_disk_size      = 30

# Addons
enable_ebs_csi_driver = true
enable_metrics_server = true
