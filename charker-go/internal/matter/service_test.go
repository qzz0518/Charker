package matter

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"charker/internal/product"
)

// The fake helper is this test binary re-run with FAKE_MATTER_LOG set. It
// logs its arguments and every stdin line to that file and plays the
// helper's side of the protocol:
//   - onboarding, then fabrics (FAKE_MATTER_FABRICS, default 0);
//   - once it has heard every port, FAKE_MATTER_COMMAND ("index:on") as a
//     command, or exits 3 with FAKE_MATTER_CRASH;
//   - exits 0 on a shutdown line or stdin EOF.
func TestHelperProcess(t *testing.T) {
	logPath := os.Getenv("FAKE_MATTER_LOG")
	if logPath == "" {
		return
	}
	os.Exit(fakeHelper(logPath))
}

func fakeHelper(logPath string) int {
	logf, err := os.OpenFile(logPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return 2
	}
	defer logf.Close()
	args := os.Args[slices.Index(os.Args, "--")+1:]
	fmt.Fprintf(logf, "args %s\n", strings.Join(args, " "))
	ports := 0
	if i := slices.Index(args, "--ports"); i >= 0 {
		ports = len(strings.Split(args[i+1], ","))
	}
	fmt.Fprintln(os.Stderr, "fake helper up")
	fmt.Println(`{"type":"onboarding","qr":"MT:FAKE","manual_code":"34970112332"}`)
	fabrics := os.Getenv("FAKE_MATTER_FABRICS")
	if fabrics == "" {
		fabrics = "0"
	}
	fmt.Printf(`{"type":"fabrics","count":%s}`+"\n", fabrics)
	heard := map[string]bool{}
	in := bufio.NewScanner(os.Stdin)
	for in.Scan() {
		line := in.Text()
		fmt.Fprintln(logf, line)
		if line == shutdownLine {
			return 0
		}
		e, ok := parseHost(line)
		if !ok || heard[e] || len(heard) >= ports {
			continue
		}
		heard[e] = true
		if len(heard) < ports {
			continue
		}
		if os.Getenv("FAKE_MATTER_CRASH") != "" {
			return 3
		}
		if c := os.Getenv("FAKE_MATTER_COMMAND"); c != "" {
			index, onText, _ := strings.Cut(c, ":")
			fmt.Printf(`{"type":"command","index":%s,"on":%s}`+"\n", index, onText)
		}
	}
	return 0
}

// parseHost returns the index of a port line.
func parseHost(line string) (string, bool) {
	const p = `{"type":"port","index":`
	if !strings.HasPrefix(line, p) {
		return "", false
	}
	i, _, ok := strings.Cut(line[len(p):], ",")
	return i, ok
}

type fake struct {
	t       *testing.T
	log     string
	dir     string
	svc     *Service
	mu      sync.Mutex
	cmds    []string
	states  []Status
	answers func(index int, on bool)
}

func newFake(t *testing.T, env ...string) *fake {
	t.Helper()
	f := &fake{t: t, dir: t.TempDir()}
	f.log = filepath.Join(f.dir, "transcript")
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	f.svc = NewService(Options{
		Helper: exe,
		Args:   []string{"-test.run=^TestHelperProcess$", "--"},
		Env:    append(append(os.Environ(), "FAKE_MATTER_LOG="+f.log), env...),
		Logf:   func(format string, args ...any) { t.Logf(format, args...) },
		OnCommand: func(index int, on bool) {
			f.mu.Lock()
			f.cmds = append(f.cmds, fmt.Sprintf("%d:%v", index, on))
			answer := f.answers
			f.mu.Unlock()
			if answer != nil {
				answer(index, on)
			}
		},
		OnStatus: func(s Status) {
			f.mu.Lock()
			f.states = append(f.states, s)
			f.mu.Unlock()
		},
	})
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		f.svc.Shutdown(ctx)
	})
	return f
}

func (f *fake) config(ports int) Config {
	labels := []string{"C1", "C2", "C3", "C4", "USB-A"}[:ports]
	return Config{Storage: filepath.Join(f.dir, "a2687"), Name: "Charker 160W", Labels: labels, UDPPort: 5540}
}

func (f *fake) transcript() []string {
	b, _ := os.ReadFile(f.log)
	return strings.Split(strings.TrimSpace(string(b)), "\n")
}

