// Package server implements the Hello World HTTP service. Public traffic and
// Prometheus metrics use separate ports, so a NetworkPolicy can restrict
// scraping without touching user traffic.
package server

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"golang.org/x/sync/errgroup"
)

// BuildInfo is stamped in at link time and exported as a Prometheus gauge.
type BuildInfo struct {
	Version string
	Commit  string
}

// Config holds the runtime configuration, sourced from the environment.
type Config struct {
	Addr      string
	AdminAddr string
	Message   string
	LogLevel  slog.Level

	ReadTimeout     time.Duration
	WriteTimeout    time.Duration
	IdleTimeout     time.Duration
	ShutdownTimeout time.Duration

	// DrainDelay is how long to keep serving after SIGTERM while reporting
	// NotReady, so kube-proxy can remove this pod from the Service first.
	DrainDelay time.Duration
}

// ConfigFromEnv builds a Config from the environment, erroring on bad values
// rather than falling back silently.
func ConfigFromEnv() (Config, error) {
	cfg := Config{
		Addr:            ":" + envString("PORT", "8080"),
		AdminAddr:       ":" + envString("ADMIN_PORT", "9090"),
		Message:         envString("MESSAGE", "Hello World"),
		ReadTimeout:     5 * time.Second,
		WriteTimeout:    10 * time.Second,
		IdleTimeout:     120 * time.Second,
		ShutdownTimeout: 15 * time.Second,
		DrainDelay:      5 * time.Second,
	}

	var err error
	if cfg.LogLevel, err = parseLevel(envString("LOG_LEVEL", "info")); err != nil {
		return Config{}, err
	}

	durations := []struct {
		key    string
		target *time.Duration
	}{
		{"READ_TIMEOUT", &cfg.ReadTimeout},
		{"WRITE_TIMEOUT", &cfg.WriteTimeout},
		{"IDLE_TIMEOUT", &cfg.IdleTimeout},
		{"SHUTDOWN_TIMEOUT", &cfg.ShutdownTimeout},
		{"DRAIN_DELAY", &cfg.DrainDelay},
	}
	for _, d := range durations {
		raw, ok := os.LookupEnv(d.key)
		if !ok {
			continue
		}
		parsed, perr := time.ParseDuration(raw)
		if perr != nil {
			return Config{}, fmt.Errorf("%s: %q is not a valid duration: %w", d.key, raw, perr)
		}
		if parsed < 0 {
			return Config{}, fmt.Errorf("%s: must not be negative, got %s", d.key, parsed)
		}
		*d.target = parsed
	}

	return cfg, nil
}

func envString(key, fallback string) string {
	if v, ok := os.LookupEnv(key); ok && v != "" {
		return v
	}
	return fallback
}

func parseLevel(s string) (slog.Level, error) {
	var lvl slog.Level
	if err := lvl.UnmarshalText([]byte(strings.ToUpper(s))); err != nil {
		return 0, fmt.Errorf("LOG_LEVEL: %q is not one of debug, info, warn, error", s)
	}
	return lvl, nil
}

// Server wires the routes, metrics and lifecycle together.
type Server struct {
	cfg     Config
	log     *slog.Logger
	metrics *metrics
	reg     *prometheus.Registry

	// ready gates /readyz and flips to false on SIGTERM before listeners close.
	ready atomic.Bool
}

// New constructs a Server with its own Prometheus registry.
func New(cfg Config, log *slog.Logger, info BuildInfo) *Server {
	reg := prometheus.NewRegistry()
	reg.MustRegister(
		collectors.NewGoCollector(),
		collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}),
	)
	return &Server{
		cfg:     cfg,
		log:     log,
		metrics: newMetrics(reg, info),
		reg:     reg,
	}
}

// Run starts both listeners and blocks until ctx is cancelled, then drains.
func (s *Server) Run(ctx context.Context) error {
	public := &http.Server{
		Addr:              s.cfg.Addr,
		Handler:           s.publicRoutes(),
		ReadHeaderTimeout: s.cfg.ReadTimeout,
		ReadTimeout:       s.cfg.ReadTimeout,
		WriteTimeout:      s.cfg.WriteTimeout,
		IdleTimeout:       s.cfg.IdleTimeout,
	}
	admin := &http.Server{
		Addr:              s.cfg.AdminAddr,
		Handler:           s.adminRoutes(),
		ReadHeaderTimeout: s.cfg.ReadTimeout,
		ReadTimeout:       s.cfg.ReadTimeout,
		WriteTimeout:      s.cfg.WriteTimeout,
		IdleTimeout:       s.cfg.IdleTimeout,
	}

	s.ready.Store(true)
	s.log.Info("server starting",
		"addr", s.cfg.Addr,
		"admin_addr", s.cfg.AdminAddr,
		"log_level", s.cfg.LogLevel.String(),
	)

	g, gctx := errgroup.WithContext(ctx)
	g.Go(func() error { return listen(public, "public") })
	g.Go(func() error { return listen(admin, "admin") })
	g.Go(func() error {
		<-gctx.Done()
		return s.drainAndShutdown(public, admin)
	})

	return g.Wait()
}

func listen(srv *http.Server, name string) error {
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return fmt.Errorf("%s listener: %w", name, err)
	}
	return nil
}

