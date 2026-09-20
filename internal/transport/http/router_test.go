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

func newTestRouter() (http.Handler, *stubUpstream, *stubUpstream, *stubUpstream, *stubUpstream, *stubUpstream, *stubUpstream, *stubUpstream) {
	auth := &stubUpstream{}
	apiary := &stubUpstream{}
	media := &stubUpstream{}
	hive := &stubUpstream{}
	harvest := &stubUpstream{}
	statistics := &stubUpstream{}
	subscription := &stubUpstream{}
	r := NewRouter(slog.New(slog.NewTextHandler(io.Discard, nil)), Upstreams{
		Auth:         auth,
		Apiary:       apiary,
		Hive:         hive,
		Inspection:   &stubUpstream{},
		Harvest:      harvest,
		Media:        media,
		Statistics:   statistics,
		Subscription: subscription,
	})
	return r, auth, apiary, media, hive, harvest, statistics, subscription
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
		{"media DeleteMine", http.MethodDelete, "/api/v1/media/mine"},
		{"hive DeleteByApiary", http.MethodDelete, "/api/v1/hives"},
		{"apiary DeleteAllMine", http.MethodDelete, "/api/v1/apiaries"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			router, _, apiary, media, hive, _, _, _ := newTestRouter()

			req := httptest.NewRequest(tc.method, tc.path, nil)
			rec := httptest.NewRecorder()
			router.ServeHTTP(rec, req)

			if rec.Code != http.StatusNotFound {
				t.Errorf("expected 404, got %d", rec.Code)
			}
			if apiary.called || media.called || hive.called {
				t.Errorf("request reached the upstream service; it must be blocked at the gateway")
			}
		})
	}
}

func TestAllInternalPathsAreBlocked(t *testing.T) {
	router, _, apiary, media, hive, harvest, _, _ := newTestRouter()
	for _, path := range []string{"/internal", "/internal/anything", "/internal/api/v1/reminders/cleanup"} {
		t.Run(path, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, path, nil)
			rec := httptest.NewRecorder()
			router.ServeHTTP(rec, req)
			if rec.Code != http.StatusNotFound {
				t.Fatalf("status = %d, want 404", rec.Code)
			}
			if apiary.called || media.called || hive.called || harvest.called {
				t.Fatal("internal request reached an upstream")
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
		{"hive list by apiary", http.MethodGet, "/api/v1/apiaries/11111111-1111-1111-1111-111111111111/hives", "hive"},
		{"hive update", http.MethodPut, "/api/v1/hives/11111111-1111-1111-1111-111111111111", "hive"},
		{"queen current", http.MethodGet, "/api/v1/hives/11111111-1111-1111-1111-111111111111/queen", "hive"},
		{"queen history", http.MethodGet, "/api/v1/hives/11111111-1111-1111-1111-111111111111/queens", "hive"},
		{"queen create", http.MethodPost, "/api/v1/hives/11111111-1111-1111-1111-111111111111/queens", "hive"},
		{"queen get", http.MethodGet, "/api/v1/hives/11111111-1111-1111-1111-111111111111/queens/22222222-2222-2222-2222-222222222222", "hive"},
		{"queen update", http.MethodPut, "/api/v1/hives/11111111-1111-1111-1111-111111111111/queens/22222222-2222-2222-2222-222222222222", "hive"},
		{"queen delete", http.MethodDelete, "/api/v1/hives/11111111-1111-1111-1111-111111111111/queens/22222222-2222-2222-2222-222222222222", "hive"},
		{"harvest create", http.MethodPost, "/api/v1/hives/11111111-1111-1111-1111-111111111111/harvests", "harvest"},
		{"harvest list", http.MethodGet, "/api/v1/hives/11111111-1111-1111-1111-111111111111/harvests", "harvest"},
		{"harvest global list", http.MethodGet, "/api/v1/harvests", "harvest"},
		{"harvest plural list", http.MethodGet, "/api/v1/hives/11111111-1111-1111-1111-111111111111/harvests", "harvest"},
		{"harvest get", http.MethodGet, "/api/v1/hives/11111111-1111-1111-1111-111111111111/harvests/22222222-2222-2222-2222-222222222222", "harvest"},
		{"harvest update", http.MethodPut, "/api/v1/hives/11111111-1111-1111-1111-111111111111/harvests/22222222-2222-2222-2222-222222222222", "harvest"},
		{"harvest delete", http.MethodDelete, "/api/v1/hives/11111111-1111-1111-1111-111111111111/harvests/22222222-2222-2222-2222-222222222222", "harvest"},
		{"apiary create", http.MethodPost, "/api/v1/apiaries", "apiary"},
		{"apiary list", http.MethodGet, "/api/v1/apiaries", "apiary"},
		{"apiary delete by id", http.MethodDelete, "/api/v1/apiaries/11111111-1111-1111-1111-111111111111", "apiary"},
		{"statistics overview", http.MethodGet, "/api/v1/statistics/overview", "statistics"},
		{"profile get", http.MethodGet, "/api/v1/profile", "auth"},
		{"profile update", http.MethodPut, "/api/v1/profile", "auth"},
		{"profile delete", http.MethodDelete, "/api/v1/profile", "auth"},
		{"subscription get", http.MethodGet, "/api/v1/subscription", "subscription"},
		{"subscription webhook", http.MethodPost, "/api/v1/subscriptions/webhooks/apple", "subscription"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			router, auth, apiary, media, hive, harvest, statistics, subscription := newTestRouter()

			req := httptest.NewRequest(tc.method, tc.path, nil)
			rec := httptest.NewRecorder()
			router.ServeHTTP(rec, req)

			if rec.Code != http.StatusOK {
				t.Fatalf("expected 200 from the stub upstream, got %d", rec.Code)
			}

			switch tc.reaches {
			case "auth":
				if !auth.called {
					t.Error("expected the request to reach auth-service")
				}
			case "apiary":
				if !apiary.called {
					t.Error("expected the request to reach apiary-service")
				}
			case "media":
				if !media.called {
					t.Error("expected the request to reach media-service")
				}
			case "hive":
				if !hive.called {
					t.Error("expected the request to reach hive-service")
				}
			case "harvest":
				if !harvest.called {
					t.Error("expected the request to reach harvest-service")
				}
			case "statistics":
				if !statistics.called {
					t.Error("expected the request to reach statistics-service")
				}
			case "subscription":
				if !subscription.called {
					t.Error("expected the request to reach subscription-service")
				}
			}
		})
	}
}

