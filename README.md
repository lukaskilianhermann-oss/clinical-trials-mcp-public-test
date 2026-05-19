# clinical-trials-mcp

Clinical Trials MCP is a Streamable HTTP MCP server for public clinical trial
registry data. It exposes a small set of Trial Tools backed by
ClinicalTrials.gov and EU Clinical Trials.

The service is intentionally only the MCP server. There is no ADK agent,
evaluation harness, frontend, or Python runtime in this repository.

## Repository Layout

```text
clinical-trials-mcp/
+-- apps/clinical-trials-mcp/      # Go MCP server
+-- infra/                         # Terraform for Cloud Run
+-- bootstrap.sh                   # One-time GCP/Terraform bootstrap
+-- .github/workflows/             # CI and Cloud Run deployment
```

## Requirements

- Go 1.25+
- Docker
- Terraform 1.6+
- Google Cloud SDK
- GitHub CLI (`gh`), authenticated with permission to set repository variables

## Run Locally

```bash
cd apps/clinical-trials-mcp
go run .
```

The server listens on `127.0.0.1:8001` by default and exposes:

- MCP endpoint: `http://127.0.0.1:8001/mcp`
- Health check: `http://127.0.0.1:8001/healthz`

Runtime environment variables:

| Variable | Default |
| --- | --- |
| `MCP_HOST` | `127.0.0.1` |
| `PORT` | `8001` |
| `MCP_PORT` | `8001` |
| `MCP_PATH` | `/mcp` |
| `CT_API_BASE_URL` | `https://clinicaltrials.gov/api/v2` |
| `EU_CT_API_BASE_URL` | `https://euclinicaltrials.eu/ctis-public-api` |
| `CT_REQUEST_TIMEOUT_SECONDS` | `30` |
| `CT_MAX_PAGE_SIZE` | `25` |

## Deployment Guide On GCP

The deployment target is Cloud Run. Terraform owns the Google Cloud
infrastructure, and GitHub Actions owns application image rollouts after the
first setup. The Cloud Run service is intentionally public by default for
self-hosted MCP use; `public_access_enabled` is the single Terraform switch that
controls that behavior.

### 1. Fork And Choose Values

You need these values:

| Value | Example |
| --- | --- |
| `PROJECT_ID` | `my-gcp-project` |
| `REGION` | `europe-west3` |
| `STATE_BUCKET` | `my-gcp-project-terraform-state` |
| `GITHUB_REPOSITORY` | `owner/clinical-trials-mcp` |

`STATE_BUCKET` must be globally unique. The bootstrap script creates it if it
does not exist.

### 2. Authenticate Locally

```bash
gcloud auth login
gcloud config set project <PROJECT_ID>
gh auth login
```

Your Google account needs permission to enable APIs, create service accounts,
create IAM bindings, create a GCS bucket, create Artifact Registry, and create
Cloud Run services. Your GitHub account needs permission to set repository
variables.

### 3. Bootstrap Infrastructure

Run this from the repository root:

```bash
./bootstrap.sh \
  --project-id <PROJECT_ID> \
  --state-bucket <STATE_BUCKET> \
  --github-repository <GITHUB_REPOSITORY> \
  --region <REGION> \
  --apply \
  --set-github-vars
```

The script:

- enables the bootstrap Google Cloud APIs
- creates and configures the Terraform state bucket
- creates the bootstrap-owned Terraform deployer service account
- writes `infra/remote-mcp/bootstrap.auto.tfvars`
- initializes Terraform with the GCS backend
- applies the Cloud Run, Artifact Registry, service account, IAM, and Workload
  Identity Federation resources
- writes the required GitHub repository variables with `gh variable set`

Terraform creates the first Cloud Run service with Google Cloud's sample
`us-docker.pkg.dev/cloudrun/container/hello` image. That image is only a
placeholder so the service exists before CI/CD builds the real MCP container.

### 4. Push To Deploy The MCP Image

Commit the repository and push to `main`:

```bash
git push origin main
```

GitHub Actions will build the Go MCP image, push it to Artifact Registry, and
deploy a new Cloud Run revision. After that first image rollout, the public MCP
endpoint is:

```text
https://<cloud-run-service-url>/mcp
```

You can read the exact URL with:

```bash
terraform -chdir=infra/remote-mcp output -raw mcp_url
```

### CI/CD Behavior

`.github/workflows/deploy-cloud-run.yml` keeps app and infrastructure changes
separate:

- App changes run Go tests, build the Docker image, push it to Artifact
  Registry, and deploy a new Cloud Run revision.
- Infrastructure changes validate Terraform on pull requests without cloud
  authentication.
- On `main`, infrastructure changes run `terraform apply`.
- If one commit changes both app and infrastructure, Terraform applies first,
  then the image rollout runs.

Only push jobs on the configured deploy branch can request GitHub OIDC tokens
for Google Cloud. Pull request jobs do not get `id-token: write`.

### Local Validation

```bash
cd apps/clinical-trials-mcp && go test ./...
cd ../..
docker build -f apps/clinical-trials-mcp/Dockerfile -t clinical-trials-mcp .
terraform -chdir=infra/remote-mcp fmt -check -recursive
terraform -chdir=infra/remote-mcp init -backend=false
terraform -chdir=infra/remote-mcp validate
```

CI runs `go test -race ./...` on Linux. On Windows, `go test -race` requires a
C compiler; use `go test ./...` locally unless you have one installed.
