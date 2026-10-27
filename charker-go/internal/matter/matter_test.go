package matter

import (
	"slices"
	"testing"

	"charker/internal/product"
)

func TestPortLine(t *testing.T) {
	got := portLine(2, PortState{On: true, VoltageMV: 20000, CurrentMA: 1500, PowerMW: 30000})
	want := `{"type":"port","index":2,"on":true,"voltage_mv":20000,"current_ma":1500,"power_mw":30000}`
	if got != want {
		t.Fatalf("got %s", got)
	}
	if got := portLine(-1, PortState{VoltageMV: -5}); got != `{"type":"port","index":0,"on":false,"voltage_mv":0,"current_ma":0,"power_mw":0}` {
		t.Fatalf("clamping: %s", got)
	}
}

func TestParseEvent(t *testing.T) {
	cases := map[string]event{
		`{"type":"onboarding","qr":"MT:ABC","manual_code":"34970112332"}`: {kind: evOnboarding, qr: "MT:ABC", manualCode: "34970112332"},
		`{"type":"fabrics","count":2}`:                                    {kind: evFabrics, count: 2},
		`{"type":"command","index":0,"on":false}`:                         {kind: evCommand, index: 0, on: false},
		`{"type":"mdns","ok":false}`:                                      {kind: evMDNS, ok: false},
		`{"type":"error","code":"bind","message":"a \"b\""}`:              {kind: evError, code: "bind", message: `a "b"`},
		`{"type":"error"}`:                                                {kind: evError, code: "internal"},
		`{"type":"fabrics","count":1,"future":true}`:                      {kind: evFabrics, count: 1},
	}
	for line, want := range cases {
		got, ok := parseEvent(line)
		if !ok || got != want {
			t.Errorf("%s: got %+v %v", line, got, ok)
		}
	}
	for _, line := range []string{
		"", "garbage", `{"type":"reboot"}`, `{"type":"onboarding","qr":"MT:A"}`,
		`{"type":"fabrics","count":-1}`, `{"type":"command","index":-1,"on":true}`,
		`{"type":"command","index":0}`, `{"type":"mdns"}`, `{"type":"fabrics","count":"2"}`,
	} {
		if e, ok := parseEvent(line); ok {
			t.Errorf("%q parsed as %+v", line, e)
		}
	}
}

func TestFormatManualCode(t *testing.T) {
	for in, want := range map[string]string{
		"34970112332": "3497-011-2332",
		"3497011233":  "3497011233",
		"3497011233a": "3497011233a",
	} {
		if got := FormatManualCode(in); got != want {
			t.Errorf("%s: %s", in, got)
		}
	}
}

func on(i int, s PortState) string { return portLine(i, s) }

func TestPortSync(t *testing.T) {
	var p PortSync
	if got := p.Update([]PortState{{On: true}}); got != nil {
		t.Fatalf("no helper, no lines: %v", got)
	}
	// Ports nothing describes read off.
	lines := p.Connect(3)
	want := []string{on(0, PortState{On: true}), on(1, PortState{}), on(2, PortState{})}
	if !slices.Equal(lines, want) {
		t.Fatalf("connect: %v", lines)
	}
	// Only what changed.
	lines = p.Update([]PortState{{On: true}, {On: true, PowerMW: 5000}, {}})
	if !slices.Equal(lines, []string{on(1, PortState{On: true, PowerMW: 5000})}) {
		t.Fatalf("update: %v", lines)
	}
	if lines := p.Update([]PortState{{On: true}, {On: true, PowerMW: 5000}, {}}); lines != nil {
		t.Fatalf("unchanged: %v", lines)
	}

	// Home switches port 0 off: the helper already shows it, readings keep
	// flowing with the requested `on` until the answer.
	if !p.Request(0, false) {
		t.Fatal("request refused")
	}
	if p.Request(3, true) || p.Request(-1, true) {
		t.Fatal("request for a port the helper does not have")
	}
	if lines := p.Update([]PortState{{On: true}, {On: true, PowerMW: 5000}, {}}); lines != nil {
		t.Fatalf("the requested state is already shown: %v", lines)
	}
	lines = p.Update([]PortState{{On: true, PowerMW: 1000}, {On: true, PowerMW: 5000}, {}})
	if !slices.Equal(lines, []string{on(0, PortState{On: false, PowerMW: 1000})}) {
		t.Fatalf("readings under a request: %v", lines)
	}
	// The refusal: the real state goes out and flips Home back.
	line, ok := p.Answer(0)
	if !ok || line != on(0, PortState{On: true, PowerMW: 1000}) {
		t.Fatalf("answer: %s %v", line, ok)
	}
	// An answer is written even when nothing changed.
	if line, _ := p.Answer(0); line != on(0, PortState{On: true, PowerMW: 1000}) {
		t.Fatalf("repeat answer: %s", line)
	}
	if _, ok := p.Answer(5); ok {
		t.Fatal("answer for a port the helper does not have")
	}

	// A new helper hears everything, requests forgotten, desired kept.
	p.Request(1, false)
	p.Disconnect()
	if lines := p.Update([]PortState{{On: true}, {On: true}, {}}); lines != nil {
		t.Fatalf("disconnected: %v", lines)
	}
	lines = p.Connect(3)
	if !slices.Equal(lines, []string{on(0, PortState{On: true}), on(1, PortState{On: true}), on(2, PortState{})}) {
		t.Fatalf("reconnect: %v", lines)
	}
}

