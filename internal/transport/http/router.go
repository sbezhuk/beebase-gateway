// Package http wires the gateway's routing: liveness/readiness for the
// gateway itself, and reverse proxies to each backend service.
package http

import (
	"log/slog"
	"net/http"
	"regexp"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"

	"github.com/sbezhuk/beebase-common/httpx"
)

// attachPathPattern matches media-service's attach endpoint,
// "/api/v1/media/{mediaID}/attach", for any mediaID segment.
var attachPathPattern = regexp.MustCompile(`^/api/v1/media/[^/]+/attach$`)

// attachPath is a sentinel methodPath.path value recognized by
// blockInternalOnly as "match attachPathPattern" rather than an exact
// string, since the real path varies by mediaID.
const attachPath = "<attach>"

// methodPath identifies one internal-only route to block: an exact HTTP
// method plus either an exact path or, for attachPath, a pattern match.
type methodPath struct {
	method string
	path   string
}

func (mp methodPath) matches(r *http.Request) bool {
	if r.Method != mp.method {
		return false
	}
	if mp.path == attachPath {
		return attachPathPattern.MatchString(r.URL.Path)
	}
	return r.URL.Path == mp.path
}

// blockInternalOnly wraps next so that any request matching one of
// blocked never reaches it, returning a plain 404 instead -
// indistinguishable from a route that doesn't exist. next is a raw
// reverse proxy (see internal/proxy), not a chi sub-router, so this
// operates directly on the request's method and full path rather than
// relying on chi's own route-priority rules, which don't reliably favor
// a literal route over a Mount's own root pattern for the exact-same
// path (verified in router_test.go).
func blockInternalOnly(next http.Handler, blocked ...methodPath) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		for _, mp := range blocked {
			if mp.matches(r) {
				http.NotFound(w, r)
				return
			}
		}
		next.ServeHTTP(w, r)
	})
}

// Upstreams holds the reverse proxy for each backend service.
type Upstreams struct {
	Auth       http.Handler
	Apiary     http.Handler
	Hive       http.Handler
	Inspection http.Handler
	Media      http.Handler
	Statistics http.Handler
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

	r.Mount("/api/v1/auth", up.Auth)
	r.Handle("/.well-known/jwks.json", up.Auth)
	r.Mount("/api/v1/apiaries", up.Apiary)
	r.Mount("/api/v1/inspections", up.Inspection)

	// More specific than the "/api/v1/hives" mount below (chi resolves by
	// specificity, not registration order, so this always wins for this
	// one path shape): listing inspections for a hive is inspection-
	// service's endpoint, not hive-service's, even though it's nested
	// under /hives/.
	r.Get("/api/v1/hives/{hiveID}/inspections", up.Inspection.ServeHTTP)

	r.Mount("/api/v1/hives", blockInternalOnly(up.Hive, methodPath{http.MethodDelete, "/api/v1/hives"}))
	r.Mount("/api/v1/media", blockInternalOnly(up.Media,
		methodPath{http.MethodDelete, "/api/v1/media"},
		methodPath{http.MethodPost, attachPath},
	))
	r.Mount("/api/v1/statistics", up.Statistics)

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
