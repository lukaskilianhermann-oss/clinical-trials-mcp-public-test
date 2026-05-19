provider "google" {
  project = var.project_id
  region  = var.region
}

locals {
  required_services = [
    "artifactregistry.googleapis.com",
    "cloudbuild.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "logging.googleapis.com",
    "run.googleapis.com",
    "sts.googleapis.com",
  ]

  mcp_env_vars = {
    MCP_HOST                   = "0.0.0.0"
    MCP_PATH                   = "/mcp"
    CT_API_BASE_URL            = var.clinical_trials_api_base_url
    EU_CT_API_BASE_URL         = var.eu_clinical_trials_api_base_url
    CT_REQUEST_TIMEOUT_SECONDS = tostring(var.clinical_trials_request_timeout_seconds)
    CT_MAX_PAGE_SIZE           = tostring(var.clinical_trials_max_page_size)
    LOG_LEVEL                  = "INFO"
  }
}

module "apis" {
  source = "../modules/gcp/apis"

  project_id = var.project_id
  services   = local.required_services
}

module "runtime_sa" {
  source = "../modules/gcp/service-account"

  project_id   = var.project_id
  account_id   = var.runtime_service_account_id
  display_name = "Remote ClinicalTrials.gov MCP runtime"

  roles = []

  depends_on = [module.apis]
}

module "artifact_registry" {
  source = "../modules/gcp/artifact-registry"

  project_id    = var.project_id
  region        = var.region
  repository_id = var.artifact_repository_id
  description   = "Docker repository for clinical-trials-mcp images"

  depends_on = [module.apis]
}

module "ci_deployer_sa" {
  source = "../modules/gcp/service-account"

  project_id   = var.project_id
  account_id   = var.ci_deployer_service_account_id
  display_name = "Clinical Trials MCP CI/CD deployer"

  roles = [
    "roles/artifactregistry.writer",
    "roles/run.developer",
  ]

  depends_on = [module.apis]
}

resource "google_service_account_iam_member" "ci_can_use_runtime_sa" {
  service_account_id = module.runtime_sa.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${module.ci_deployer_sa.email}"
}

resource "google_iam_workload_identity_pool" "github_actions" {
  project                   = var.project_id
  workload_identity_pool_id = var.github_actions_pool_id
  display_name              = "GitHub Actions"
  description               = "OIDC identities for clinical-trials-mcp GitHub Actions."

  depends_on = [module.apis]
}

resource "google_iam_workload_identity_pool_provider" "github_actions" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github_actions.workload_identity_pool_id
  workload_identity_pool_provider_id = var.github_actions_provider_id
  display_name                       = "GitHub Actions OIDC"
  description                        = "Trust GitHub Actions for the configured repository."

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.actor"      = "assertion.actor"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
  }

  attribute_condition = "assertion.repository == '${var.github_repository}' && assertion.ref == 'refs/heads/${var.deploy_branch}' && (assertion.event_name == 'push' || assertion.event_name == 'workflow_dispatch')"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account_iam_member" "github_actions_can_impersonate_ci" {
  service_account_id = module.ci_deployer_sa.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github_actions.name}/attribute.repository/${var.github_repository}"
}

resource "google_service_account_iam_member" "github_actions_can_impersonate_terraform" {
  service_account_id = "projects/${var.project_id}/serviceAccounts/${var.terraform_deployer_service_account_email}"
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github_actions.name}/attribute.repository/${var.github_repository}"
}

module "cloud_run" {
  source = "../modules/gcp/cloud-run-v2-service"

  project_id            = var.project_id
  region                = var.region
  service_name          = var.service_name
  image                 = var.container_image
  service_account_email = module.runtime_sa.email
  ingress               = "INGRESS_TRAFFIC_ALL"
  invoker_iam_disabled  = var.public_access_enabled
  cpu                   = "1"
  memory                = "512Mi"
  startup_cpu_boost     = var.startup_cpu_boost
  timeout_seconds       = 300
  concurrency           = 80
  min_instance_count    = 0
  max_instance_count    = 10
  env_vars              = local.mcp_env_vars

  depends_on = [
    module.apis,
    module.artifact_registry,
  ]
}
