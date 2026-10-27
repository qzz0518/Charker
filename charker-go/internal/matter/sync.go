package matter

// PortSync is what the helper has been told per port and what it still has
// to hear.
//
// A Home request stays open until the host answers it. Meanwhile readings
// keep flowing but the port keeps the requested `on`, so Home's switch does
// not flip back to the old value before the real answer arrives.
type PortSync struct {
	// desired is the latest state of every port, as the host sees it.
	desired []PortState
	// sent is, per port, what the running helper was last told; nil while
	// none runs. A nil entry has not been written yet.
	sent []*PortState
	// requested is the requested `on` per port index, until answered.
	requested map[int]bool
}

// Desired is the latest state of every port, as the host sees it.
func (p *PortSync) Desired() []PortState { return append([]PortState(nil), p.desired...) }

// Connect: a freshly launched helper with count ports hears every one.
func (p *PortSync) Connect(count int) []string {
	p.requested = nil
	p.sent = make([]*PortState, count)
	lines := make([]string, count)
	for i := range p.sent {
		lines[i] = p.write(i)
	}
	return lines
}

// Disconnect: no helper is listening any more. Desired stays for the next.
func (p *PortSync) Disconnect() {
	p.requested = nil
	p.sent = nil
}

// Update stores the latest states and returns lines for the ports that
// changed since they were last written.
func (p *PortSync) Update(states []PortState) []string {
	p.desired = append([]PortState(nil), states...)
	var lines []string
	for i, s := range p.sent {
		if s == nil || *s != p.state(i) {
			lines = append(lines, p.write(i))
		}
	}
	return lines
}

// Request records that Home switched a port; the helper already shows on.
// False for a port the helper does not have.
func (p *PortSync) Request(index int, on bool) bool {
	if index < 0 || index >= len(p.sent) {
		return false
	}
	if p.sent[index] != nil {
		p.sent[index].On = on
	}
	if p.requested == nil {
		p.requested = map[int]bool{}
	}
	p.requested[index] = on
	return true
}

// Answer is the answer to a request: the port's real state, written even
// when nothing changed, because only this turns a refused switch back.
func (p *PortSync) Answer(index int) (string, bool) {
	if index < 0 || index >= len(p.sent) {
		return "", false
	}
	delete(p.requested, index)
	return p.write(index), true
}

func (p *PortSync) state(index int) PortState {
	var s PortState
	if index < len(p.desired) {
		s = p.desired[index]
	}
	if on, ok := p.requested[index]; ok {
		s.On = on
	}
	return s
}

func (p *PortSync) write(index int) string {
	s := p.state(index)
	p.sent[index] = &s
	return portLine(index, s)
}
