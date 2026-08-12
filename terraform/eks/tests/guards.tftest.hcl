# Native Terraform tests for the configuration's guard rails.
#
# Run with: terraform test
#
# mock_provider means these need no AWS credentials and create nothing, so they
# run in CI on every pull request. Each `run` block asserts that a specific
# misconfiguration is rejected — if one of these ever passes, a guard has
# silently stopped protecting anything.

# Baseline for every run. Without this each test inherits the module's own
# defaults, which include an API endpoint open to 0.0.0.0/0 — so every test
# would trip that guard in addition to the one it is actually checking.
variables {
  endpoint_public_access         = true
  endpoint_public_access_cidrs   = ["203.0.113.4/32"]
  allow_public_api_from_anywhere = false
}

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["ap-south-1a", "ap-south-1b", "ap-south-1c"]
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:role/terraform"
      user_id    = "AIDAEXAMPLEEXAMPLE"
      id         = "123456789012"
    }
  }

  mock_data "aws_iam_session_context" {
    defaults = {
      issuer_arn  = "arn:aws:iam::123456789012:role/terraform"
      issuer_id   = "AROAEXAMPLEEXAMPLE"
      issuer_name = "terraform"
      arn         = "arn:aws:iam::123456789012:role/terraform"
    }
  }

  # Without this the mock invents a placeholder string for `json`, and every
  # aws_iam_role rejects it as "not a JSON object" — an artefact of mocking
  # that would otherwise drown out the failures these tests are checking for.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json          = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
      minified_json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  # Likewise: a random partition string turns every managed-policy ARN the
  # module builds into an invalid ARN.
  mock_data "aws_partition" {
    defaults = {
      partition          = "aws"
      dns_suffix         = "amazonaws.com"
      reverse_dns_prefix = "com.amazonaws"
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "ap-south-1"
      name   = "ap-south-1"
    }
  }
}

# ---------------------------------------------------------------------------
# Happy path
#
# The rejection tests below would all still pass if the configuration were
# broken in some way that made every plan fail. This one proves a valid
# configuration plans cleanly and derives the values it should.
# ---------------------------------------------------------------------------

run "valid_configuration_plans_and_derives_expected_topology" {
  command = plan

  variables {
    az_count           = 3
    node_desired_size  = 3
    node_min_size      = 3
    node_max_size      = 6
    single_nat_gateway = true
  }

  assert {
    condition     = length(output.availability_zones) == 3
    error_message = "Expected three availability zones."
  }

  assert {
    condition     = length(output.private_subnet_ids) == 3
    error_message = "Expected one private subnet per availability zone."
  }

  assert {
    condition     = length(output.public_subnet_ids) == 3
    error_message = "Expected one public subnet per availability zone."
  }

  assert {
    condition     = output.nat_gateway_count == 1
    error_message = "single_nat_gateway = true should produce exactly one NAT gateway."
  }

  # Pod Identity, not IRSA: no OIDC provider should be created.
  assert {
    condition     = output.oidc_provider_arn == null
    error_message = "An OIDC provider was created; this cluster is meant to use EKS Pod Identity instead of IRSA."
  }
}

# The optional addons are guarded by count/conditional expressions that index
# into module.ebs_csi_pod_identity[0]. Nothing exercises those indexes unless a
# test turns the addons off, so this run is what proves the disabled path is
# not a latent "index out of range" at apply time.
run "plans_with_optional_addons_disabled" {
  command = plan

  variables {
    enable_ebs_csi_driver = false
    enable_metrics_server = false
  }

  assert {
    condition     = output.ebs_kms_key_arn == null
    error_message = "No EBS KMS key should be created when the CSI driver is disabled — an orphaned CMK still bills monthly."
  }
}

run "one_nat_gateway_per_zone_when_not_cost_optimised" {
  command = plan

  variables {
    az_count           = 3
    single_nat_gateway = false
  }

  assert {
    condition     = output.nat_gateway_count == 3
    error_message = "single_nat_gateway = false should produce one NAT gateway per zone."
  }
}

# ---------------------------------------------------------------------------
# API endpoint exposure
# ---------------------------------------------------------------------------

run "rejects_public_api_open_to_the_world_without_acknowledgement" {
  command = plan

  variables {
    endpoint_public_access         = true
    endpoint_public_access_cidrs   = ["0.0.0.0/0"]
    allow_public_api_from_anywhere = false
  }

  expect_failures = [var.endpoint_public_access_cidrs]
}

run "rejects_malformed_endpoint_cidr" {
  command = plan

  variables {
    endpoint_public_access_cidrs = ["203.0.113.4"]
  }

  expect_failures = [var.endpoint_public_access_cidrs]
}

# ---------------------------------------------------------------------------
# Node group sizing
# ---------------------------------------------------------------------------

run "rejects_desired_size_below_minimum" {
  command = plan

  variables {
    node_min_size     = 5
    node_desired_size = 3
    node_max_size     = 6
  }

  expect_failures = [var.node_desired_size]
}

run "rejects_desired_size_above_maximum" {
  command = plan

  variables {
    node_min_size     = 1
    node_desired_size = 9
    node_max_size     = 6
  }

  expect_failures = [var.node_desired_size]
}

# Fewer nodes than zones means at least one zone is empty, and the chart's
# zone spread constraint uses whenUnsatisfiable: DoNotSchedule — so a replica
# would sit Pending forever with no obvious link back to this setting.
run "rejects_fewer_nodes_than_availability_zones" {
  command = plan

  variables {
    az_count          = 3
    node_min_size     = 1
    node_desired_size = 2
    node_max_size     = 6
  }

  expect_failures = [var.node_desired_size]
}

run "rejects_invalid_capacity_type" {
  command = plan

  variables {
    node_capacity_type = "CHEAP"
  }

  expect_failures = [var.node_capacity_type]
}

# ---------------------------------------------------------------------------
# Network sizing
# ---------------------------------------------------------------------------

run "rejects_single_availability_zone" {
  command = plan

  variables {
    az_count = 1
  }

  expect_failures = [var.az_count]
}

# The VPC CNI gives every pod a real VPC address, so an undersized VPC runs out
# of pod IPs long before it runs out of nodes.
run "rejects_vpc_cidr_too_small_for_pod_addresses" {
  command = plan

  variables {
    vpc_cidr = "10.0.0.0/24"
  }

  expect_failures = [var.vpc_cidr]
}

run "rejects_malformed_vpc_cidr" {
  command = plan

  variables {
    vpc_cidr = "10.0.0.0"
  }

  expect_failures = [var.vpc_cidr]
}

# ---------------------------------------------------------------------------
# Naming
# ---------------------------------------------------------------------------

run "rejects_project_name_with_invalid_characters" {
  command = plan

  variables {
    project = "BV_DevOps"
  }

  expect_failures = [var.project]
}
