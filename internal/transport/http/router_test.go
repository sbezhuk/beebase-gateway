package http

import (
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
)

// stubUpstream always responds 200, recording the method+path it was
// invoked with so a test can tell whether a request actually reached the
// (fake) backend service or was intercepted before ever reaching the mount.
type stubUpstream struct {
	called bool
}

func (s *stubUpstream) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	s.called = true
	w.WriteHeader(http.StatusOK)
}

func newTestRouter() (http.Handler, *stubUpstream, *stubUpstream, *stubUpstream) {
	media := &stubUpstream{}
	hive := &stubUpstream{}
	statistics := &stubUpstream{}
	r := NewRouter(slog.New(slog.NewTextHandler(io.Discard, nil)), Upstreams{
		Auth:       &stubUpstream{},
		Apiary:     &stubUpstream{},
		Hive:       hive,
		Inspection: &stubUpstream{},
		Media:      media,
		Statistics: statistics,
	})
	return r, media, hive, statistics
}

// TestInternalOnlyRoutesAreBlocked locks in the fix: an external client
// must never be able to reach media-service's attach/DeleteByOwner or
// hive-service's DeleteByApiary through the gateway, since neither
// service's own auth can distinguish a forwarded internal call from a
// direct external one - the gateway is the only enforcement point.
func TestInternalOnlyRoutesAreBlocked(t *testing.T) {
	cases := []struct {
		name   string
		method string
		path   string
	}{
		{"media attach", http.MethodPost, "/api/v1/media/11111111-1111-1111-1111-111111111111/attach"},
		{"media DeleteByOwner", http.MethodDelete, "/api/v1/media"},
		{"hive DeleteByApiary", http.MethodDelete, "/api/v1/hives"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			router, media, hive, _ := newTestRouter()

			req := httptest.NewRequest(tc.method, tc.path, nil)
			rec := httptest.NewRecorder()
			router.ServeHTTP(rec, req)

			if rec.Code != http.StatusNotFound {
				t.Errorf("expected 404, got %d", rec.Code)
			}
			if media.called || hive.called {
				t.Errorf("request reached the upstream service; it must be blocked at the gateway")
			}
		})
	}
}

// TestLegitimateRoutesStillProxy is the flip side: the blocking fix must
// not collateral-damage any real, client-facing route at the same or a
// neighboring path.
func TestLegitimateRoutesStillProxy(t *testing.T) {
	cases := []struct {
		name    string
		method  string
		path    string
		reaches string // which upstream should see the request
	}{
		{"media upload", http.MethodPost, "/api/v1/media", "media"},
		{"media list", http.MethodGet, "/api/v1/media", "media"},
		{"media get by id", http.MethodGet, "/api/v1/media/11111111-1111-1111-1111-111111111111", "media"},
		{"media download", http.MethodGet, "/api/v1/media/11111111-1111-1111-1111-111111111111/download", "media"},
		{"media delete by id", http.MethodDelete, "/api/v1/media/11111111-1111-1111-1111-111111111111", "media"},
		{"hive create", http.MethodPost, "/api/v1/hives", "hive"},
		{"hive list", http.MethodGet, "/api/v1/hives", "hive"},
		{"hive update", http.MethodPut, "/api/v1/hives/11111111-1111-1111-1111-111111111111", "hive"},
		{"statistics overview", http.MethodGet, "/api/v1/statistics/overview", "statistics"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			router, media, hive, statistics := newTestRouter()

			req := httptest.NewRequest(tc.method, tc.path, nil)
			rec := httptest.NewRecorder()
			router.ServeHTTP(rec, req)

			if rec.Code != http.StatusOK {
				t.Fatalf("expected 200 from the stub upstream, got %d", rec.Code)
			}

			switch tc.reaches {
			case "media":
				if !media.called {
					t.Error("expected the request to reach media-service")
				}
			case "hive":
				if !hive.called {
					t.Error("expected the request to reach hive-service")
				}
			case "statistics":
				if !statistics.called {
					t.Error("expected the request to reach statistics-service")
				}
			}
		})
	}
}
