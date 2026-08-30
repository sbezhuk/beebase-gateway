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
| `/api/v1/apiaries/*` | apiary-service |
| `/api/v1/hives/{hiveId}/inspections` | inspection-service (checked before the `/api/v1/hives/*` wildcard below, since it'd otherwise match too) |
| `/api/v1/hives/*` | hive-service |
| `/api/v1/inspections/*` | inspection-service |
| `/api/v1/media/*` | media-service |
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

## Project structure

```
cmd/gateway/              entry point: wires config, logger, proxies, server
internal/
  config/                   environment-based configuration
  proxy/                     builds a reverse proxy to one upstream service
  transport/http/           chi router: health/ready + proxy mounts
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