func (s *Server) drainAndShutdown(servers ...*http.Server) error {
	s.log.Info("shutdown signal received, failing readiness", "drain_delay", s.cfg.DrainDelay)
	s.ready.Store(false)

	// Give Kubernetes time to drop this pod from the Service endpoints.
	time.Sleep(s.cfg.DrainDelay)

	ctx, cancel := context.WithTimeout(context.Background(), s.cfg.ShutdownTimeout)
	defer cancel()

	s.log.Info("draining in-flight requests", "timeout", s.cfg.ShutdownTimeout)
	var errs []error
	for _, srv := range servers {
		if err := srv.Shutdown(ctx); err != nil {
			errs = append(errs, err)
		}
	}
	return errors.Join(errs...)
}

func (s *Server) publicRoutes() http.Handler {
	mux := http.NewServeMux()
	// "GET /{$}" matches the root path exactly rather than acting as a catch-all.
	mux.Handle("GET /{$}", s.instrument("/", s.handleHello))
	mux.Handle("GET /healthz", s.instrument("/healthz", s.handleHealthz))
	mux.Handle("GET /readyz", s.instrument("/readyz", s.handleReadyz))
	// Everything else shares one route label to bound metric cardinality.
	mux.Handle("/", s.instrument("other", s.handleNotFound))
	return mux
}

func (s *Server) adminRoutes() http.Handler {
	mux := http.NewServeMux()
	mux.Handle("GET /metrics", promhttp.HandlerFor(s.reg, promhttp.HandlerOpts{
		ErrorHandling: promhttp.ContinueOnError,
	}))
	// Probes are duplicated here so the metrics port can be checked on its own.
	mux.HandleFunc("GET /healthz", s.handleHealthz)
	mux.HandleFunc("GET /readyz", s.handleReadyz)
	return mux
}

func (s *Server) handleHello(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	fmt.Fprintln(w, s.cfg.Message)
}

// handleHealthz reports process health only, never downstream health.
func (s *Server) handleHealthz(w http.ResponseWriter, r *http.Request) {
	writePlain(w, http.StatusOK, "ok")
}

func (s *Server) handleReadyz(w http.ResponseWriter, r *http.Request) {
	if !s.ready.Load() {
		writePlain(w, http.StatusServiceUnavailable, "draining")
		return
	}
	writePlain(w, http.StatusOK, "ready")
}

func (s *Server) handleNotFound(w http.ResponseWriter, r *http.Request) {
	writePlain(w, http.StatusNotFound, "not found")
}

func writePlain(w http.ResponseWriter, status int, body string) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(status)
	fmt.Fprintln(w, body)
}

// instrument wraps a handler with request metrics. The route label is passed in
// rather than read from the URL, which bounds cardinality by construction.
func (s *Server) instrument(route string, next http.HandlerFunc) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		s.metrics.inFlight.Inc()
		defer s.metrics.inFlight.Dec()

		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next(rec, r)

		elapsed := time.Since(start)
		s.metrics.requests.WithLabelValues(r.Method, route, strconv.Itoa(rec.status)).Inc()
		s.metrics.duration.WithLabelValues(r.Method, route).Observe(elapsed.Seconds())

		s.log.Debug("request served",
			"method", r.Method,
			"route", route,
			"status", rec.status,
			"duration_ms", elapsed.Milliseconds(),
			"remote_addr", r.RemoteAddr,
		)
	})
}

// statusRecorder captures the response status for use as a metric label.
type statusRecorder struct {
	http.ResponseWriter
	status      int
	wroteHeader bool
}

func (r *statusRecorder) WriteHeader(status int) {
	if r.wroteHeader {
		return
	}
	r.status = status
	r.wroteHeader = true
	r.ResponseWriter.WriteHeader(status)
}

func (r *statusRecorder) Write(b []byte) (int, error) {
	if !r.wroteHeader {
		r.WriteHeader(http.StatusOK)
	}
	return r.ResponseWriter.Write(b)
}

type metrics struct {
	requests *prometheus.CounterVec
	duration *prometheus.HistogramVec
	inFlight prometheus.Gauge
}

func newMetrics(reg prometheus.Registerer, info BuildInfo) *metrics {
	m := &metrics{
		requests: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "http_requests_total",
			Help: "Total number of HTTP requests served, by method, route and status code.",
		}, []string{"method", "route", "status"}),
		duration: prometheus.NewHistogramVec(prometheus.HistogramOpts{
			Name: "http_request_duration_seconds",
			Help: "HTTP request latency in seconds, by method and route.",
			// Tuned for sub-millisecond responses; the defaults start too coarse.
			Buckets: []float64{0.0005, 0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5},
		}, []string{"method", "route"}),
		inFlight: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "http_requests_in_flight",
			Help: "Number of HTTP requests currently being served.",
		}),
	}

	buildInfo := prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "hello_world_build_info",
		Help: "Build metadata for the running binary; the value is always 1.",
	}, []string{"version", "commit"})
	buildInfo.WithLabelValues(info.Version, info.Commit).Set(1)

	reg.MustRegister(m.requests, m.duration, m.inFlight, buildInfo)
	m.initSeries()
	return m
}

// initSeries exports the label sets this router can produce as zero from
// startup, so rate() on a new replica sees zero instead of a missing series.
func (m *metrics) initSeries() {
	known := []struct {
		route    string
		statuses []int
	}{
		{"/", []int{http.StatusOK}},
		{"/healthz", []int{http.StatusOK}},
		// Readiness returns 503 for the whole drain window.
		{"/readyz", []int{http.StatusOK, http.StatusServiceUnavailable}},
		{"other", []int{http.StatusNotFound}},
	}

	for _, k := range known {
		m.duration.WithLabelValues(http.MethodGet, k.route)
		for _, status := range k.statuses {
			m.requests.WithLabelValues(http.MethodGet, k.route, strconv.Itoa(status))
		}
	}
}