func (f *fake) waitFor(what string, cond func() bool) {
	f.t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			f.t.Fatalf("timed out waiting for %s; status %+v, transcript:\n%s",
				what, f.svc.Status(), strings.Join(f.transcript(), "\n"))
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func (f *fake) waitLine(line string) {
	f.t.Helper()
	f.waitFor(line, func() bool { return slices.Contains(f.transcript(), line) })
}

func (f *fake) count(prefix string) int {
	n := 0
	for _, l := range f.transcript() {
		if strings.HasPrefix(l, prefix) {
			n++
		}
	}
	return n
}

func TestServiceRoundTrip(t *testing.T) {
	f := newFake(t, "FAKE_MATTER_COMMAND=1:true")
	f.answers = func(index int, on bool) {
		// The app refuses: the real state goes back.
		f.svc.Resend(index)
	}
	f.svc.Start(f.config(3))
	f.svc.Update([]PortState{{On: true, VoltageMV: 5000, CurrentMA: 100, PowerMW: 500}})

	f.waitFor("pairing code", func() bool { return f.svc.Status().State == StateWaiting })
	st := f.svc.Status()
	if st.QR != "MT:FAKE" || st.ManualCode != "34970112332" || st.Fabrics != 0 || !st.Running || !st.MDNSOK {
		t.Fatalf("status %+v", st)
	}
	off := PortState{}
	f.waitLine(portLine(0, PortState{On: true, VoltageMV: 5000, CurrentMA: 100, PowerMW: 500}))
	f.waitLine(portLine(2, off))
	if got := f.transcript()[0]; got != "args --storage "+f.config(3).Storage+" --name Charker 160W --ports C1,C2,C3 --udp-port 5540" {
		t.Fatalf("args: %s", got)
	}

	// Home switched port 1 on; the app refused and resent port 1 off.
	f.waitFor("command", func() bool {
		f.mu.Lock()
		defer f.mu.Unlock()
		return slices.Equal(f.cmds, []string{"1:true"})
	})
	f.waitFor("answer", func() bool { return f.count(portLine(1, off)) == 2 })

	// Only changes go out.
	f.svc.Update([]PortState{{On: true, VoltageMV: 5000, CurrentMA: 100, PowerMW: 500}, {On: true}})
	f.waitLine(portLine(1, PortState{On: true}))
	if n := f.count(`{"type":"port","index":0`); n != 1 {
		t.Fatalf("port 0 written %d times", n)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	f.svc.Shutdown(ctx)
	if tr := f.transcript(); tr[len(tr)-1] != shutdownLine {
		t.Fatalf("last line %q", tr[len(tr)-1])
	}
	if st := f.svc.Status(); st.State != StateOff || st.Running {
		t.Fatalf("after shutdown %+v", st)
	}
}

func TestServiceAnswersAnUnansweredCommand(t *testing.T) {
	old := commandTimeout
	commandTimeout = 100 * time.Millisecond
	t.Cleanup(func() { commandTimeout = old })

	f := newFake(t, "FAKE_MATTER_COMMAND=0:false")
	f.svc.Start(f.config(3))
	f.svc.Update([]PortState{{On: true}})
	// No answer from the app: the timeout sends the real state.
	f.waitFor("timeout answer", func() bool { return f.count(portLine(0, PortState{On: true})) == 2 })
}

func TestServicePaired(t *testing.T) {
	f := newFake(t, "FAKE_MATTER_FABRICS=2")
	f.svc.Start(f.config(5))
	f.waitFor("paired", func() bool { return f.svc.Status().State == StatePaired })
	if st := f.svc.Status(); st.Fabrics != 2 || st.QR != "" {
		t.Fatalf("paired status %+v", st)
	}
	f.waitLine(portLine(4, PortState{}))
}

func TestServiceRestartsWithBackoff(t *testing.T) {
	old := restartDelays
	restartDelays = []time.Duration{50 * time.Millisecond, 100 * time.Millisecond}
	t.Cleanup(func() { restartDelays = old })

	f := newFake(t, "FAKE_MATTER_CRASH=1")
	f.svc.Start(f.config(3))
	f.waitFor("three launches", func() bool { return f.count("args ") >= 3 })
	f.mu.Lock()
	sawRestarting := slices.ContainsFunc(f.states, func(s Status) bool { return s.State == StateRestarting })
	f.mu.Unlock()
	if !sawRestarting {
		t.Fatal("never reported restarting")
	}
	f.svc.Stop()
	n := f.count("args ")
	time.Sleep(300 * time.Millisecond)
	if f.count("args ") != n {
		t.Fatal("a stopped service relaunched")
	}
	if st := f.svc.Status(); st.State != StateOff {
		t.Fatalf("after stop %+v", st)
	}
}

func TestServiceResetPairing(t *testing.T) {
	f := newFake(t)
	cfg := f.config(3)
	f.svc.Start(cfg)
	f.svc.Update([]PortState{{}, {On: true}})
	f.waitFor("first launch", func() bool { return f.svc.Status().State == StateWaiting })
	marker := filepath.Join(cfg.Storage, "pairing.json")
	if err := os.WriteFile(marker, []byte("{}"), 0o644); err != nil {
		t.Fatal(err)
	}
	f.svc.ResetPairing()
	f.waitFor("second launch", func() bool { return f.count("args ") == 2 })
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatalf("storage kept: %v", err)
	}
	// The old helper was told to stop before the new one started, and the
	// new one hears the port states again.
	tr := f.transcript()
	if i := slices.Index(tr, shutdownLine); i < 0 || i > slices.IndexFunc(tr[1:], func(l string) bool { return strings.HasPrefix(l, "args ") })+1 {
		t.Fatalf("shutdown not before the relaunch:\n%s", strings.Join(tr, "\n"))
	}
	f.waitFor("ports again", func() bool { return f.count(portLine(1, PortState{On: true})) == 2 })
}

func TestServiceUnavailable(t *testing.T) {
	s := NewService(Options{Helper: filepath.Join(t.TempDir(), "missing", helperName)})
	s.Start(Config{Storage: t.TempDir(), Name: "N", Labels: []string{"C1", "C2", "C3"}, UDPPort: 5540})
	deadline := time.Now().Add(5 * time.Second)
	for s.Status().State != StateUnavailable {
		if time.Now().After(deadline) {
			t.Fatalf("status %+v", s.Status())
		}
		time.Sleep(10 * time.Millisecond)
	}
	s.Stop()
}

func TestHomeRoutesCommandsAndAnswersBoth(t *testing.T) {
	dir := t.TempDir()
	logPath := filepath.Join(dir, "transcript")
	exe, _ := os.Executable()
	var mu sync.Mutex
	var got []string
	var h *Home
	h = NewHome(HomeOptions{
		Dir:      dir,
		Helper:   exe,
		Localize: func(k string) string { return strings.Replace(k, "端口", "Ports", 1) },
		OnCommand: func(index int, target Target, on bool) {
			mu.Lock()
			got = append(got, target.Label+":"+strconv.FormatBool(on))
			mu.Unlock()
			h.Resend(index)
		},
	})
	// Both services re-exec the fake helper.
	for _, s := range []*Service{h.whole, h.ports} {
		s.opts.Args = []string{"-test.run=^TestHelperProcess$", "--"}
		s.opts.Env = append(os.Environ(), "FAKE_MATTER_LOG="+logPath, "FAKE_MATTER_COMMAND=4:false")
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		h.Shutdown(ctx)
	})
	h.SetProduct(product.ProductA2345)
	h.Update([]PortState{{}, {}, {}, {}, {On: true}})
	deadline := time.Now().Add(10 * time.Second)
	usbA := portLine(4, PortState{On: true})
	for {
		b, _ := os.ReadFile(logPath)
		mu.Lock()
		n := len(got)
		mu.Unlock()
		// Each helper: the connect line or update, then the answer, both
		// helpers answered on each command, so at least 4 lines.
		if n == 2 && strings.Count(string(b), usbA) >= 4 &&
			strings.Contains(string(b), "--name Charker 250W Ports --ports 250W C1,250W C2,250W C3,250W C4,250W USB-A --udp-port 5541 --bridge") &&
			strings.Contains(string(b), "--name Charker 250W --ports C1,C2,C3,C4,USB-A --udp-port 5540") {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("commands %v, transcript:\n%s", got, b)
		}
		time.Sleep(10 * time.Millisecond)
	}
	if got[0] != "USB-A:false" || got[1] != "USB-A:false" {
		t.Fatalf("commands %v", got)
	}
	if st := h.Status(); st.Whole.State != StateWaiting || st.Ports.State != StateWaiting {
		t.Fatalf("status %+v", st)
	}
}
