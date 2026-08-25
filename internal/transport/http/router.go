// Package http wires the gateway's routing: liveness/readiness for the
// gateway itself, and reverse proxies to each backend service.
package http

import (
	"log/slog"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"

	"github.com/sbezhuk/beebase-common/httpx"
)

// Upstreams holds the reverse proxy for each backend service.
type Upstreams struct {
	Auth       http.Handler
	Apiary     http.Handler
	Hive       http.Handler
	Inspection http.Handler
}

type statusResponse struct {
	Status string `json:"status"`
}

// NewRouter builds the root HTTP handler for the gateway.
func NewRouter(log *slog.Logger, up Upstreams) http.Handler {
	r := chi.NewRouter()

	r.Use(middleware.RequestID)
	r.Use(requestLogger(log))
	r.Use(middleware.Recoverer)
	r.Use(middleware.Timeout(30 * time.Second))

	// The gateway itself is a stateless proxy with no dependencies of its
	// own to check, so liveness and readiness are the same trivial check.
	r.Get("/health", func(w http.ResponseWriter, r *http.Request) {
		httpx.WriteJSON(w, http.StatusOK, statusResponse{Status: "ok"})
	})
	r.Get("/ready", func(w http.ResponseWriter, r *http.Request) {
		httpx.WriteJSON(w, http.StatusOK, statusResponse{Status: "ok"})
	})

	r.Handle("/api/v1/auth/*", up.Auth)
	r.Handle("/.well-known/jwks.json", up.Auth)
	r.Handle("/api/v1/apiaries/*", up.Apiary)
	r.Handle("/api/v1/inspections/*", up.Inspection)

	// More specific than the "/api/v1/hives/*" wildcard below (chi
	// resolves by specificity, not registration order, so this always
	// wins for this one path shape): listing inspections for a hive is
	// inspection-service's endpoint, not hive-service's, even though it's
	// nested under /hives/.
	r.Get("/api/v1/hives/{hiveID}/inspections", up.Inspection.ServeHTTP)
	r.Handle("/api/v1/hives/*", up.Hive)

	return r
}

// requestLogger logs each request's method, path, status, and duration
// through slog instead of chi's default stdlib logger.
func requestLogger(log *slog.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			start := time.Now()
			ww := middleware.NewWrapResponseWriter(w, r.ProtoMajor)

			next.ServeHTTP(ww, r)

			log.Info("http request",
				"method", r.Method,
				"path", r.URL.Path,
				"status", ww.Status(),
				"bytes", ww.BytesWritten(),
				"duration_ms", time.Since(start).Milliseconds(),
				"request_id", middleware.GetReqID(r.Context()),
			)
		})
	}
}
