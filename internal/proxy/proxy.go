// Package proxy builds reverse proxies to BeeBase's backend services.
package proxy

import (
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httputil"
	"net/url"

	"github.com/sbezhuk/beebase-common/httpx"
)

// New returns a reverse proxy forwarding requests to target, unchanged
// apart from scheme/host — path and query stay exactly as the client sent
// them, since each backend service already routes its own full path
// (e.g. /api/v1/apiaries/...).
func New(name, target string, log *slog.Logger) (http.Handler, error) {
	targetURL, err := url.Parse(target)
	if err != nil {
		return nil, fmt.Errorf("proxy: parse %s URL %q: %w", name, target, err)
	}

	rp := httputil.NewSingleHostReverseProxy(targetURL)

	rp.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
		log.Error("upstream request failed", "service", name, "path", r.URL.Path, "error", err)
		httpx.WriteError(w, http.StatusBadGateway, "upstream_unavailable",
			fmt.Sprintf("%s is temporarily unavailable", name))
	}

	return rp, nil
}
