#!/usr/bin/env bash
set -euo pipefail

# Optional no-argument configuration. Fill these in if you want to run
# ./bootstrap.sh without passing flags.
PROJECT_ID="test-mcp-496812"
STATE_BUCKET="test-mcp-terraform-state"
GITHUB_REPOSITORY="lukaskilianhermann-oss/clinical-trials-mcp-public-test"
REGION="europe-west3"
TF_STATE_PREFIX="clinical-trials-mcp/remote-mcp"
DEPLOY_BRANCH="main"
TERRAFORM_DEPLOYER_SERVICE_ACCOUNT_ID="trial-mcp-tf-deployer"
APPLY_TERRAFORM=true
AUTO_APPROVE=true
SET_GITHUB_VARS=true
DEPLOY_IMAGE=false

usage() {
  cat <<'USAGE'
Usage: ./bootstrap.sh \
  --project-id <gcp-project-id> \
  --state-bucket <terraform-state-bucket> \
  --github-repository <owner/clinical-trials-mcp> \
  [--region europe-west3] \
  [--tf-state-prefix clinical-trials-mcp/remote-mcp] \
  [--deploy-branch main] \
  [--terraform-deployer-service-account-id trial-mcp-tf-deployer] \
  [--apply] \
  [--auto-approve] \
  [--set-github-vars] \
  [--deploy-image]

Or edit the configuration block at the top of this file and run:
  ./bootstrap.sh

Creates the Terraform state bucket if needed, enables bootstrap APIs, creates
the bootstrap-owned Terraform deployer service account, writes a local Terraform
variable override for CI/CD identity settings, and initializes the remote MCP
Terraform backend.

Use --apply to provision the Cloud Run, Artifact Registry, service account, and
Workload Identity Federation resources. Use --set-github-vars after apply to
write deployment variables to the GitHub repository with gh. Use --deploy-image
after --set-github-vars to trigger the first real MCP image deployment.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-id)
      PROJECT_ID="${2:-}"
      shift 2
      ;;
    --state-bucket)
      STATE_BUCKET="${2:-}"
      shift 2
      ;;
    --github-repository)
      GITHUB_REPOSITORY="${2:-}"
      shift 2
      ;;
    --region)
      REGION="${2:-}"
      shift 2
      ;;
    --tf-state-prefix)
      TF_STATE_PREFIX="${2:-}"
      shift 2
      ;;
    --deploy-branch)
      DEPLOY_BRANCH="${2:-}"
      shift 2
      ;;
    --terraform-deployer-service-account-id)
      TERRAFORM_DEPLOYER_SERVICE_ACCOUNT_ID="${2:-}"
      shift 2
      ;;
    --apply)
      APPLY_TERRAFORM=true
      shift
      ;;
    --auto-approve)
      AUTO_APPROVE=true
      shift
      ;;
    --set-github-vars)
      SET_GITHUB_VARS=true
      shift
      ;;
    --deploy-image)
      DEPLOY_IMAGE=true
      SET_GITHUB_VARS=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "${PROJECT_ID}" || -z "${STATE_BUCKET}" || -z "${GITHUB_REPOSITORY}" ]]; then
  echo "Missing required arguments." >&2
  usage
  exit 1
fi

