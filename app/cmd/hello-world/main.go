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

// Set at link time via -ldflags.
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

	// JSON to stdout, where the container runtime collects it.
	log := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: cfg.LogLevel}))
	slog.SetDefault(log)

	// SIGTERM from Kubernetes, SIGINT for Ctrl-C locally.
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	srv := server.New(cfg, log, server.BuildInfo{Version: version, Commit: commit})
	if err := srv.Run(ctx); err != nil {
		return err
	}

	log.Info("shutdown complete", "version", version, "commit", commit)
	return nil
}
