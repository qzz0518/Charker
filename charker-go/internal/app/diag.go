package app

import (
	"log"
	"strings"
)

// Diag is the development-only diagnostics service bound as "CharkerDiag" in
// the dev build (charkerdev). A preload script injected into the main window
// reports what the page sees — window.mygo presence, DOM readiness, AppState
// size, JavaScript errors — back through it, because mygo 0.7.1's EvalAs and
// CapturePage deadlock on Windows/WebView2 and must not be used for tests.
// Nothing binds this service in a release build.
type Diag struct{}

// NewDiag returns the diagnostics service.
func NewDiag() *Diag { return &Diag{} }

// Report appends one page-side diagnostic line to the app log.
func (d *Diag) Report(kind, text string) (any, error) {
	if len(text) > 8000 {
		text = text[:8000] + "…"
	}
	log.Printf("page[%s]: %s", kind, strings.ReplaceAll(text, "\n", " "))
	return nil, nil
}
