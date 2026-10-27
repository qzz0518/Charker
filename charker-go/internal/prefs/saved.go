package prefs

import (
	"encoding/json"
	"os"
	"sort"
	"strings"
)

// SavedCharger is one remembered charger (spec §1.5, JSON in
// saved-chargers.json). LastConnectedAt is epoch milliseconds, 0 = never.
type SavedCharger struct {
	ID              string `json:"id"`
	Nickname        string `json:"nickname,omitempty"`
	SerialNumber    string `json:"serialNumber,omitempty"`
	LastConnectedAt int64  `json:"lastConnectedAt"`
	Name            string `json:"name,omitempty"`
	Address         string `json:"address,omitempty"`
	Product         string `json:"product,omitempty"`
}

const nicknameLimit = 24

// LoadSavedChargers loads the saved-charger list. A missing file yields an
// empty list; a corrupt file is quarantined and an empty list is returned.
// Decoding is entry-tolerant: a bad record is dropped, the rest survive, and
// duplicate ids keep the first.
func (s *Store) LoadSavedChargers() []SavedCharger {
	data, ok := s.readFile(SavedFile)
	if !ok {
		return []SavedCharger{}
	}
	var raw []json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		s.quarantine(SavedFile)
		return []SavedCharger{}
	}
	out := make([]SavedCharger, 0, len(raw))
	seen := make(map[string]bool, len(raw))
	seenSerial := make(map[string]bool, len(raw))
	for _, entry := range raw {
		var c SavedCharger
		if err := json.Unmarshal(entry, &c); err != nil {
			continue
		}
		c = normalizeSavedCharger(c)
		if c.ID == "" || seen[c.ID] {
			continue
		}
		if c.SerialNumber != "" && seenSerial[c.SerialNumber] {
			continue // serial twin already present
		}
		seen[c.ID] = true
		if c.SerialNumber != "" {
			seenSerial[c.SerialNumber] = true
		}
		out = append(out, c)
	}
	return SortReconnect(out)
}

// SaveSavedChargers writes the list atomically in reconnect order.
func (s *Store) SaveSavedChargers(list []SavedCharger) error {
	list = SortReconnect(NormalizeSaved(list))
	data, err := json.MarshalIndent(list, "", "  ")
	if err != nil {
		return err
	}
	return s.writeFileAtomic(SavedFile, append(data, '\n'))
}

// NormalizeSaved trims fields, drops empty/duplicate ids, resolves serial
// twins (first wins) and caps nicknames. It preserves array order.
func NormalizeSaved(list []SavedCharger) []SavedCharger {
	out := make([]SavedCharger, 0, len(list))
	seen := make(map[string]bool, len(list))
	seenSerial := make(map[string]bool, len(list))
	for _, c := range list {
		c = normalizeSavedCharger(c)
		if c.ID == "" || seen[c.ID] {
			continue
		}
		if c.SerialNumber != "" && seenSerial[c.SerialNumber] {
			continue
		}
		seen[c.ID] = true
		if c.SerialNumber != "" {
			seenSerial[c.SerialNumber] = true
		}
		out = append(out, c)
	}
	return out
}

// SortReconnect orders chargers most recently connected first; entries that
// were never connected keep their relative order at the end.
func SortReconnect(list []SavedCharger) []SavedCharger {
	out := append([]SavedCharger(nil), list...)
	sort.SliceStable(out, func(i, j int) bool {
		a, b := out[i].LastConnectedAt, out[j].LastConnectedAt
		if (a == 0) != (b == 0) {
			return a != 0 // connected entries before never-connected ones
		}
		return a > b
	})
	return out
}

// ReconnectOrder returns saved ids in reconnect order.
func ReconnectOrder(list []SavedCharger) []string {
	sorted := SortReconnect(list)
	out := make([]string, 0, len(sorted))
	for _, c := range sorted {
		out = append(out, c.ID)
	}
	return out
}

// FindSaved returns the entry for id.
func FindSaved(list []SavedCharger, id string) (SavedCharger, bool) {
	for _, c := range list {
		if c.ID == id {
			return c, true
		}
	}
	return SavedCharger{}, false
}

