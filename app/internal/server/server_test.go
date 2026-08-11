package server

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"
)

// newTestServer builds a Server with logging discarded and drain timings
// collapsed, so lifecycle tests do not spend real seconds sleeping.
func newTestServer(t *testing.T, mutate func(*Config)) *Server {
	t.Helper()

	cfg := Config{
		Addr:            ":0",
		AdminAddr:       ":0",
		Message:         "Hello World",
		LogLevel:        slog.LevelError,
		ReadTimeout:     time.Second,
		WriteTimeout:    time.Second,
		IdleTimeout:     time.Second,
		ShutdownTimeout: time.Second,
		DrainDelay:      time.Millisecond,
	}
	if mutate != nil {
		mutate(&cfg)
	}

	log := slog.New(slog.NewJSONHandler(io.Discard, &slog.HandlerOptions{Level: cfg.LogLevel}))
	s := New(cfg, log, BuildInfo{Version: "test", Commit: "abc123"})
	s.ready.Store(true)
	return s
}

func TestPublicRoutes(t *testing.T) {
	tests := []struct {
		name       string
		method     string
		path       string
		wantStatus int
		wantBody   string
	}{
		{"root returns hello world", http.MethodGet, "/", http.StatusOK, "Hello World\n"},
		{"liveness probe", http.MethodGet, "/healthz", http.StatusOK, "ok\n"},
		{"readiness probe", http.MethodGet, "/readyz", http.StatusOK, "ready\n"},
		{"unknown path is 404", http.MethodGet, "/nope", http.StatusNotFound, "not found\n"},
		{"nested unknown path is 404", http.MethodGet, "/a/b/c", http.StatusNotFound, "not found\n"},
		{"metrics are not on the public port", http.MethodGet, "/metrics", http.StatusNotFound, "not found\n"},
		{"post to root is not routed", http.MethodPost, "/", http.StatusNotFound, "not found\n"},
	}

	srv := newTestServer(t, nil)
	handler := srv.publicRoutes()

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			rec := httptest.NewRecorder()
			handler.ServeHTTP(rec, httptest.NewRequest(tc.method, tc.path, nil))

			if rec.Code != tc.wantStatus {
				t.Errorf("status = %d, want %d", rec.Code, tc.wantStatus)
			}
			if got := rec.Body.String(); got != tc.wantBody {
				t.Errorf("body = %q, want %q", got, tc.wantBody)
			}
			if ct := rec.Header().Get("Content-Type"); ct != "text/plain; charset=utf-8" {
				t.Errorf("Content-Type = %q, want text/plain; charset=utf-8", ct)
			}
		})
	}
}

func TestHelloMessageIsConfigurable(t *testing.T) {
	srv := newTestServer(t, func(c *Config) { c.Message = "Namaste World" })

	rec := httptest.NewRecorder()
	srv.publicRoutes().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))

	if got, want := rec.Body.String(), "Namaste World\n"; got != want {
		t.Errorf("body = %q, want %q", got, want)
	}
}

func TestReadyzReportsNotReadyWhileDraining(t *testing.T) {
	srv := newTestServer(t, nil)
	handler := srv.publicRoutes()

	// Liveness must keep passing while draining, otherwise the kubelet would
	// kill the pod mid-drain instead of letting it finish in-flight requests.
	srv.ready.Store(false)

	for _, tc := range []struct {
		path       string
		wantStatus int
		wantBody   string
	}{
		{"/readyz", http.StatusServiceUnavailable, "draining\n"},
		{"/healthz", http.StatusOK, "ok\n"},
	} {
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, tc.path, nil))

		if rec.Code != tc.wantStatus {
			t.Errorf("%s status = %d, want %d", tc.path, rec.Code, tc.wantStatus)
		}
		if got := rec.Body.String(); got != tc.wantBody {
			t.Errorf("%s body = %q, want %q", tc.path, got, tc.wantBody)
		}
	}
}

func TestMetricsExposedOnAdminPort(t *testing.T) {
	srv := newTestServer(t, nil)

	// Drive some traffic so the request metrics have a non-zero sample.
	pub := srv.publicRoutes()
	pub.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/", nil))
	pub.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/missing", nil))

	rec := httptest.NewRecorder()
	srv.adminRoutes().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/metrics", nil))

	if rec.Code != http.StatusOK {
		t.Fatalf("metrics status = %d, want 200", rec.Code)
	}
	body := rec.Body.String()

	want := []string{
		`http_requests_total{method="GET",route="/",status="200"} 1`,
		`http_requests_total{method="GET",route="other",status="404"} 1`,
		`hello_world_build_info{commit="abc123",version="test"} 1`,
		"http_request_duration_seconds_bucket",
		"http_requests_in_flight",
		"go_goroutines",
	}
	for _, w := range want {
		if !strings.Contains(body, w) {
			t.Errorf("metrics output missing %q", w)
		}
	}
}

func TestUnknownPathsShareOneRouteLabel(t *testing.T) {
	srv := newTestServer(t, nil)
	pub := srv.publicRoutes()

	scans := []string{"/wp-admin", "/.env", "/x/y/z", "/admin/config.php"}
	for _, p := range scans {
		pub.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, p, nil))
	}

	rec := httptest.NewRecorder()
	srv.adminRoutes().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/metrics", nil))
	body := rec.Body.String()

	// Every scan must collapse into one series, or an attacker could exhaust
	// Prometheus memory through label cardinality alone.
	want := `http_requests_total{method="GET",route="other",status="404"} ` + strconv.Itoa(len(scans))
	if !strings.Contains(body, want) {
		t.Errorf("expected %q in metrics output, got:\n%s", want, body)
	}
	for _, p := range scans {
		if strings.Contains(body, p) {
			t.Errorf("raw request path %q leaked into a metric label", p)
		}
	}
}

