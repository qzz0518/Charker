// Command webdev serves the pages to a regular browser for layout work: the
// same app layer and simulated charger as the app, the "Charker" calls over
// HTTP and its events over SSE, and web/ straight from disk, so a page edit
// needs only a reload. A small shim stands in for window.mygo.
//
//	go run ./cmd/webdev -addr 127.0.0.1:8765
//
// Then open http://127.0.0.1:8765/#dashboard (or screenshot it with
// tools/shot.ts). Nothing here ships in the app.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"

	"charker/internal/app"
	"charker/internal/prefs"
)

func main() {
	addr := flag.String("addr", "127.0.0.1:8765", "listen address")
	data := flag.String("data", "", "data directory (default: a fresh temp dir)")
	flag.Parse()

	dir := *data
	if dir == "" {
		var err error
		if dir, err = os.MkdirTemp("", "charker-webdev-"); err != nil {
			log.Fatal(err)
		}
	}
	hub := newHub()
	store := prefs.NewStore(dir)
	p := store.LoadPreferences()
	session := app.NewSessionHost(app.SessionConfig{Mock: true, WritesEnabled: p.WritesEnabled})
	energyService := app.NewEnergyService(dir, p.EnergyPricePerKWh, p.EnergyCurrencyCode, true)
	var energy app.Energy
	if energyService != nil {
		energy = energyService
		app.FeedEnergy(session, energyService)
	}
	a := app.New(app.Config{
		Version:   "0.0.0-dev",
		Store:     store,
		ForceDemo: true,
		Session:   session,
		Energy:    energy,
		Emit:      hub.send,
	})
	// The ledger follows the app's demo mode (AppModel.displayedEnergyHistory).
	energyService.Attach(a)
	service := app.NewService(a)
	go a.RunSession(context.Background())

	web := filepath.Join("web")
	mux := http.NewServeMux()
	mux.HandleFunc("/__dev/call", func(w http.ResponseWriter, r *http.Request) { handleCall(w, r, service) })
	mux.HandleFunc("/__dev/events", hub.serve)
	mux.HandleFunc("/__dev/shim.js", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/javascript")
		fmt.Fprint(w, shim)
	})
	files := http.FileServer(http.Dir(web))
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		if r.URL.Path == "/" || strings.HasSuffix(r.URL.Path, ".html") {
			name := strings.TrimPrefix(filepath.Clean(r.URL.Path), "/")
			if name == "" || name == "." {
				name = "index.html"
			}
			html, err := os.ReadFile(filepath.Join(web, name))
			if err != nil {
				http.Error(w, err.Error(), 500)
				return
			}
			page := strings.Replace(string(html), "<head>", "<head>\n    <script src=\"/__dev/shim.js\"></script>", 1)
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			fmt.Fprint(w, page)
			return
		}
		files.ServeHTTP(w, r)
	})
	log.Printf("webdev: http://%s (data %s)", *addr, dir)
	log.Fatal(http.ListenAndServe(*addr, mux))
}

// handleCall runs one "Charker.Method" with JSON arguments by reflection,
// as MyGo's binding does.
func handleCall(w http.ResponseWriter, r *http.Request, service *app.Charker) {
	var req struct {
		Method string            `json:"method"`
		Args   []json.RawMessage `json:"args"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, err.Error(), 400)
		return
	}
	name := strings.TrimPrefix(req.Method, "Charker.")
	m := reflect.ValueOf(service).MethodByName(name)
	if !m.IsValid() {
		http.Error(w, "no method "+req.Method, 404)
		return
	}
	t := m.Type()
	in := []reflect.Value{}
	next := 0
	for i := 0; i < t.NumIn(); i++ {
		pt := t.In(i)
		if pt == reflect.TypeOf((*context.Context)(nil)).Elem() {
			in = append(in, reflect.ValueOf(r.Context()))
			continue
		}
		v := reflect.New(pt)
		if next < len(req.Args) {
			if err := json.Unmarshal(req.Args[next], v.Interface()); err != nil {
				http.Error(w, fmt.Sprintf("argument %d: %v", next, err), 400)
				return
			}
		}
		next++
		in = append(in, v.Elem())
	}
	out := m.Call(in)
	var result any
	for _, o := range out {
		if o.Type() == reflect.TypeOf((*error)(nil)).Elem() {
			if !o.IsNil() {
				http.Error(w, o.Interface().(error).Error(), 500)
				return
			}
			continue
		}
		result = o.Interface()
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(result)
}

// hub fans the app's events out to the SSE streams.
type hub struct {
	mu      sync.Mutex
	clients map[chan []byte]bool
}

func newHub() *hub { return &hub{clients: map[chan []byte]bool{}} }

func (h *hub) send(event string, payload any) {
	data, err := json.Marshal(map[string]any{"event": event, "payload": payload})
	if err != nil {
		return
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	for c := range h.clients {
		select {
		case c <- data:
		default:
		}
	}
}

func (h *hub) serve(w http.ResponseWriter, r *http.Request) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "no streaming", 500)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-store")
	c := make(chan []byte, 16)
	h.mu.Lock()
	h.clients[c] = true
	h.mu.Unlock()
	defer func() {
		h.mu.Lock()
		delete(h.clients, c)
		h.mu.Unlock()
	}()
	flusher.Flush()
	for {
		select {
		case <-r.Context().Done():
			return
		case data := <-c:
			fmt.Fprintf(w, "data: %s\n\n", data)
			flusher.Flush()
		}
	}
}

const shim = `(() => {
  const listeners = {};
  const source = new EventSource('/__dev/events');
  source.onmessage = (e) => {
    const { event, payload } = JSON.parse(e.data);
    (listeners[event] || []).forEach((fn) => fn(payload));
  };
  window.mygo = {
    platform: 'win32',
    call(method, ...args) {
      return fetch('/__dev/call', { method: 'POST', body: JSON.stringify({ method, args }) }).then(
        async (r) => {
          if (!r.ok) throw new Error(await r.text());
          return r.json();
        },
      );
    },
    on(event, fn) {
      (listeners[event] ||= []).push(fn);
      return () => (listeners[event] = listeners[event].filter((f) => f !== fn));
    },
    window: { setTitle(t) { document.title = t; } },
  };
  const style = document.documentElement.style;
  style.setProperty('--mygo-titlebar-height', '32px');
  style.setProperty('--mygo-titlebar-inset-right', '138px');
})();
`
