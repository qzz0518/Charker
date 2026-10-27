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
	mygo.App.SetName(appName)
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
	forceDemo := devForceMock()
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
		Mock:          persisted.DemoMode || forceDemo,
		Remembered:    remembered,
		LastDevice:    persisted.LastDeviceID,
		WritesEnabled: persisted.WritesEnabled,
	})
	// The energy ledger persists under the same user-data directory; the
	// session's telemetry samples feed it while the app runs.
	energyService := app.NewEnergyService(dataDir, persisted.EnergyPricePerKWh, persisted.EnergyCurrencyCode)
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
		ForceDemo:     forceDemo,
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
