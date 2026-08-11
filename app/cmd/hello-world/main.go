// Command hello-world runs the Hello World HTTP microservice.
package main

import (
	"context"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"github.com/baldevv0001/bv-devops-assignment/app/internal/server"
)

// Populated at link time via -ldflags; see the Dockerfile and Makefile.
var (
	version = "dev"
	commit  = "none"
)

func main() {
	if err := run(); err != nil {
		slog.Error("fatal", "error", err)
		os.Exit(1)
	}
}

func run() error {
	cfg, err := server.ConfigFromEnv()
	if err != nil {
		return err
	}

	// Logs go to stdout as JSON: the container runtime collects them from
	// there, and structured output is what makes them queryable once they
	// reach a log backend.
	log := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: cfg.LogLevel}))
	slog.SetDefault(log)

	// SIGTERM is what Kubernetes sends first when terminating a pod; SIGINT
	// covers Ctrl-C during local development.
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	srv := server.New(cfg, log, server.BuildInfo{Version: version, Commit: commit})
	if err := srv.Run(ctx); err != nil {
		return err
	}

	log.Info("shutdown complete", "version", version, "commit", commit)
	return nil
}