// TestHarvestRoutesDoNotReachHiveService locks in the routing precedence
// harvest depends on: /api/v1/hives/{hiveId}/harvests must never fall
// through to hive-service's own broader /api/v1/hives mount, since that
// would return hive-service's 404 for a resource it knows nothing about
// rather than routing to harvest-service.
func TestHarvestRoutesDoNotReachHiveService(t *testing.T) {
	router, _, _, _, hive, harvest, _, _ := newTestRouter()

	req := httptest.NewRequest(http.MethodGet, "/api/v1/hives/11111111-1111-1111-1111-111111111111/harvests", nil)
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
	if hive.called {
		t.Error("harvest route reached hive-service; it must be routed to harvest-service instead")
	}
	if !harvest.called {
		t.Error("harvest route did not reach harvest-service")
	}
}

// TestHealthHistoryRouteReachesInspectionServiceNotHive proves the new
// GET /api/v1/hives/{hiveId}/health/history route is proxied to
// inspection-service - the service that owns Colony Health, computed from
// inspection history - and never falls through to hive-service's own
// broader /api/v1/hives mount, the same routing precedence concern
// TestHarvestRoutesDoNotReachHiveService already covers for harvests.
func TestHealthHistoryRouteReachesInspectionServiceNotHive(t *testing.T) {
	inspection := &stubUpstream{}
	hive := &stubUpstream{}
	r := NewRouter(slog.New(slog.NewTextHandler(io.Discard, nil)), Upstreams{
		Auth: &stubUpstream{}, Apiary: &stubUpstream{}, Hive: hive, Inspection: inspection,
		Harvest: &stubUpstream{}, Media: &stubUpstream{}, Statistics: &stubUpstream{}, Subscription: &stubUpstream{},
	})

	req := httptest.NewRequest(http.MethodGet, "/api/v1/hives/11111111-1111-1111-1111-111111111111/health/history?from=2026-01-01&to=2026-01-02", nil)
	rec := httptest.NewRecorder()
	r.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	if hive.called {
		t.Error("health/history route reached hive-service; it must be routed to inspection-service instead")
	}
	if !inspection.called {
		t.Error("health/history route did not reach inspection-service")
	}
}

// TestHealthAndHealthHistoryRoutesDoNotConflict proves the new, longer
// "/health/history" static route and the existing "/health" route
// coexist without either shadowing the other - chi resolves both as
// distinct exact paths, not a wildcard match.
func TestHealthAndHealthHistoryRoutesDoNotConflict(t *testing.T) {
	inspection := &stubUpstream{}
	r := NewRouter(slog.New(slog.NewTextHandler(io.Discard, nil)), Upstreams{
		Auth: &stubUpstream{}, Apiary: &stubUpstream{}, Hive: &stubUpstream{}, Inspection: inspection,
		Harvest: &stubUpstream{}, Media: &stubUpstream{}, Statistics: &stubUpstream{}, Subscription: &stubUpstream{},
	})

	for _, path := range []string{
		"/api/v1/hives/11111111-1111-1111-1111-111111111111/health",
		"/api/v1/hives/11111111-1111-1111-1111-111111111111/health/history?from=2026-01-01&to=2026-01-02",
	} {
		inspection.called = false
		req := httptest.NewRequest(http.MethodGet, path, nil)
		rec := httptest.NewRecorder()
		r.ServeHTTP(rec, req)

		if rec.Code != http.StatusOK {
			t.Fatalf("path %s: status = %d, want 200", path, rec.Code)
		}
		if !inspection.called {
			t.Fatalf("path %s: did not reach inspection-service", path)
		}
	}
}

func TestLegacySingularHarvestRouteDoesNotProxy(t *testing.T) {
	router, _, _, _, hive, harvest, _, _ := newTestRouter()

	req := httptest.NewRequest(http.MethodGet, "/api/v1/hives/11111111-1111-1111-1111-111111111111/harvest", nil)
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("expected 404 for legacy singular route, got %d", rec.Code)
	}
	if hive.called || harvest.called {
		t.Error("legacy singular harvest route reached an upstream service")
	}
}
