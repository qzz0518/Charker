// Command charker is the Windows port of Charker, an Anker Prime 160W
// charger companion built with MyGo (WebView2). The frontend is plain
// HTML/CSS/JS under web/, embedded as-is with no build step.
package main

import (
	"context"
	"embed"
	"io"
	"io/fs"
	"log"
	"os"
	"time"

	"charker/internal/app"
	"charker/internal/prefs"

	"github.com/egoist/mygo"
)

// //go:embed all:web embeds the frontend sources served at the app origin.
//
//go:embed all:web
var webFS embed.FS

// version is overridden by -X main.version at build time.
var version = "0.1.0"

func main() {
	if f := logFile(); f != nil {
		defer f.Close()
		log.SetOutput(io.MultiWriter(os.Stderr, f))
	}
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)
	log.Printf("charker %s starting (pid %d)", version, os.Getpid())

	// Identity: used for PathUserData, the single-instance key and Secrets.
	mygo.App.SetName("Charker")
	mygo.App.SetVersion(version)

	// Only one Charker at a time: a second launch forwards its command line
	// to the first and exits.
	if !mygo.App.RequestSingleInstanceLock() {
		log.Printf("another Charker instance is running; exiting")
		return
	}

	dataDir := ""
	if dir, err := mygo.App.Path(mygo.PathUserData); err != nil {
		log.Printf("app: user data dir: %v", err)
	} else {
		dataDir = dir
	}
	forceMock := devForceMock()
	var store *prefs.Store
	var persisted prefs.Preferences
	if dataDir != "" {
		store = prefs.NewStore(dataDir)
		persisted = store.LoadPreferences()
	} else {
		persisted = prefs.DefaultPreferences()
	}
	remembered := []string{}
	if store != nil {
		for _, c := range store.LoadSavedChargers() {
			if c.ID != "" {
				remembered = append(remembered, c.ID)
			}
		}
	}

	// The real session engine (core-session) with the Windows BLE transport,
	// or its simulator when the user last ran in demo mode.
	session := app.NewSessionHost(app.SessionConfig{
		Mock:          persisted.MockMode || forceMock,
		Remembered:    remembered,
		LastDevice:    persisted.LastDeviceID,
		WritesEnabled: persisted.WritesEnabled,
	})
	// The energy ledger persists under the same user-data directory; the
	// session's telemetry samples feed it while the app runs.
	energyService := app.NewEnergyService(dataDir, persisted.EnergyPricePerKWh, persisted.EnergyCurrency)
	var energy app.Energy
	if energyService != nil {
		energy = energyService
		session.SetOnSample(energyService.RecordAt)
	}

	a := app.New(app.Config{
		Version:       version,
		IconPNG:       iconPNG(),
		TrayIconPNG:   app.TrayIconPNG(iconPNG()),
		Store:         store,
		ForceMock:     forceMock,
		Session:       session,
		Energy:        energy,
		PreloadScript: devPreloadScript(),
	})

	// Bind the service the pages call: window.mygo.call("Charker.State", …).
	mygo.BindAs("Charker", app.NewService(a))
	// The dev build additionally reports DOM/bridge diagnostics from the page
	// into dev.log (safe under the agent bridge, where mygo.EvalAs deadlocks).
	if devPreloadScript() != "" {
		mygo.BindAs("CharkerDiag", app.NewDiag())
	}

	web, err := fs.Sub(webFS, "web")
	if err != nil {
		log.Fatalf("app: embedded frontend: %v", err)
	}
	mygo.SetFrontend(newFrontend(web))

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	mygo.App.OnWindowAllClosed(func() { a.OnWindowAllClosed() })
	mygo.App.WhenReady(func() {
		a.StartUI()
		go a.RunSession(ctx)
		if win := a.Window(); win != nil {
			debugPage(a, win)
		}
		if d := devAutoQuit(); d > 0 {
			log.Printf("debug: auto-quit in %s", d)
			time.AfterFunc(d, a.Quit)
		}
	})
	if err := mygo.App.Run(); err != nil {
		log.Fatalf("app: run: %v", err)
	}
	a.Close()
	log.Printf("charker exited")
}

// iconPNG reads the embedded app icon (used for the window and the tray).
func iconPNG() []byte {
	data, err := fs.ReadFile(webFS, "web/assets/app-icon.png")
	if err != nil {
		log.Printf("app: app icon: %v", err)
		return nil
	}
	return data
}

// debugPage wires the dev-only self-test hooks. It never evaluates
// JavaScript from Go: on Windows/WebView2 mygo 0.7.1's EvalAs and CapturePage
// deadlock, so the page itself reports its state through the "CharkerDiag"
// service, and a screenshot is taken of the desktop while the app runs.
// CHARKER_TRAY_TEST=1 checks close-to-tray instead of screenshotting.
func debugPage(a *app.App, win *mygo.Window) {
	if os.Getenv("CHARKER_TRAY_TEST") == "1" {
		page := win.Page()
		if page == nil {
			return
		}
		page.OnDidFinishLoad(func() {
			time.AfterFunc(2*time.Second, func() {
				log.Printf("debug: tray test: closing the main window")
				win.Close()
			})
			time.AfterFunc(3*time.Second, func() {
				log.Printf("debug: tray test: after close visible=%v quitting=%v (app must still run)", win.IsVisible(), a.IsQuitting())
			})
			time.AfterFunc(3500*time.Millisecond, func() {
				log.Printf("debug: tray test: showing the window again (tray click path)")
				win.Show()
				win.Focus()
			})
			time.AfterFunc(4200*time.Millisecond, func() {
				log.Printf("debug: tray test: after show visible=%v", win.IsVisible())
			})
			time.AfterFunc(5*time.Second, func() {
				log.Printf("debug: tray test: quitting")
				a.Quit()
			})
		})
		return
	}
	path := os.Getenv("CHARKER_SHOT")
	if path == "" {
		return
	}
	page := win.Page()
	if page == nil {
		return
	}
	page.OnDidFinishLoad(func() {
		log.Printf("debug: page finished loading")
		time.AfterFunc(3500*time.Millisecond, func() {
			if devScreenshot(path) {
				log.Printf("debug: screenshot saved to %s", path)
			} else {
				log.Printf("debug: screenshot failed")
			}
			if os.Getenv("CHARKER_STAY") == "" {
				a.Quit()
			}
		})
	})
}