// UpsertSaved records a connection: an existing id keeps its nickname and gets
// a refreshed timestamp/serial; a different id carrying a known serial takes
// over that entry (nickname preserved) and removes the twin; otherwise the
// entry is appended.
func UpsertSaved(list []SavedCharger, c SavedCharger) []SavedCharger {
	c = normalizeSavedCharger(c)
	if c.ID == "" {
		return SortReconnect(NormalizeSaved(list))
	}
	list = NormalizeSaved(list)
	for i := range list {
		if list[i].ID == c.ID {
			keep := list[i].Nickname
			if c.Nickname != "" {
				keep = c.Nickname
			}
			if c.SerialNumber == "" {
				c.SerialNumber = list[i].SerialNumber
			}
			if c.Name == "" {
				c.Name = list[i].Name
			}
			if c.Address == "" {
				c.Address = list[i].Address
			}
			if c.Product == "" {
				c.Product = list[i].Product
			}
			c.Nickname = keep
			list[i] = c
			return SortReconnect(dropSerialTwins(list, c.ID, c.SerialNumber))
		}
	}
	if c.SerialNumber != "" {
		for i := range list {
			if list[i].SerialNumber != c.SerialNumber {
				continue
			}
			nick := list[i].Nickname
			if c.Nickname == "" {
				c.Nickname = nick
			}
			if c.Name == "" {
				c.Name = list[i].Name
			}
			list[i] = c
			return SortReconnect(dropSerialTwins(list, c.ID, c.SerialNumber))
		}
	}
	list = append(list, c)
	return SortReconnect(list)
}

// RemoveSaved drops one charger by id.
func RemoveSaved(list []SavedCharger, id string) []SavedCharger {
	out := make([]SavedCharger, 0, len(list))
	for _, c := range list {
		if c.ID != id {
			out = append(out, c)
		}
	}
	return SortReconnect(out)
}

// SetNickname updates (or clears) one entry's nickname.
func SetNickname(list []SavedCharger, id, nickname string) []SavedCharger {
	out := append([]SavedCharger(nil), list...)
	for i := range out {
		if out[i].ID == id {
			out[i].Nickname = trimNickname(nickname)
			break
		}
	}
	return out
}

// DisplayName renders the saved charger's display name:
// nickname, else "<product> · <last 4 of serial>", else the product name.
func DisplayName(c SavedCharger) string {
	if c.Nickname != "" {
		return c.Nickname
	}
	base := "Anker Prime 160W"
	if strings.EqualFold(c.Product, "A2345") {
		base = "Anker Prime 250W"
	}
	if len(c.SerialNumber) >= 4 {
		return base + " · " + c.SerialNumber[len(c.SerialNumber)-4:]
	}
	return base
}

func normalizeSavedCharger(c SavedCharger) SavedCharger {
	c.ID = strings.TrimSpace(c.ID)
	c.Nickname = trimNickname(c.Nickname)
	c.SerialNumber = strings.TrimSpace(c.SerialNumber)
	c.Name = strings.TrimSpace(c.Name)
	c.Address = strings.TrimSpace(c.Address)
	c.Product = strings.TrimSpace(c.Product)
	if c.LastConnectedAt < 0 {
		c.LastConnectedAt = 0
	}
	return c
}

// dropSerialTwins removes entries that share serial with keepID but have a
// different id (a charger seen under a second host identifier).
func dropSerialTwins(list []SavedCharger, keepID, serial string) []SavedCharger {
	if serial == "" {
		return list
	}
	out := list[:0]
	for _, c := range list {
		if c.ID != keepID && c.SerialNumber == serial {
			continue
		}
		out = append(out, c)
	}
	return out
}

// RemoveSavedFile deletes the saved-charger file (used by tests/forget-all).
func (s *Store) RemoveSavedFile() error {
	err := os.Remove(s.path(SavedFile))
	if os.IsNotExist(err) {
		return nil
	}
	return err
}
