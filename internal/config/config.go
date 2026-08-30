// Package config loads gateway configuration from environment variables,
// with sane defaults for local development.
package config

import (
	"fmt"
	"os"
	"time"
)

// Config holds all runtime configuration for the gateway.
type Config struct {
	Env string // "development" or "production"

	HTTPPort            string
	HTTPReadTimeout     time.Duration
	HTTPWriteTimeout    time.Duration
	HTTPIdleTimeout     time.Duration
	HTTPShutdownTimeout time.Duration

	LogLevel string // "debug", "info", "warn", "error"

	// Upstream base URLs, e.g. "http://auth-service:8080". Requests are
	// forwarded with their path and query untouched, so each upstream
	// keeps routing exactly as it does when called directly.
	AuthServiceURL       string
	ApiaryServiceURL     string
	HiveServiceURL       string
	InspectionServiceURL string
	MediaServiceURL      string
}

// Load builds a Config from environment variables, falling back to
// defaults suitable for local development where a variable is unset.
func Load() (*Config, error) {
	cfg := &Config{
		Env: getEnv("APP_ENV", "development"),

		HTTPPort:            getEnv("HTTP_PORT", "8080"),
		HTTPReadTimeout:     getDuration("HTTP_READ_TIMEOUT", 5*time.Second),
		HTTPWriteTimeout:    getDuration("HTTP_WRITE_TIMEOUT", 10*time.Second),
		HTTPIdleTimeout:     getDuration("HTTP_IDLE_TIMEOUT", 60*time.Second),
		HTTPShutdownTimeout: getDuration("HTTP_SHUTDOWN_TIMEOUT", 15*time.Second),

		LogLevel: getEnv("LOG_LEVEL", "info"),

		AuthServiceURL:       getEnv("AUTH_SERVICE_URL", ""),
		ApiaryServiceURL:     getEnv("APIARY_SERVICE_URL", ""),
		HiveServiceURL:       getEnv("HIVE_SERVICE_URL", ""),
		InspectionServiceURL: getEnv("INSPECTION_SERVICE_URL", ""),
		MediaServiceURL:      getEnv("MEDIA_SERVICE_URL", ""),
	}

	required := []struct{ name, value string }{
		{"AUTH_SERVICE_URL", cfg.AuthServiceURL},
		{"APIARY_SERVICE_URL", cfg.ApiaryServiceURL},
		{"HIVE_SERVICE_URL", cfg.HiveServiceURL},
		{"INSPECTION_SERVICE_URL", cfg.InspectionServiceURL},
		{"MEDIA_SERVICE_URL", cfg.MediaServiceURL},
	}
	for _, r := range required {
		if r.value == "" {
			return nil, fmt.Errorf("config: %s is required", r.name)
		}
	}

	return cfg, nil
}

func getEnv(key, fallback string) string {
	if v, ok := os.LookupEnv(key); ok && v != "" {
		return v
	}
	return fallback
}

func getDuration(key string, fallback time.Duration) time.Duration {
	v, ok := os.LookupEnv(key)
	if !ok || v == "" {
		return fallback
	}
	d, err := time.ParseDuration(v)
	if err != nil {
		return fallback
	}
	return d
}
