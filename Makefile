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

## --- Helm chart ------------------------------------------------------------

CHART_DIR   ?= charts/hello-world
KIND_CLUSTER?= hello-world
KIND_IMAGE  ?= hello-world:ci

.PHONY: helm-lint
helm-lint: ## Lint the chart against both default and kind values
	helm lint $(CHART_DIR)
	helm lint $(CHART_DIR) --values $(CHART_DIR)/ci/kind-values.yaml

.PHONY: helm-template
helm-template: ## Render the chart with default values
	helm template hello-world $(CHART_DIR)

.PHONY: helm-package
helm-package: ## Package the chart into dist/
	mkdir -p dist
	helm package $(CHART_DIR) --destination dist
	@echo "packaged into dist/"

.PHONY: kind-up
kind-up: ## Create the 3-zone kind cluster and load the app image
	scripts/kind-up.sh $(KIND_IMAGE)

.PHONY: kind-down
kind-down: ## Delete the kind cluster
	kind delete cluster --name $(KIND_CLUSTER)

.PHONY: chart-test
chart-test: ## Run the full chart test suite against kind
	scripts/chart-test.sh

.PHONY: chart-test-keep
chart-test-keep: ## Same, but leave the release installed for inspection
	scripts/chart-test.sh --keep

## --- Terraform --------------------------------------------------------------

TF_DIR   ?= terraform/eks
TF_VARS  ?= environments/dev.tfvars

.PHONY: tf-fmt
tf-fmt: ## Format all Terraform
	terraform fmt -recursive terraform

.PHONY: tf-fmt-check
tf-fmt-check: ## Fail if any Terraform is unformatted
	terraform fmt -recursive -check -diff terraform

.PHONY: tf-init
tf-init: ## Initialise the EKS configuration
	cd $(TF_DIR) && terraform init

.PHONY: tf-validate
tf-validate: ## Validate both Terraform configurations
	cd $(TF_DIR) && terraform init -backend=false -input=false >/dev/null && terraform validate
	cd terraform/bootstrap && terraform init -backend=false -input=false >/dev/null && terraform validate

.PHONY: tf-test
tf-test: ## Run the Terraform guard tests (mocked, no AWS credentials needed)
	cd $(TF_DIR) && terraform test

.PHONY: tf-plan
tf-plan: ## Plan the EKS cluster (needs AWS credentials)
	cd $(TF_DIR) && terraform plan -var-file=$(TF_VARS)

.PHONY: tf-apply
tf-apply: ## Create the EKS cluster (COSTS MONEY, ~Rs 30/hour)
	cd $(TF_DIR) && terraform apply -var-file=$(TF_VARS)

.PHONY: tf-destroy
tf-destroy: ## Destroy the EKS cluster
	cd $(TF_DIR) && terraform destroy -var-file=$(TF_VARS)

.PHONY: tf-check
tf-check: tf-fmt-check tf-validate tf-test ## All Terraform checks that need no AWS credentials

.PHONY: kubeconfig
kubeconfig: ## Point kubectl at the provisioned cluster
	cd $(TF_DIR) && $$(terraform output -raw configure_kubectl)

.PHONY: clean
clean: ## Remove build artefacts
	rm -rf bin dist coverage.html $(APP_DIR)/coverage.out
