.PHONY: run build fmt vet test lint tidy \
	up down build-all logs ps

APP_NAME := gateway
BIN_DIR  := bin

run: ## Run the gateway locally (loads .env; point *_SERVICE_URL at running services).
	go run ./cmd/gateway

build: ## Build the gateway binary into bin/.
	CGO_ENABLED=0 go build -o $(BIN_DIR)/$(APP_NAME) ./cmd/gateway

fmt: ## Format all Go source.
	go fmt ./...

vet: ## Run go vet on all packages.
	go vet ./...

test: ## Run the unit test suite.
	go test ./... -v

lint: ## Run golangci-lint, if installed.
	golangci-lint run

tidy: ## Sync go.mod/go.sum with imports.
	go mod tidy

up: ## Start the full BeeBase stack (every service + this gateway). Needs sibling checkouts, see README.
	docker compose up --build

down: ## Stop and remove every service in the stack.
	docker compose down

build-all: ## Build every service's image without starting anything.
	docker compose build

logs: ## Tail every service's logs.
	docker compose logs -f

ps: ## Show the status of every service in the stack.
	docker compose ps
