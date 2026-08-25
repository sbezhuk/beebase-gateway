// Command gateway is the entry point for the BeeBase gateway: the single
// HTTP entry point clients talk to, which reverse-proxies to each backend
// service.
package main

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"

	"github.com/joho/godotenv"

	"github.com/sbezhuk/beebase-gateway/internal/config"
	"github.com/sbezhuk/beebase-gateway/internal/proxy"
	transporthttp "github.com/sbezhuk/beebase-gateway/internal/transport/http"

	"github.com/sbezhuk/beebase-common/logger"
	"github.com/sbezhuk/beebase-common/server"
)

func main() {
	if err := run(); err != nil {
		slog.Error("gateway exited with error", "error", err)
		os.Exit(1)
	}
}

func run() error {
	// .env is optional: present in local dev, absent in production/containers.
	_ = godotenv.Load()

	cfg, err := config.Load()
	if err != nil {
		return fmt.Errorf("load config: %w", err)
	}

	log := logger.New(cfg.Env, cfg.LogLevel)
	slog.SetDefault(log)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	upstreams := map[string]string{
		"auth-service":       cfg.AuthServiceURL,
		"apiary-service":     cfg.ApiaryServiceURL,
		"hive-service":       cfg.HiveServiceURL,
		"inspection-service": cfg.InspectionServiceURL,
	}
	proxies := make(map[string]http.Handler, len(upstreams))
	for name, target := range upstreams {
		p, err := proxy.New(name, target, log)
		if err != nil {
			return fmt.Errorf("build proxy for %s: %w", name, err)
		}
		proxies[name] = p
	}

	router := transporthttp.NewRouter(log, transporthttp.Upstreams{
		Auth:       proxies["auth-service"],
		Apiary:     proxies["apiary-service"],
		Hive:       proxies["hive-service"],
		Inspection: proxies["inspection-service"],
	})

	srv := server.New(server.Config{
		Addr:         ":" + cfg.HTTPPort,
		Handler:      router,
		ReadTimeout:  cfg.HTTPReadTimeout,
		WriteTimeout: cfg.HTTPWriteTimeout,
		IdleTimeout:  cfg.HTTPIdleTimeout,
	})

	errCh := make(chan error, 1)
	go func() {
		log.Info("starting gateway", "port", cfg.HTTPPort, "env", cfg.Env)
		errCh <- srv.Run()
	}()

	select {
	case err := <-errCh:
		if err != nil {
			return fmt.Errorf("run server: %w", err)
		}
		return nil
	case <-ctx.Done():
		log.Info("shutdown signal received")
	}

	shutdownCtx, cancelShutdown := context.WithTimeout(context.Background(), cfg.HTTPShutdownTimeout)
	defer cancelShutdown()

	if err := srv.Shutdown(shutdownCtx); err != nil {
		return fmt.Errorf("graceful shutdown: %w", err)
	}

	log.Info("gateway stopped cleanly")
	return nil
}
