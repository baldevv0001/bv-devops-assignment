# ---------------------------------------------------------------------------
# Identity and placement
# ---------------------------------------------------------------------------

variable "region" {
  description = "AWS region to deploy into. Must have at least as many availability zones as az_count."
  type        = string
  default     = "ap-south-1"
}

variable "project" {
  description = "Project name. Combined with environment to name every resource."
  type        = string
  default     = "bv-devops"

  validation {
    condition     = can(regex("^[a-z0-9-]{2,24}$", var.project))
    error_message = "project must be 2-24 characters of lowercase letters, digits or hyphens."
  }
}

variable "environment" {
  description = "Environment name, e.g. dev, staging, prod."
  type        = string
  default     = "dev"

  validation {
    condition     = can(regex("^[a-z0-9-]{2,12}$", var.environment))
    error_message = "environment must be 2-12 characters of lowercase letters, digits or hyphens."
  }
}

variable "tags" {
  description = "Additional tags applied to every resource that supports them."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR block for the VPC. Needs room for three private and three public subnets."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid CIDR block."
  }

  # The can() short-circuits input that is not a CIDR, which would crash the split.
  validation {
    condition     = !can(cidrhost(var.vpc_cidr, 0)) || tonumber(split("/", var.vpc_cidr)[1]) <= 20
    error_message = "vpc_cidr must be /20 or larger. Anything smaller cannot be split into six subnets with room for pod IPs, and the VPC CNI hands every pod a real VPC address."
  }
}

variable "az_count" {
  description = "Number of availability zones to spread across. Three is the minimum for the chart's zone spread constraint to be satisfiable."
  type        = number
  default     = 3

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 4
    error_message = "az_count must be between 2 and 4. Below 2 there is no availability story at all; above 4 the subnet maths in this configuration runs out of address space."
  }
}

variable "single_nat_gateway" {
  description = "One NAT Gateway instead of one per zone. Cheaper, but outbound traffic then depends on a single zone."
  type        = bool
  default     = true
}

variable "enable_flow_logs" {
  description = "Send VPC flow logs to CloudWatch. Useful for incident forensics; adds ingestion and storage cost."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# Cluster
# ---------------------------------------------------------------------------

variable "kubernetes_version" {
  description = "EKS control plane version. Staying on a version in standard support avoids the 6x extended-support price."
  type        = string
  default     = "1.34"
}

variable "endpoint_public_access" {
  description = "Expose the Kubernetes API endpoint publicly. Required to run kubectl from outside the VPC without a bastion or VPN."
  type        = bool
  default     = true
}

variable "endpoint_public_access_cidrs" {
  description = "Source CIDRs allowed to reach the public API endpoint. Narrow this to your own address."
  type        = list(string)
  default     = ["0.0.0.0/0"]

  validation {
    condition     = alltrue([for c in var.endpoint_public_access_cidrs : can(cidrhost(c, 0))])
    error_message = "Every entry must be a valid CIDR block, e.g. [\"203.0.113.4/32\"]."
  }

  # Placed here rather than in a resource precondition so it needs no plan.
  validation {
    condition = (
      !var.endpoint_public_access
      || !contains(var.endpoint_public_access_cidrs, "0.0.0.0/0")
      || var.allow_public_api_from_anywhere
    )
    error_message = join("", [
      "The Kubernetes API endpoint would be reachable from 0.0.0.0/0. ",
      "Either narrow endpoint_public_access_cidrs to your own address, for example [\"203.0.113.4/32\"], ",
      "or set allow_public_api_from_anywhere = true to accept the exposure deliberately.",
    ])
  }
}

variable "allow_public_api_from_anywhere" {
  description = "Explicit acknowledgement required to expose the API endpoint to 0.0.0.0/0. Exists so that leaving it open is a decision rather than an oversight."
  type        = bool
  default     = false
}

variable "cluster_log_types" {
  description = "Control plane log types to ship to CloudWatch. The audit log is the one that answers 'who did this' after an incident."
  type        = list(string)
  default     = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
}

variable "cluster_log_retention_days" {
  description = "CloudWatch retention for control plane logs. Zero means never expire, which quietly becomes the largest line on the bill."
  type        = number
  default     = 30
}

# ---------------------------------------------------------------------------
# Node group
# ---------------------------------------------------------------------------

variable "node_instance_types" {
  description = "Instance types for the managed node group. Listing several lets the ASG fall back when one type is unavailable in a zone."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_capacity_type" {
  description = "ON_DEMAND or SPOT. Spot is far cheaper but interruptible; the PodDisruptionBudget and zone spread limit the blast radius of a reclaim."
  type        = string
  default     = "ON_DEMAND"

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.node_capacity_type)
    error_message = "node_capacity_type must be ON_DEMAND or SPOT."
  }
}

variable "node_desired_size" {
  description = "Initial node count. Should be at least az_count so every zone has a node for the workload to spread onto."
  type        = number
  default     = 3

  validation {
    condition     = var.node_desired_size >= var.node_min_size && var.node_desired_size <= var.node_max_size
    error_message = "Node sizing must satisfy node_min_size <= node_desired_size <= node_max_size."
  }

  validation {
    condition     = var.node_desired_size >= var.az_count
    error_message = "node_desired_size must be at least az_count, otherwise some zone has no node and the workload's zone spread constraint can never be satisfied."
  }
}

variable "node_min_size" {
  description = "Minimum node count."
  type        = number
  default     = 3
}

variable "node_max_size" {
  description = "Maximum node count."
  type        = number
  default     = 6
}

variable "node_disk_size" {
  description = "Root EBS volume size in GiB per node."
  type        = number
  default     = 30
}

# ---------------------------------------------------------------------------
# Addons
# ---------------------------------------------------------------------------

variable "enable_ebs_csi_driver" {
  description = "Install the EBS CSI driver with a Pod Identity role. Required for any PersistentVolumeClaim, including Prometheus and Grafana storage."
  type        = bool
  default     = true
}

variable "enable_metrics_server" {
  description = "Install metrics-server. Required for the HorizontalPodAutoscaler to have any metrics to act on."
  type        = bool
  default     = true
}
