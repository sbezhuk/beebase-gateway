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
(cd ../beebase-auth-service && make keygen)   # paste the JWT_PRIVATE_KEY line into .env
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

BeeBase is **7 independent Git repositories**, each with its own Azure
DevOps pipeline, its own commit history, and its own Git SHA. There is
no single SHA that describes "the app" — a production release is the
combination of one specific, independently-chosen image tag per
service, and deployment tooling treats that combination, not any one
commit, as the unit that gets deployed.

### Per-service image tags

Each service pipeline (`Test → Build → push`, defined once in
[beebase-common's shared template](https://github.com/sbezhuk/beebase-common/blob/main/ci/azure-pipelines-service-template.yml)
and extended by each repo's own `azure-pipelines.yml`) tags its image
with its own full Git commit SHA — never `latest`, never a SHA
belonging to a different repository:

```text
beebase-gateway:5a066d9...
beebase-auth-service:0b4d246...
beebase-apiary-service:436efff...
beebase-hive-service:f9e257a...
beebase-inspection-service:8844c5b...
beebase-media-service:a5b903b...
beebase-statistics-service:a0877a0...
```

[docker-compose.prod.yml](docker-compose.prod.yml) reflects this
directly: there is no shared `IMAGE_TAG`, only one variable per service
(`GATEWAY_IMAGE_TAG`, `AUTH_IMAGE_TAG`, `APIARY_IMAGE_TAG`,
`HIVE_IMAGE_TAG`, `INSPECTION_IMAGE_TAG`, `MEDIA_IMAGE_TAG`,
`STATISTICS_IMAGE_TAG`), all required with no default. Migration images
use the same variable, suffixed `-migrate` (e.g.
`${AUTH_IMAGE_TAG}-migrate`).

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
plus an Azure DevOps Build ID, e.g. `2026.09.07-1` — not a Git SHA and
not a substitute for one; it's only ever used for CloudWatch log stream
naming on containers that have no image tag of their own (`edge`,
`postgres-*`, `redis`). Manifests never contain secrets: those still
come from AWS SSM Parameter Store on every deploy, exactly as before.

Manifests are **immutable**: once `<release>.env` exists at
`/opt/beebase/releases/`, nothing ever overwrites it — `deploy.sh`
refuses to touch it, and the release pipeline refuses to create a
release id that already exists. Every past release stays on disk,
which is what makes rollback possible (see below).

### The release pipeline

[deploy/azure-pipelines-release.yml](deploy/azure-pipelines-release.yml)
is a separate Azure DevOps pipeline (registered independently from this
repo's own `Test → Build → push` pipeline) that:

1. Reads each of the 7 service pipelines' `resources.pipeline.<alias>.sourceCommit`
   — the exact SHA that pipeline most recently built and pushed —
   **independently per service**, never assuming they match.
2. Writes those 7 tags into a new, immutable release manifest.
3. Ships the manifest to the EC2 host and runs `deploy.sh` against it,
   via the same `aws ssm send-command` + poll pattern each service
   pipeline used to run individually — see the flow below.

```text
Individual service pipelines (7x)
  Test → Build → push image tagged with its own SHA
        │
        ▼
Production release pipeline (run on demand, once every
service you want released has a green Build on main)
  resolve each service's latest SHA independently
  → write immutable release manifest
  → send manifest + deploy.sh invocation to EC2 via SSM
        │
        ▼
deploy.sh <manifest>
  validate manifest → verify every image exists in ECR
  → pull → start data layer → run migrations
  → recreate app stack → health checks → smoke tests
  → mark this release `current`
```

Each service's own pipeline no longer deploys anything by itself — it
stops after pushing its image. Only the release pipeline ever calls
`deploy.sh`, and only with a full 7-service manifest.

### Deploying and rolling back

`deploy.sh` takes a manifest path, not a Git SHA:

```bash
deploy.sh /opt/beebase/releases/2026.09.07-1.env
```

It validates the manifest (every service tag present, shaped like a
real Git SHA, never `latest`), regenerates `/opt/beebase/config/.env`
(mode `0600`) from SSM plus the manifest's tags, authenticates to ECR
via the EC2 instance role, **verifies every referenced image and
migrate image actually exists in ECR before touching anything running**,
pulls, starts the data layer, runs each service's own migration image,
recreates the application stack, waits for every health check, runs
the gateway smoke tests, and — only once all of that has passed —
updates `/opt/beebase/releases/current` to point at the manifest it
just deployed. Any failure at any step aborts the deploy without
touching the previously-running containers.

**Rollback** is just deploying an older manifest — nothing is rebuilt:

```bash
deploy.sh /opt/beebase/releases/2026.09.07-1.env   # redeploy exactly that combination of images
```

Since every past manifest stays on disk and every image is immutable in
ECR (`image_tag_mutability = "IMMUTABLE"`, enforced in Terraform), this
redeploys the exact bytes that ran in that release — not a rebuild, not
an approximation. `/opt/beebase/releases/current` (a symlink deploy.sh
updates only after a fully successful deploy) always tells you which
manifest is live.

### Secrets, images, "no latest"

- Secrets (`JWT_PRIVATE_KEY`, `TOTP_ENCRYPTION_KEY`, `POSTGRES_*_PASSWORD`,
  ...) come from AWS SSM Parameter Store under `/beebase/prod/*` on
  every deploy — never from Git, release manifests, or Docker images.
- Images come from ECR, one repository per service, pulled with the EC2
  instance's IAM role — no static AWS credentials anywhere on the host.
- `latest` is never used anywhere in this pipeline: `deploy.sh` rejects
  it outright, `docker-compose.prod.yml` has no image reference without
  a `${...:?...}`-guarded tag variable, and a missing ECR image fails
  the deploy rather than falling back to whatever tag happens to
  already be running.

### Tests

```bash
make deploy-test   # deploy/tests/run_all.sh — manifest parsing/validation,
                    # docker compose config, and a mocked deploy.sh run
                    # (no AWS account or Docker daemon required)
```

### Azure DevOps configuration required (manual, one-time)

- The "AWS Toolkit for Azure DevOps" marketplace extension, plus an
  `AWS-BeeBase-OIDC` service connection (OIDC/workload-identity
  federation — no long-lived AWS keys stored in Azure DevOps).
- A `beebase-prod-pipeline` variable group with `AWS_REGION`,
  `AWS_ACCOUNT_ID`, `EC2_INSTANCE_ID`.
- A `beebase-production` Environment (used by both the per-service
  Build pipelines' approval gate history and the release pipeline).
- Each of the 7 service repos' `azure-pipelines.yml` already exists and
  extends `beebase-common`'s shared template — no change needed beyond
  bumping the `ref:` tag when the template changes (see
  [beebase-common's CHANGELOG/tags](https://github.com/sbezhuk/beebase-common/tags)).
- **New:** register `deploy/azure-pipelines-release.yml` from this repo
  as its own separate Azure DevOps pipeline (distinct from this repo's
  existing `Test → Build → push` pipeline), and grant it permission to
  consume the other 6 services' pipelines as resources (Azure DevOps
  prompts for this authorization the first time the pipeline resolves a
  resource it doesn't yet have access to).

### EC2 bootstrap requirements

- `/opt/beebase/releases/` now exists from first boot (Terraform's
  `user_data.sh.tftpl`) — release manifests and the `current` symlink
  live there.
- `/opt/beebase/deploy/` (deploy.sh, `lib/manifest.sh`, and the other
  `deploy/*.sh` ops scripts) and `/opt/beebase/compose/docker-compose.prod.yml`
  are still bootstrapped/updated manually, same as before this change —
  they change rarely, unlike the release manifests deployed on every
  run. When updating them, copy `deploy/lib/manifest.sh` alongside
  `deploy/deploy.sh` — deploy.sh sources it by relative path.

## Project structure

```
cmd/gateway/              entry point: wires config, logger, proxies, server
internal/
  config/                   environment-based configuration
  proxy/                     builds a reverse proxy to one upstream service
  transport/http/           chi router: health/ready + proxy mounts
deploy/
  deploy.sh                  deploys one release manifest to the production stack
  azure-pipelines-release.yml  resolves all 7 services' SHAs into a manifest, deploys it
  lib/manifest.sh             manifest parsing/validation (shared by deploy.sh and its tests)
  tests/                      deploy-tooling tests — see `make deploy-test`
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