// Paths that need cleaning never reach our handlers: net/http's ServeMux
// answers them with its own redirect. Pinning that here documents why such
// requests produce no request metric, so the gap is not mistaken for a bug in
// the instrumentation later.
func TestTraversalPathsAreRedirectedAndNotInstrumented(t *testing.T) {
	srv := newTestServer(t, nil)

	rec := httptest.NewRecorder()
	srv.publicRoutes().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/../etc/passwd", nil))

	if rec.Code < 300 || rec.Code >= 400 {
		t.Errorf("status = %d, want a 3xx redirect from path cleaning", rec.Code)
	}

	metrics := httptest.NewRecorder()
	srv.adminRoutes().ServeHTTP(metrics, httptest.NewRequest(http.MethodGet, "/metrics", nil))

	if body := metrics.Body.String(); strings.Contains(body, "etc/passwd") {
		t.Error("cleaned traversal path leaked into a metric label")
	}
	if body := metrics.Body.String(); strings.Contains(body, `route="other"`) {
		t.Error("mux redirect was unexpectedly counted as a served request")
	}
}

func TestRunShutsDownGracefullyOnContextCancel(t *testing.T) {
	srv := newTestServer(t, nil)

	ctx, cancel := context.WithCancel(context.Background())
	errCh := make(chan error, 1)
	go func() { errCh <- srv.Run(ctx) }()

	// Wait for Run to mark the server ready before signalling shutdown.
	deadline := time.After(2 * time.Second)
	for !srv.ready.Load() {
		select {
		case <-deadline:
			t.Fatal("server never became ready")
		default:
			time.Sleep(time.Millisecond)
		}
	}

	cancel()

	select {
	case err := <-errCh:
		if err != nil {
			t.Fatalf("Run returned %v, want nil on clean shutdown", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Run did not return within 5s of cancellation")
	}

	if srv.ready.Load() {
		t.Error("readiness should be false after shutdown")
	}
}

func TestConfigFromEnvDefaults(t *testing.T) {
	cfg, err := ConfigFromEnv()
	if err != nil {
		t.Fatalf("ConfigFromEnv() error = %v", err)
	}

	checks := []struct {
		name string
		got  any
		want any
	}{
		{"Addr", cfg.Addr, ":8080"},
		{"AdminAddr", cfg.AdminAddr, ":9090"},
		{"Message", cfg.Message, "Hello World"},
		{"LogLevel", cfg.LogLevel, slog.LevelInfo},
		{"DrainDelay", cfg.DrainDelay, 5 * time.Second},
		{"ShutdownTimeout", cfg.ShutdownTimeout, 15 * time.Second},
	}
	for _, c := range checks {
		if c.got != c.want {
			t.Errorf("%s = %v, want %v", c.name, c.got, c.want)
		}
	}
}

func TestConfigFromEnvOverrides(t *testing.T) {
	t.Setenv("PORT", "3000")
	t.Setenv("ADMIN_PORT", "3001")
	t.Setenv("MESSAGE", "Hello from Mumbai")
	t.Setenv("LOG_LEVEL", "debug")
	t.Setenv("DRAIN_DELAY", "12s")

	cfg, err := ConfigFromEnv()
	if err != nil {
		t.Fatalf("ConfigFromEnv() error = %v", err)
	}

	checks := []struct {
		name string
		got  any
		want any
	}{
		{"Addr", cfg.Addr, ":3000"},
		{"AdminAddr", cfg.AdminAddr, ":3001"},
		{"Message", cfg.Message, "Hello from Mumbai"},
		{"LogLevel", cfg.LogLevel, slog.LevelDebug},
		{"DrainDelay", cfg.DrainDelay, 12 * time.Second},
	}
	for _, c := range checks {
		if c.got != c.want {
			t.Errorf("%s = %v, want %v", c.name, c.got, c.want)
		}
	}
}

func TestConfigFromEnvRejectsBadValues(t *testing.T) {
	tests := []struct {
		name  string
		key   string
		value string
	}{
		{"non-duration drain delay", "DRAIN_DELAY", "5"},
		{"garbage duration", "SHUTDOWN_TIMEOUT", "soon"},
		{"negative duration", "READ_TIMEOUT", "-3s"},
		{"unknown log level", "LOG_LEVEL", "verbose"},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv(tc.key, tc.value)
			if _, err := ConfigFromEnv(); err == nil {
				t.Fatalf("ConfigFromEnv() with %s=%q returned nil error, want a failure", tc.key, tc.value)
			}
		})
	}
}

func TestStatusRecorderKeepsFirstStatus(t *testing.T) {
	rec := httptest.NewRecorder()
	sr := &statusRecorder{ResponseWriter: rec, status: http.StatusOK}

	sr.WriteHeader(http.StatusTeapot)
	sr.WriteHeader(http.StatusInternalServerError)

	if sr.status != http.StatusTeapot {
		t.Errorf("recorded status = %d, want %d", sr.status, http.StatusTeapot)
	}
	if rec.Code != http.StatusTeapot {
		t.Errorf("underlying status = %d, want %d", rec.Code, http.StatusTeapot)
	}
}

func TestStatusRecorderDefaultsToOKOnBareWrite(t *testing.T) {
	rec := httptest.NewRecorder()
	sr := &statusRecorder{ResponseWriter: rec, status: 0}

	if _, err := sr.Write([]byte("body")); err != nil {
		t.Fatalf("Write() error = %v", err)
	}
	if sr.status != http.StatusOK {
		t.Errorf("status = %d, want %d", sr.status, http.StatusOK)
	}
}
