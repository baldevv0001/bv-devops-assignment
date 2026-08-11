# syntax=docker/dockerfile:1

# ---------------------------------------------------------------------------
# Build stage
#
# Pinned to a patch version rather than a floating tag: the image a pipeline
# produces should depend only on what is committed, not on when it ran.
# ---------------------------------------------------------------------------
FROM --platform=$BUILDPLATFORM golang:1.26.5-alpine AS build

WORKDIR /src

# Dependencies are copied and downloaded on their own so this layer stays
# cached across source-only changes.
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download && go mod verify

COPY . .

ARG TARGETOS
ARG TARGETARCH
ARG VERSION=dev
ARG COMMIT=none

# CGO is disabled to produce a fully static binary, which is what lets the
# runtime stage be a distroless image with no libc at all.
# -trimpath strips local filesystem paths so the build is reproducible;
# -s -w drop the symbol and DWARF tables to cut image size.
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build \
      -trimpath \
      -ldflags="-s -w -X main.version=${VERSION} -X main.commit=${COMMIT}" \
      -o /out/hello-world \
      ./cmd/hello-world

# ---------------------------------------------------------------------------
# Runtime stage
#
# distroless/static carries no shell, no package manager and no busybox, so
# there is nothing for an attacker to pivot to if they achieve execution. It
# does ship CA certificates and /etc/passwd, which is all a static Go binary
# needs. The :nonroot tag defaults the user to uid 65532.
# ---------------------------------------------------------------------------
FROM gcr.io/distroless/static-debian12:nonroot

COPY --from=build /out/hello-world /usr/local/bin/hello-world

# Set explicitly as well as via the tag, so the manifest states the intent
# even if the base tag ever changes. Kubernetes runAsNonRoot checks this.
USER 65532:65532

# 8080 serves user traffic; 9090 serves Prometheus metrics only.
EXPOSE 8080 9090

# No HEALTHCHECK: the image has no shell or curl to run one with, and in
# Kubernetes the kubelet probes defined in the Helm chart own this concern.
ENTRYPOINT ["/usr/local/bin/hello-world"]
