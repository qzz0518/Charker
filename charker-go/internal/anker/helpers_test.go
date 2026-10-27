package anker

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"sync"
	"testing"
	"time"
)

// stubTransport answers every request in-process, keeping the real request
// URL (and host) intact, like the Swift tests' URLProtocol stub.
type stubTransport struct {
	mu      sync.Mutex
	handler func(*http.Request, []byte) (int, []byte)
	hosts   []string
	calls   int
}

func (s *stubTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	var body []byte
	if req.Body != nil {
		body, _ = io.ReadAll(req.Body)
	}
	s.mu.Lock()
	s.hosts = append(s.hosts, req.URL.Host)
	s.calls++
	h := s.handler
	s.mu.Unlock()
	status, data := h(req, body)
	return &http.Response{
		StatusCode: status,
		Header:     http.Header{"Content-Type": []string{"application/json"}},
		Body:       io.NopCloser(bytes.NewReader(data)),
		Request:    req,
	}, nil
}

func stubClient(h func(*http.Request, []byte) (int, []byte)) (*http.Client, *stubTransport) {
	t := &stubTransport{handler: h}
	return &http.Client{Transport: t, CheckRedirect: func(*http.Request, []*http.Request) error {
		return http.ErrUseLastResponse
	}}, t
}

func jsonResponse(tb testing.TB, v any) (int, []byte) {
	tb.Helper()
	data, err := json.Marshal(v)
	if err != nil {
		tb.Fatalf("marshal: %v", err)
	}
	return 200, data
}

func mustHex(tb testing.TB, s string) []byte {
	tb.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		tb.Fatalf("bad hex %q: %v", s, err)
	}
	return b
}

func decodeBody(tb testing.TB, body []byte) map[string]any {
	tb.Helper()
	var m map[string]any
	if err := json.Unmarshal(body, &m); err != nil {
		tb.Fatalf("body is not JSON: %v (%s)", err, body)
	}
	return m
}

func farFuture() time.Time { return time.Unix(4_000_000_000, 0) }