func TestLayout(t *testing.T) {
	l := NewLayout(product.ProductA2687, Grouped)
	if l.Name() != "Charker 160W" || l.StorageName() != "a2687" || l.UDPPort() != 5540 ||
		!slices.Equal(l.Labels(), []string{"C1", "C2", "C3"}) {
		t.Fatalf("160W grouped: %s %s %d %v", l.Name(), l.StorageName(), l.UDPPort(), l.Labels())
	}
	b := NewLayout(product.ProductA2345, Bridged)
	if b.Name() != "Charker 250W 端口" || b.StorageName() != "a2345-ports" || b.UDPPort() != 5541 ||
		!slices.Equal(b.Labels(), []string{"250W C1", "250W C2", "250W C3", "250W C4", "250W USB-A"}) {
		t.Fatalf("250W bridged: %s %s %d %v", b.Name(), b.StorageName(), b.UDPPort(), b.Labels())
	}
	if tgt, ok := b.Target(4); !ok || !slices.Equal(tgt.Ports, []product.PortID{product.PortA1, product.PortA2}) {
		t.Fatalf("USB-A target: %+v", tgt)
	}
	if _, ok := b.Target(5); ok {
		t.Fatal("target 5")
	}
	for _, s := range append(b.Labels(), b.Name()) {
		if len(s) > 32 {
			t.Errorf("%q is longer than 32 bytes", s)
		}
	}
}

func TestStatesA2345(t *testing.T) {
	l := NewLayout(product.ProductA2345, Grouped)
	r := &product.Reading{Product: product.ProductA2345, Ports: []product.PortReading{
		{Enabled: true, Volts: 20, Amps: 1.5, Watts: 30},
		{}, {}, {},
		{Enabled: true, Volts: 5, Amps: 1, Watts: 5},
		{Enabled: true, Volts: 9, Amps: 2, Watts: 18},
	}}
	// Before settings: live output proves on, none keeps the previous.
	got := l.States(r, true, nil, []PortState{{}, {On: true}})
	want := []PortState{
		{On: true, VoltageMV: 20000, CurrentMA: 1500, PowerMW: 30000},
		{On: true}, {}, {},
		{On: true, VoltageMV: 9000, CurrentMA: 3000, PowerMW: 23000},
	}
	if !slices.Equal(got, want) {
		t.Fatalf("live:\n got %+v\nwant %+v", got, want)
	}
	// Settings rule the switch; stale readings zero V/I/P.
	got = l.States(r, false, map[product.PortID]bool{product.PortC1: false, product.PortA1: true}, []PortState{{}, {On: true}})
	want = []PortState{{}, {On: true}, {}, {}, {On: true}}
	if !slices.Equal(got, want) {
		t.Fatalf("settings:\n got %+v\nwant %+v", got, want)
	}
}

func TestStatesA2687(t *testing.T) {
	l := NewLayout(product.ProductA2687, Grouped)
	r := &product.Reading{Product: product.ProductA2687, Ports: []product.PortReading{
		{Enabled: true, Volts: 20.004, Amps: 2, Watts: 40.08},
		{Enabled: false, Volts: 5},
	}}
	got := l.States(r, true, nil, []PortState{{}, {}, {On: true}})
	want := []PortState{{On: true, VoltageMV: 20004, CurrentMA: 2000, PowerMW: 40080}, {}, {On: true}}
	if !slices.Equal(got, want) {
		t.Fatalf("live:\n got %+v\nwant %+v", got, want)
	}
	if got := l.States(r, false, nil, nil); !slices.Equal(got, []PortState{{On: true}, {}, {}}) {
		t.Fatalf("stale: %+v", got)
	}
	if got := l.States(nil, true, nil, []PortState{{On: true}}); !slices.Equal(got, []PortState{{On: true}, {}, {}}) {
		t.Fatalf("no reading: %+v", got)
	}
}
