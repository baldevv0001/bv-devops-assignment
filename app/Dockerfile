# syntax=docker/dockerfile:1

# Pinned to a patch version so the build depends only on what is committed.
FROM --platform=$BUILDPLATFORM golang:1.26.5-alpine AS build

WORKDIR /src

# Dependencies first, so this layer stays cached across source-only changes.
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download && go mod verify

COPY . .

ARG TARGETOS
ARG TARGETARCH
ARG VERSION=dev
ARG COMMIT=none

# CGO off gives a static binary, which is what allows a distroless runtime.
# -trimpath makes the build reproducible; -s -w drop symbol and debug tables.
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build \
      -trimpath \
      -ldflags="-s -w -X main.version=${VERSION} -X main.commit=${COMMIT}" \
      -o /out/hello-world \
      ./cmd/hello-world

# distroless/static has no shell and no package manager, so there is nothing to
# pivot to after an exploit. The :nonroot tag defaults the user to uid 65532.
FROM gcr.io/distroless/static-debian12:nonroot

COPY --from=build /out/hello-world /usr/local/bin/hello-world

# Stated explicitly as well as via the tag; runAsNonRoot checks this.
USER 65532:65532

# 8080 serves user traffic, 9090 serves metrics.
EXPOSE 8080 9090

# No HEALTHCHECK: there is no shell to run one, and kubelet probes cover it.
ENTRYPOINT ["/usr/local/bin/hello-world"]