if [[ "${GITHUB_REPOSITORY}" != */* ]]; then
  echo "--github-repository must be in owner/name format." >&2
  exit 1
fi

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_cmd terraform

if command -v gcloud >/dev/null 2>&1; then
  GCLOUD_BIN="$(command -v gcloud)"
elif command -v gcloud.cmd >/dev/null 2>&1; then
  GCLOUD_BIN="$(command -v gcloud.cmd)"
else
  echo "Missing required command: gcloud" >&2
  exit 1
fi

run_gcloud() {
  local -a env_args=(-u PYTHONHOME -u PYTHONPATH -u CLOUDSDK_PYTHON)
  if [[ "${GCLOUD_BIN}" == *.cmd ]]; then
    # Git Bash runs .cmd files poorly when paths or args contain spaces.
    local gcloud_win="${GCLOUD_BIN}"
    if command -v cygpath >/dev/null 2>&1; then
      gcloud_win="$(cygpath -w "${GCLOUD_BIN}")"
    fi
    env "${env_args[@]}" cmd.exe //c "\"${gcloud_win}\"" "$@"
  else
    env "${env_args[@]}" "${GCLOUD_BIN}" "$@"
  fi
}

echo "Setting gcloud project to ${PROJECT_ID}"
run_gcloud config set project "${PROJECT_ID}" >/dev/null

BOOTSTRAP_APIS=(
  cloudresourcemanager.googleapis.com
  iam.googleapis.com
  serviceusage.googleapis.com
  storage.googleapis.com
)

echo "Enabling bootstrap APIs"
run_gcloud services enable "${BOOTSTRAP_APIS[@]}" --project "${PROJECT_ID}"

if run_gcloud storage buckets describe "gs://${STATE_BUCKET}" --project "${PROJECT_ID}" >/dev/null 2>&1; then
  echo "State bucket gs://${STATE_BUCKET} already exists"
else
  echo "Creating state bucket gs://${STATE_BUCKET} in ${REGION}"
  run_gcloud storage buckets create "gs://${STATE_BUCKET}" \
    --project "${PROJECT_ID}" \
    --location "${REGION}" \
    --uniform-bucket-level-access
fi

echo "Configuring state bucket"
run_gcloud storage buckets update "gs://${STATE_BUCKET}" --versioning >/dev/null
run_gcloud storage buckets update "gs://${STATE_BUCKET}" --pap >/dev/null

TERRAFORM_DEPLOYER_SERVICE_ACCOUNT="${TERRAFORM_DEPLOYER_SERVICE_ACCOUNT_ID}@${PROJECT_ID}.iam.gserviceaccount.com"

if run_gcloud iam service-accounts describe "${TERRAFORM_DEPLOYER_SERVICE_ACCOUNT}" --project "${PROJECT_ID}" >/dev/null 2>&1; then
  echo "Terraform deployer service account ${TERRAFORM_DEPLOYER_SERVICE_ACCOUNT} already exists"
else
  echo "Creating Terraform deployer service account ${TERRAFORM_DEPLOYER_SERVICE_ACCOUNT}"
  run_gcloud iam service-accounts create "${TERRAFORM_DEPLOYER_SERVICE_ACCOUNT_ID}" \
    --project "${PROJECT_ID}" \
    --display-name "Clinical Trials MCP Terraform deployer"
fi

ensure_project_role() {
  local member="$1"
  local role="$2"

  run_gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member "${member}" \
    --role "${role}" \
    --quiet >/dev/null
}

TF_DEPLOYER_MEMBER="serviceAccount:${TERRAFORM_DEPLOYER_SERVICE_ACCOUNT}"
TF_DEPLOYER_PROJECT_ROLES=(
  roles/artifactregistry.admin
  roles/iam.serviceAccountAdmin
  roles/iam.workloadIdentityPoolAdmin
  roles/resourcemanager.projectIamAdmin
  roles/run.admin
  roles/serviceusage.serviceUsageAdmin
)

echo "Granting Terraform deployer project roles"
for role in "${TF_DEPLOYER_PROJECT_ROLES[@]}"; do
  ensure_project_role "${TF_DEPLOYER_MEMBER}" "${role}"
done

echo "Granting Terraform deployer state bucket access"
run_gcloud storage buckets add-iam-policy-binding "gs://${STATE_BUCKET}" \
  --member "${TF_DEPLOYER_MEMBER}" \
  --role roles/storage.admin \
  --quiet >/dev/null

cat > infra/remote-mcp/bootstrap.auto.tfvars <<EOF
project_id                                 = "${PROJECT_ID}"
region                                     = "${REGION}"
github_repository                          = "${GITHUB_REPOSITORY}"
deploy_branch                              = "${DEPLOY_BRANCH}"
terraform_deployer_service_account_email   = "${TERRAFORM_DEPLOYER_SERVICE_ACCOUNT}"
EOF

echo "Initializing Terraform backend"
terraform -chdir=infra/remote-mcp init \
  -backend-config="bucket=${STATE_BUCKET}" \
  -backend-config="prefix=${TF_STATE_PREFIX}" \
  -reconfigure

if [[ "${APPLY_TERRAFORM}" == "true" ]]; then
  echo "Applying Terraform"
  if [[ "${AUTO_APPROVE}" == "true" ]]; then
    terraform -chdir=infra/remote-mcp apply -auto-approve
  else
    terraform -chdir=infra/remote-mcp apply
  fi
fi

set_github_var() {
  local name="$1"
  local value="$2"

  gh variable set "${name}" \
    --repo "${GITHUB_REPOSITORY}" \
    --body "${value}"
}

if [[ "${SET_GITHUB_VARS}" == "true" ]]; then
  require_cmd gh

  echo "Reading Terraform outputs"
  CLOUD_RUN_SERVICE="$(terraform -chdir=infra/remote-mcp output -raw service_name)"
  ARTIFACT_REGISTRY_REPOSITORY="$(terraform -chdir=infra/remote-mcp output -raw artifact_repository_url)"
  WIF_PROVIDER="$(terraform -chdir=infra/remote-mcp output -raw github_actions_workload_identity_provider)"
  DEPLOYER_SERVICE_ACCOUNT="$(terraform -chdir=infra/remote-mcp output -raw ci_deployer_service_account_email)"
  TERRAFORM_DEPLOYER_SERVICE_ACCOUNT="$(terraform -chdir=infra/remote-mcp output -raw terraform_deployer_service_account_email)"

  echo "Setting GitHub repository variables on ${GITHUB_REPOSITORY}"
  set_github_var GCP_PROJECT_ID "${PROJECT_ID}"
  set_github_var GCP_REGION "${REGION}"
  set_github_var CLOUD_RUN_SERVICE "${CLOUD_RUN_SERVICE}"
  set_github_var ARTIFACT_REGISTRY_REPOSITORY "${ARTIFACT_REGISTRY_REPOSITORY}"
  set_github_var WIF_PROVIDER "${WIF_PROVIDER}"
  set_github_var DEPLOYER_SERVICE_ACCOUNT "${DEPLOYER_SERVICE_ACCOUNT}"
  set_github_var TERRAFORM_DEPLOYER_SERVICE_ACCOUNT "${TERRAFORM_DEPLOYER_SERVICE_ACCOUNT}"
  set_github_var TERRAFORM_STATE_BUCKET "${STATE_BUCKET}"
  set_github_var TERRAFORM_STATE_PREFIX "${TF_STATE_PREFIX}"

  echo "GitHub repository variables updated."
fi

if [[ "${DEPLOY_IMAGE}" == "true" ]]; then
  require_cmd gh

  echo "Triggering GitHub Actions MCP image deployment on ${DEPLOY_BRANCH}"
  gh workflow run deploy-cloud-run.yml \
    --repo "${GITHUB_REPOSITORY}" \
    --ref "${DEPLOY_BRANCH}" \
    -f deploy_image=true \
    -f apply_terraform=false

  echo "GitHub Actions image deployment triggered."
fi

cat <<EOF
Bootstrap complete.

Terraform state backend:
  bucket: gs://${STATE_BUCKET}
  prefix: ${TF_STATE_PREFIX}

Local Terraform variables:
  infra/remote-mcp/bootstrap.auto.tfvars

Next:
  Review and apply Terraform manually:
    terraform -chdir=infra/remote-mcp plan
    terraform -chdir=infra/remote-mcp apply

  Or rerun bootstrap as the one-command setup path:
  ./bootstrap.sh \\
    --project-id ${PROJECT_ID} \\
    --state-bucket ${STATE_BUCKET} \\
    --github-repository ${GITHUB_REPOSITORY} \\
    --region ${REGION} \\
    --tf-state-prefix ${TF_STATE_PREFIX} \\
    --deploy-branch ${DEPLOY_BRANCH} \\
    --terraform-deployer-service-account-id ${TERRAFORM_DEPLOYER_SERVICE_ACCOUNT_ID} \\
    --apply \\
    --set-github-vars \\
    --deploy-image

If you apply Terraform manually, add these values manually or rerun bootstrap
with --set-github-vars after apply:
  GCP_PROJECT_ID=${PROJECT_ID}
  GCP_REGION=${REGION}
  CLOUD_RUN_SERVICE=\$(terraform -chdir=infra/remote-mcp output -raw service_name)
  ARTIFACT_REGISTRY_REPOSITORY=\$(terraform -chdir=infra/remote-mcp output -raw artifact_repository_url)
  WIF_PROVIDER=\$(terraform -chdir=infra/remote-mcp output -raw github_actions_workload_identity_provider)
  DEPLOYER_SERVICE_ACCOUNT=\$(terraform -chdir=infra/remote-mcp output -raw ci_deployer_service_account_email)
  TERRAFORM_DEPLOYER_SERVICE_ACCOUNT=\$(terraform -chdir=infra/remote-mcp output -raw terraform_deployer_service_account_email)
  TERRAFORM_STATE_BUCKET=${STATE_BUCKET}
  TERRAFORM_STATE_PREFIX=${TF_STATE_PREFIX}
EOF
