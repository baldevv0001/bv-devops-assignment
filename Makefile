# Entry point for every task in this repository. CI calls these same targets,
# so what runs locally is what runs in the pipeline.

SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

APP_DIR    ?= app
BINARY     ?= hello-world

# Override REGISTRY/IMAGE_NAME to publish somewhere other than Docker Hub.
REGISTRY   ?= docker.io
IMAGE_OWNER?= baldevv0001
IMAGE_NAME ?= hello-world
IMAGE      ?= $(REGISTRY)/$(IMAGE_OWNER)/$(IMAGE_NAME)

# Version defaults to the current git describe, falling back to the short SHA
# on a repository with no tags yet.
VERSION    ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
COMMIT     ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo none)
PLATFORMS  ?= linux/amd64,linux/arm64

GO_LDFLAGS := -s -w -X main.version=$(VERSION) -X main.commit=$(COMMIT)

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

## --- Application -----------------------------------------------------------

.PHONY: tidy
tidy: ## Sync go.mod/go.sum
	cd $(APP_DIR) && go mod tidy

.PHONY: fmt
fmt: ## Format Go sources
	cd $(APP_DIR) && gofmt -l -w .

.PHONY: fmt-check
fmt-check: ## Fail if any Go source is unformatted
	@cd $(APP_DIR) && out=$$(gofmt -l .); \
	if [[ -n "$$out" ]]; then echo "unformatted files:"; echo "$$out"; exit 1; fi
	@echo "gofmt: clean"

.PHONY: vet
vet: ## Run go vet
	cd $(APP_DIR) && go vet ./...

.PHONY: test
test: ## Run unit tests with coverage
	cd $(APP_DIR) && go test ./... -count=1 -cover

.PHONY: test-race
test-race: ## Run unit tests under the race detector (needs a C compiler)
	cd $(APP_DIR) && CGO_ENABLED=1 go test ./... -count=1 -race

.PHONY: cover
cover: ## Write an HTML coverage report to coverage.html
	cd $(APP_DIR) && go test ./... -count=1 -coverprofile=coverage.out \
		&& go tool cover -html=coverage.out -o ../coverage.html
	@echo "report: coverage.html"

.PHONY: build
build: ## Build the binary into bin/
	mkdir -p bin
	cd $(APP_DIR) && CGO_ENABLED=0 go build -trimpath -ldflags="$(GO_LDFLAGS)" \
		-o ../bin/$(BINARY) ./cmd/$(BINARY)
	@echo "built: bin/$(BINARY) ($(VERSION))"

.PHONY: run
run: ## Run the service locally on :8080 (metrics on :9090)
	cd $(APP_DIR) && go run ./cmd/$(BINARY)

.PHONY: check
check: fmt-check vet test ## Run all application checks

## --- Container -------------------------------------------------------------

.PHONY: docker-build
docker-build: ## Build the container image for the local platform
	docker build \
		--build-arg VERSION=$(VERSION) \
		--build-arg COMMIT=$(COMMIT) \
		-t $(IMAGE):$(VERSION) \
		-t $(IMAGE):latest \
		$(APP_DIR)
	@echo "built: $(IMAGE):$(VERSION)"

.PHONY: docker-buildx
docker-buildx: ## Build and push a multi-arch image (needs buildx + docker login)
	docker buildx build \
		--platform $(PLATFORMS) \
		--build-arg VERSION=$(VERSION) \
		--build-arg COMMIT=$(COMMIT) \
		-t $(IMAGE):$(VERSION) \
		-t $(IMAGE):latest \
		--push \
		$(APP_DIR)

.PHONY: docker-run
docker-run: ## Run the image locally, app on :8080 and metrics on :9090
	docker run --rm -p 8080:8080 -p 9090:9090 $(IMAGE):$(VERSION)

.PHONY: docker-smoke
docker-smoke: docker-build ## Build the image and assert every endpoint responds
	@scripts/smoke-test.sh $(IMAGE):$(VERSION)

.PHONY: clean
clean: ## Remove build artefacts
	rm -rf bin coverage.html $(APP_DIR)/coverage.out
