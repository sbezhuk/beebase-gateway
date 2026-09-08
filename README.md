# beebase-gateway

Single HTTP entry point for BeeBase, an open-source backend for a
beekeeper management application split into microservices. Reverse-proxies
requests to the right backend service; holds no business logic, no
database, and no state of its own.

## The full picture

| Service | Repo | Owns |
|---|---|---|
| auth-service | [beebase-auth-service](https://github.com/sbezhuk/beebase-auth-service) | users, refresh tokens, JWT issuing |
| apiary-service | [beebase-apiary-service](https://github.com/sbezhuk/beebase-apiary-service) | apiaries |
| hive-service | [beebase-hive-service](https://github.com/sbezhuk/beebase-hive-service) | hives |
| inspection-service | [beebase-inspection-service](https://github.com/sbezhuk/beebase-inspection-service) | inspections |
| media-service | [beebase-media-service](https://github.com/sbezhuk/beebase-media-service) | file/media uploads (photos, PDFs, XML, etc.), generically attached to an apiary or a hive |
| statistics-service | [beebase-statistics-service](https://github.com/sbezhuk/beebase-statistics-service) | Dashboard statistics, computed fresh from the services above on every request — holds no data of its own |
| gateway (this repo) | `beebase-gateway` | single entry point, routes to the above |

[beebase-common](https://github.com/sbezhuk/beebase-common) is a shared Go
module every service (including this one) depends on: structured logging,
JSON response/error helpers, graceful shutdown, and — for the backend
services — access-token verification.

### Routing

Paths are forwarded unchanged (no prefix stripping), since every backend
service already routes its own full path:

| Path prefix | Forwarded to |
|---|---|
| `/api/v1/auth/*` | auth-service |
| `/.well-known/jwks.json` | auth-service |
| `/api/v1/profile` | auth-service |
| `/api/v1/apiaries/*` | apiary-service |
| `/api/v1/hives/{hiveId}/inspections` | inspection-service (checked before the `/api/v1/hives/*` wildcard below, since it'd otherwise match too) |
| `/api/v1/hives/*` | hive-service |
| `/api/v1/inspections/*` | inspection-service |
| `/api/v1/media/*` | media-service |
| `/api/v1/statistics/*` | statistics-service |
| `/health`, `/ready` | answered by the gateway itself (it has no dependencies of its own to check) |

### Trust model

auth-service holds the only private key in the deployment and is the only
service that can mint access tokens. Every other backend service verifies
tokens against auth-service's public key, fetched live from
`/.well-known/jwks.json`, and can never forge one. The gateway itself
never inspects or verifies tokens — it just forwards the Authorization
header through untouched, and whichever backend service receives the
request verifies it.

## Running the full stack

Clone every service as a sibling of this repo, using its GitHub name as
the directory name:

```bash
cd .. # the parent directory that will hold all five repos
git clone https://github.com/sbezhuk/beebase-auth-service.git
git clone https://github.com/sbezhuk/beebase-apiary-service.git
git clone https://github.com/sbezhuk/beebase-hive-service.git
git clone https://github.com/sbezhuk/beebase-inspection-service.git
git clone https://github.com/sbezhuk/beebase-media-service.git
git clone https://github.com/sbezhuk/beebase-statistics-service.git
# beebase-gateway is this repo
```

Then, from this repo:

```bash
cp .env.example .env
(cd ../beebase-auth-service && make keygen)    # paste the JWT_PRIVATE_KEY line into .env
make up                                        # docker compose up --build
```

This starts every service, its own Postgres database, applies each
service's migrations once, and brings up the gateway last (after every
backend service reports healthy). Verify:

```bash
curl http://localhost:8080/health
curl http://localhost:8080/.well-known/jwks.json

curl -X POST http://localhost:8080/api/v1/auth/register \
  -H 'Content-Type: application/json' \
  -d '{"email":"you@example.com","password":"supersecret"}'
```

Apiary/hive/inspection endpoints aren't implemented yet (those services
are still just foundations) — this stack proves the routing and trust
model end to end, ahead of those features landing.

### Running the gateway against services on the host (no Docker)

Point each `*_SERVICE_URL` in `.env` at wherever that service's `go run`
is listening (see `.env.example`), then `make run`.

## Configuration

All configuration is via environment variables (see
[.env.example](.env.example) for the full list — it is a template only,
never read by the app, Docker Compose, or deployment tooling; copy it
once to create your real `.env`, which is what actually gets loaded).
Production configuration is generated at deploy time on the EC2 host
from AWS SSM Parameter Store (see [deploy/deploy.sh](deploy/deploy.sh),
which writes a fresh `/opt/beebase/config/.env` and fails the deploy if
the expected parameters aren't there) — `.env.example` is never used as
a fallback, in development or in production.

| Variable | Default | Description |
|---|---|---|
| `APP_ENV` | `development` | `development` or `production` |
| `LOG_LEVEL` | `info` | `debug`, `info`, `warn`, `error` |
| `HTTP_PORT` | `8080` | Port the gateway listens on |
| `HTTP_READ_TIMEOUT` | `5s` | Request read timeout |
| `HTTP_WRITE_TIMEOUT` | `10s` | Response write timeout |
| `HTTP_IDLE_TIMEOUT` | `60s` | Keep-alive idle timeout |
| `HTTP_SHUTDOWN_TIMEOUT` | `15s` | Max time to wait for graceful shutdown |
| `AUTH_SERVICE_URL` | *(required)* | Base URL of auth-service |
| `APIARY_SERVICE_URL` | *(required)* | Base URL of apiary-service |
| `HIVE_SERVICE_URL` | *(required)* | Base URL of hive-service |
| `INSPECTION_SERVICE_URL` | *(required)* | Base URL of inspection-service |
| `MEDIA_SERVICE_URL` | *(required)* | Base URL of media-service |
| `STATISTICS_SERVICE_URL` | *(required)* | Base URL of statistics-service |

## Production deployment

BeeBase is **7 independent Git repositories**, each with its own
GitHub Actions workflow, its own commit history, and its own Git SHA.
There is no single SHA that describes "the app" — a production release
is the combination of one specific, independently-chosen image tag per
service, and deployment tooling treats that combination, not any one
commit, as the unit that gets deployed.

### Per-service image tags

Each service repo has its own `.github/workflows/ci.yml`
(`Test → Build → push`, triggered only by pushing a Git tag matching
`v*` — never by a push to `main` or any other branch) that tags its
image with its own full Git commit SHA (`${{ github.sha }}`) — never
the tag name, never `latest`, never a SHA belonging to a different
repository. Each run ends with a GitHub Actions summary that prints the
commit SHA in full, ready to paste into the production release
workflow's inputs below:

```text
beebase-gateway:5a066d9...
beebase-auth-service:0b4d246...
beebase-apiary-service:436efff...
beebase-hive-service:f9e257a...
beebase-inspection-service:8844c5b...
beebase-media-service:a5b903b...
beebase-statistics-service:a0877a0...
```

Each workflow authenticates to AWS via GitHub's OIDC federation
(`aws-actions/configure-aws-credentials`, assuming the
`beebase-prod-github-actions-ci` IAM role — see Terraform below) and
builds for `linux/arm64` (EC2 is Graviton) with Buildx + QEMU, exactly
like the retired Azure Pipelines template did. Services with a database
(auth/apiary/hive/inspection/media) also push a `Dockerfile.migrate`
image tagged `<sha>-migrate`.

[docker-compose.prod.yml](docker-compose.prod.yml) reflects the
per-service tagging directly: there is no shared `IMAGE_TAG`, only one
variable per service (`GATEWAY_IMAGE_TAG`, `AUTH_IMAGE_TAG`,
`APIARY_IMAGE_TAG`, `HIVE_IMAGE_TAG`, `INSPECTION_IMAGE_TAG`,
`MEDIA_IMAGE_TAG`, `STATISTICS_IMAGE_TAG`), all required with no
default. Migration images use the same variable, suffixed `-migrate`
(e.g. `${AUTH_IMAGE_TAG}-migrate`).

### Deployment bundle (beebase-gateway only)

After beebase-gateway's own image push, its `ci.yml` also tars up
[docker-compose.prod.yml](docker-compose.prod.yml) and [deploy/](deploy/)
exactly as they exist at that commit — no `.env`, no secrets — and
uploads it, via the same OIDC-assumed CI role, to:

```text
s3://beebase-production-976033326057/deploy-bundles/<commit-sha>/bundle.tar.gz
```

This is the exact bucket/prefix `terraform/modules/ec2-instance`'s
`user_data.sh.tftpl` already downloads from at boot
(`deployment_bundle_bucket` / `deployment_bundle_version` in
`terraform.tfvars`) — the CI job only ever gets `s3:PutObject` on this
one prefix, nothing broader. Like the Docker image, the object key is
the immutable commit SHA, never the tag name, and is never overwritten.

### Release manifests

A **release manifest** is what combines those 7 independent tags into
one deployable unit. It's a plain `KEY=VALUE` env file — the same shape
`docker compose --env-file` already expects, and the same shape
`deploy.sh` already writes production config in — parsed and validated
by [deploy/lib/manifest.sh](deploy/lib/manifest.sh):

```bash
# /opt/beebase/releases/2026.09.07-1.env
RELEASE=2026.09.07-1
CREATED_AT=2026-09-07T18:30:00Z
GATEWAY_IMAGE_TAG=5a066d9...
AUTH_IMAGE_TAG=0b4d246...
APIARY_IMAGE_TAG=436efff...
HIVE_IMAGE_TAG=f9e257a...
INSPECTION_IMAGE_TAG=8844c5b...
MEDIA_IMAGE_TAG=a5b903b...
STATISTICS_IMAGE_TAG=a0877a0...
```

`RELEASE` is an identifier for *this combination of versions* — a date
plus the release workflow's run number, e.g. `2026.09.07-1` — not a Git
SHA and not a substitute for one; it's only ever used for CloudWatch
log stream naming on containers that have no image tag of their own
(`edge`, `postgres-*`, `redis`). Manifests never contain secrets: those
come exclusively from the production `.env` on the host (see "Secrets,
images, 'no latest'" below) — SSM only ever supplies non-secret config
like `PUBLIC_DOMAIN`.

Manifests are **immutable**: once `<release>.env` exists at
`/opt/beebase/releases/`, nothing ever overwrites it — `deploy.sh`
refuses to touch it, and the release workflow refuses to create a
release id that already exists. Every past release stays on disk,
which is what makes rollback possible (see below).

### The production release workflow

[.github/workflows/production-release.yml](.github/workflows/production-release.yml)
is a separate, manual (`workflow_dispatch`-only) GitHub Actions workflow
in this repo — distinct from this repo's own `ci.yml` — that:

1. Takes the exact image tag for all 7 services as explicit inputs
   (`gateway_image_tag`, `auth_image_tag`, ...) — **never** assumes any
   two repositories share a SHA, and never auto-selects `latest`.
2. Builds and validates a new, immutable release manifest from those
   inputs, reusing `deploy/lib/manifest.sh`'s own validation rules
   (the workflow `source`s that file directly rather than
   reimplementing its rules).
3. Verifies every one of those images — and every migrate image —
   actually exists in ECR, and fails the run before anything is sent to
   EC2 if any one of them is missing.
4. Runs under the protected `production` GitHub Environment (see
   "GitHub configuration required" below) — a required-reviewers rule
   there gates both jobs on one manual approval.
5. Ships the manifest to the EC2 host and runs `deploy.sh` against it,
   via the same `aws ssm send-command` + poll pattern the old per-service
   Azure Pipelines Deploy stage used to run individually.

```text
Individual service workflows (7x, each its own repo)
  Test → Build → push image tagged with its own SHA
        │
        ▼
Production release workflow (workflow_dispatch, operator supplies
all 7 SHAs explicitly)
  build + validate release manifest (deploy/lib/manifest.sh)
  → verify every image + migrate image exists in ECR
  → production Environment approval
  → send manifest + deploy.sh invocation to EC2 via SSM
        │
        ▼
deploy.sh <manifest>
  validate manifest → verify every image exists in ECR
  → pull → start data layer → run migrations
  → recreate app stack → health checks → smoke tests
  → mark this release `current`
```

Each service's own workflow only ever builds and pushes — it never
deploys. Only the production release workflow ever calls `deploy.sh`,
and only with a full 7-service manifest. `deploy.sh` itself is
unchanged and unduplicated: the workflow orchestrates *when* it runs,
never *what* it does.

The workflow also accepts an optional `rollback_release` input (an
existing release id already under `/opt/beebase/releases/`) that skips
straight to calling `deploy.sh` against that manifest — no rebuild, no
re-validation on the runner (deploy.sh re-validates on the host
regardless), see Rollback below.

### Deploying and rolling back

`deploy.sh` takes a manifest path, not a Git SHA:

```bash
deploy.sh /opt/beebase/releases/2026.09.07-1.env
```

It validates the manifest (every service tag present, shaped like a
real Git SHA, never `latest`), loads the seven production secrets from
the existing `/opt/beebase/config/.env` (failing clearly if that file
or any of those secrets is missing — see "Secrets, images, 'no latest'"
below), refreshes everything else in that same file (mode `0600`) —
`ECR_REGISTRY`, `AWS_REGION`, the manifest's tags, and non-secret SSM
config — around them without touching the secrets, authenticates to ECR
via the EC2 instance role, **verifies every referenced image and
migrate image actually exists in ECR before touching anything running**,
pulls, starts the data layer, runs each service's own migration image,
recreates the application stack, waits for every health check, runs
the gateway smoke tests, and — only once all of that has passed —
updates `/opt/beebase/releases/current` to point at the manifest it
just deployed. Any failure at any step aborts the deploy without
touching the previously-running containers.

**Rollback** is just deploying an older manifest — nothing is rebuilt.
Either run `deploy.sh` directly on the host:

```bash
deploy.sh /opt/beebase/releases/2026.09.07-1.env   # redeploy exactly that combination of images
```

or trigger the production release workflow with `rollback_release` set
to `2026.09.07-1` and every `*_image_tag` input left blank.

Since every past manifest stays on disk and every image is immutable in
ECR (`image_tag_mutability = "IMMUTABLE"`, enforced in Terraform), this
redeploys the exact bytes that ran in that release — not a rebuild, not
an approximation. `/opt/beebase/releases/current` (a symlink deploy.sh
updates only after a fully successful deploy) always tells you which
manifest is live.

### Secrets, images, "no latest"

- The seven production secrets — `JWT_PRIVATE_KEY`, `TOTP_ENCRYPTION_KEY`,
  and the five `POSTGRES_*_PASSWORD` variables (the full list lives in
  `deploy/lib/secrets.sh`) — come **exclusively** from the production
  `.env` at `/opt/beebase/config/.env`. An operator provisions that file
  once, by hand, from `deploy/.env.example`
  (`cp deploy/.env.example /opt/beebase/config/.env && chmod 600 ...`
  then filling in real values) — never from Git, GitHub Actions, release
  manifests, Docker images, or AWS SSM Parameter Store. `deploy.sh`
  requires the file and every one of these seven keys to already be
  present and non-empty before it will deploy, and never logs their
  values; if a stale SecureString with one of these names is still
  sitting in SSM, `deploy.sh` ignores it outright (logging only that it
  did, by key name) rather than letting it override the `.env`.
- Non-secret production config (`PUBLIC_DOMAIN`, `STORAGE_BUCKET`, ...)
  is unaffected by the above: it still comes from AWS SSM Parameter
  Store under `/beebase/prod/*` and is refreshed into the same `.env` on
  every deploy, exactly as before. GitHub Actions never has read access
  to `/beebase/prod/*` either way — see the IAM policies in
  `terraform/modules/github-oidc`.
- Images come from ECR, one repository per service. CI pushes with the
  `beebase-prod-github-actions-ci` role (push-only, scoped to the 7
  BeeBase ECR repositories); the production host pulls with its own EC2
  IAM role, unrelated to either GitHub Actions role, no static AWS
  credentials anywhere.
- No AWS access keys are ever stored in GitHub: both GitHub Actions IAM
  roles are assumed via OIDC federation
  (`token.actions.githubusercontent.com`), scoped by repository and (for
  the release role) by GitHub Environment — see "AWS IAM / OIDC" below.
- `latest` is never used anywhere in this pipeline: `deploy.sh` rejects
  it outright, `docker-compose.prod.yml` has no image reference without
  a `${...:?...}`-guarded tag variable, and a missing ECR image fails
  the deploy (or the release workflow, before it ever reaches EC2)
  rather than falling back to whatever tag happens to already be
  running.

### Tests

```bash
make deploy-test   # deploy/tests/run_all.sh:
                    #   - manifest parsing/validation (deploy/lib/manifest.sh)
                    #   - the seven-secret allowlist and validation (deploy/lib/secrets.sh)
                    #   - docker compose config resolves each service's own tag
                    #   - a mocked deploy.sh run (fail-fast on a missing ECR image or
                    #     incomplete production .env, secrets carried over unchanged,
                    #     a stale SSM secret ignored, success path)
                    #   - every service's .github/workflows/ci.yml against the CI checklist
                    #   - .github/workflows/production-release.yml against the release checklist
                    # No AWS account or Docker daemon required.
```

`actionlint` (https://github.com/rhysd/actionlint) is recommended for
validating workflow YAML/embedded shell beyond what `make deploy-test`
checks structurally: `actionlint .github/workflows/*.yml`.

### AWS IAM / OIDC (Terraform)

`terraform/modules/github-oidc` creates:

- One `aws_iam_openid_connect_provider` for
  `token.actions.githubusercontent.com` (thumbprint fetched live via the
  `tls` provider, not hardcoded).
- **`<name_prefix>-github-actions-ci`** — assumable only by a workflow
  run from a pushed `v*` tag in one of the 7 service repos
  (`repo:<org>/<repo>:ref:refs/tags/v*`, matched with `StringLike` since
  the tag name itself varies per release). Permissions: ECR authenticate
  + push, scoped to the 7 BeeBase ECR repository ARNs, plus (gateway's
  workflow only, by prefix) `s3:PutObject` under `deploy-bundles/*` in
  the media bucket for the deployment bundle below. Nothing else — in
  particular, no `/beebase/prod` SSM access.
- **`<name_prefix>-github-actions-release`** — assumable only by a
  workflow run in `beebase-gateway` under the `production` GitHub
  Environment (`repo:<org>/beebase-gateway:environment:production`).
  Permissions: `ecr:DescribeImages`/`DescribeRepositories` (read-only,
  scoped to the 7 repo ARNs), `ssm:SendCommand` (scoped to the one
  production EC2 instance + the `AWS-RunShellScript` document),
  `ssm:GetCommandInvocation` (SSM supports no resource-level scoping for
  this action — this is the narrowest it can be), and
  `sts:GetCallerIdentity`. No EC2 administration, no
  `/beebase/prod/*` SSM access, no S3 access.

Both roles are wired into `terraform/environments/prod/main.tf`
(`module "github_oidc"`), reusing the existing `local.service_names`
list and the existing `module.ecr`/`module.ec2` outputs — no new ECR
repositories, no EC2/SSM/S3 redesign.

### GitHub configuration required (manual, one-time)

- Run `terraform apply` (see `terraform/environments/prod`) to create
  the OIDC provider and the two IAM roles, then read
  `github_actions_ci_role_arn` and `github_actions_release_role_arn`
  from its outputs.
- In **each of the 7 service repos**, add a repository variable (not a
  secret — a role ARN isn't sensitive) `AWS_CI_ROLE_ARN` set to
  `github_actions_ci_role_arn`. (If these ever move under a GitHub
  *organization* rather than a personal account, this can become one
  org-level variable instead of 7 repo-level copies.)
- In **beebase-gateway only**, add two more repository variables:
  `AWS_RELEASE_ROLE_ARN` (`github_actions_release_role_arn`) and
  `EC2_INSTANCE_ID` (also not secrets).
- In **beebase-gateway**, create a GitHub Environment named
  `production` (Settings → Environments) and add at least one required
  reviewer — this is what gates the release workflow on a manual
  approval; Terraform's trust policy already restricts the release IAM
  role to workflow runs under this exact Environment name.
- None of the above are GitHub *Secrets* — no AWS credential, of any
  kind, is ever stored in this repo. The only real secrets in this
  whole system (`JWT_PRIVATE_KEY`, `POSTGRES_*_PASSWORD`, ...) live
  exclusively in the production `.env` on the EC2 host and are never
  exposed to GitHub Actions, AWS SSM Parameter Store, or this repo at
  all.

### EC2 bootstrap requirements

- `/opt/beebase/releases/` now exists from first boot (Terraform's
  `user_data.sh.tftpl`) — release manifests and the `current` symlink
  live there.
- `/opt/beebase/deploy/` (deploy.sh, `lib/manifest.sh`, `lib/secrets.sh`,
  and the other `deploy/*.sh` ops scripts) and
  `/opt/beebase/compose/docker-compose.prod.yml` are still
  bootstrapped/updated manually, same as before this change — they
  change rarely, unlike the release manifests deployed on every run.
  When updating them, copy `deploy/lib/manifest.sh` and
  `deploy/lib/secrets.sh` alongside `deploy/deploy.sh` — deploy.sh
  sources both by relative path.
- `/opt/beebase/config/.env` must be provisioned **once**, by hand,
  before the first deploy: `cp deploy/.env.example
  /opt/beebase/config/.env`, `chmod 600` it, then fill in real values
  for the seven secrets it lists. `deploy.sh` refuses to deploy — with a
  clear error, nothing printed — if this file or any of those seven
  values is missing; it never creates or completes this file itself.

## Project structure

```
cmd/gateway/              entry point: wires config, logger, proxies, server
internal/
  config/                   environment-based configuration
  proxy/                     builds a reverse proxy to one upstream service
  transport/http/           chi router: health/ready + proxy mounts
.github/workflows/
  ci.yml                     this repo's own Test → Build → push (gateway image)
  production-release.yml     resolves all 7 services' SHAs into a manifest, deploys it
deploy/
  deploy.sh                  deploys one release manifest to the production stack
  lib/manifest.sh             manifest parsing/validation (shared by deploy.sh and its tests)
  lib/secrets.sh               the seven-secret allowlist + production .env validation
  .env.example                 template for /opt/beebase/config/.env — placeholders only
  tests/                      deploy-tooling + workflow tests — see `make deploy-test`
  Caddyfile, backup-postgres.sh, healthcheck-containers.sh, systemd/
```

## Development

```bash
make run     # go run ./cmd/gateway (point *_SERVICE_URL at running services)
make fmt     # go fmt ./...
make vet     # go vet ./...
make build   # build binary into bin/

make up      # docker compose up --build — the full stack
make down    # stop everything
make logs    # tail every service's logs
make ps      # status of every service
```
