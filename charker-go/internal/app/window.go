package app

import (
	"log"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/egoist/mygo"
)

// StartUI creates the app's UI. Call it from mygo.App.WhenReady: it registers
// the app lifecycle listeners, creates the tray icon and the main window.
func (a *App) StartUI() {
	// MyGo's own menus and controls speak the languages of the app; the
	// page's i18n follows AppState.app.locale.
	mygo.App.SetLanguages("zh-Hans", "en")
	a.mu.Lock()
	a.systemLocale = systemLocale()
	appearance := a.prefs.Appearance
	a.mu.Unlock()
	mygo.App.SetLocale(localeTag(a.locale()))
	applyAppearance(appearance)

	mygo.App.OnBeforeQuit(func(*mygo.QuitEvent) {
		a.SetQuitting()
	})
	mygo.App.OnSecondInstance(func(args []string, workingDir string) {
		log.Printf("app: second instance args=%q dir=%q", args, workingDir)
		a.showMainWindow()
	})

	if !mygo.WebViewAvailable() {
		log.Printf("app: WebView2 runtime is not available")
		mygo.Dialog.Error("Charker",
			"Charker needs the Microsoft Edge WebView2 runtime.\n"+
				"Install it from https://go.microsoft.com/fwlink/p/?LinkId=2124703 and start Charker again.")
		mygo.App.Quit()
		return
	}

	a.createTray()
	a.createMainWindow()
}

// createTray puts Charker in the notification area. Left click toggles the
// window, right click opens the context menu (Windows tray semantics,
// spec-mygo 閹?.2).
func (a *App) createTray() {
	tray, err := mygo.NewTray(mygo.TrayOptions{
		ID:             "charker",
		Icon:           a.trayIconPNG,
		IconIsTemplate: false,
		ToolTip:        "Charker",
	})
	if err != nil {
		log.Printf("app: tray icon: %v", err)
		return
	}
	a.uiMu.Lock()
	a.tray = tray
	a.uiMu.Unlock()
	tray.OnClick(func() { a.toggleMainWindow() })
	tray.OnRightClick(func() { a.showTrayMenu() })
	log.Printf("app: tray icon created")
}

// showTrayMenu opens the tray context menu with the strings of the current
// locale. The menu is set only for this popup so left clicks keep reaching
// OnClick (a tray menu would otherwise open on the next left click).
func (a *App) showTrayMenu() {
	a.uiMu.Lock()
	tray := a.tray
	a.uiMu.Unlock()
	if tray == nil {
		return
	}
	menu := mygo.NewMenu([]*mygo.MenuItem{
		{Label: a.tr(textTrayShow), Click: func(*mygo.MenuItem, *mygo.Window) { a.showMainWindow() }},
		{Label: a.tr(textTrayHide), Click: func(*mygo.MenuItem, *mygo.Window) { a.hideMainWindow() }},
		mygo.Separator(),
		{Label: a.tr(textTrayQuit), Click: func(*mygo.MenuItem, *mygo.Window) { a.quit() }},
	})
	tray.SetMenu(menu)
	defer tray.SetMenu(nil)
	tray.PopUpMenu()
}

// createMainWindow creates the main window at the overview's comfortable size
// (969x840, min 890x600, as MainWindowSizing on macOS), hidden until its first
// page is ready to avoid a white flash. MyGo sizes are device-independent.
func (a *App) createMainWindow() {
	win := mygo.NewWindow(mygo.WindowOptions{
		Title:           "Charker",
		URL:             "/",
		Width:           969,
		Height:          840,
		UseContentSize:  true,
		MinWidth:        890,
		MinHeight:       600,
		BackgroundColor: "light-dark(#F0F1F4, #0D0E12)",
		// The page draws the title strip; Windows keeps its caption buttons.
		TitleBarStyle: mygo.TitleBarHidden,
		StateKey:      "main",
		Hidden:        true,
		Page: mygo.PageOptions{
			PreloadScript: a.preloadScript,
		},
	})
	win.OnReadyToShow(func() {
		win.Show()
		log.Printf("app: main window ready")
	})
	// A hidden window that becomes ready-to-show before the listener above is
	// registered (fast embedded page, production build) would never show, and a
	// page that never loads would leave a black window: track both and report.
	loaded := make(chan struct{})
	var loadedOnce, shown sync.Once
	markLoaded := func() { loadedOnce.Do(func() { close(loaded) }) }
	show := func(why string) {
		shown.Do(func() {
			win.Show()
			log.Printf("app: main window shown (%s)", why)
		})
	}
	if page := win.Page(); page != nil {
		page.OnDOMReady(func() {
			log.Printf("app: main window DOM ready")
			show("dom ready")
		})
		page.OnDidFinishLoad(func() {
			log.Printf("app: main window finished loading (webview process %d)", page.ProcessID())
			markLoaded()
			show("did finish load")
		})
		page.OnDidFailLoad(func(e *mygo.LoadError) {
			log.Printf("app: main window load failed: %+v", e)
			show("load failed")
		})
	}
	time.AfterFunc(3*time.Second, func() {
		if !win.IsVisible() {
			log.Printf("app: main window still hidden after 3s; showing it")
			show("fallback timer")
		}
	})
	go func() {
		select {
		case <-loaded:
		case <-time.After(15 * time.Second):
			log.Printf("app: the page did not load within 15s; reporting it")
			mygo.Dialog.Error("Charker",
				"Charker \u7684\u754c\u9762\u6ca1\u80fd\u52a0\u8f7d\u3002\n\n"+
					"\u8bf7\u786e\u8ba4\u5df2\u5b89\u88c5 Microsoft Edge WebView2 \u8fd0\u884c\u65f6\uff0c\u7136\u540e\u91cd\u65b0\u542f\u52a8 Charker\u3002\n"+
					"\u8bca\u65ad\u65e5\u5fd7\uff1a"+diagnosticLogPath())
		}
	}()
	win.OnClose(func(e *mygo.CloseEvent) {
		if a.IsQuitting() || !a.hasTray() {
			// A deliberate quit, or no tray icon to bring the window back.
			return
		}
		e.PreventDefault()
		win.Hide()
		log.Printf("app: main window hidden to tray")
	})
	win.OnClosed(func() {
		log.Printf("app: main window closed")
		a.uiMu.Lock()
		if a.win == win {
			a.win = nil
		}
		a.uiMu.Unlock()
	})
	if len(a.iconPNG) > 0 {
		if err := win.SetIcon(a.iconPNG); err != nil {
			log.Printf("app: window icon: %v", err)
		}
	}
	fitWindowToWorkArea(win)
	a.uiMu.Lock()
	a.win = win
	a.uiMu.Unlock()
	a.updateTrayToolTip(a.currentState())
}

// fitWindowToWorkArea keeps the main window inside the primary display's work
// area. A window that already fits - including one restored from
// window-state.json - is left alone.
func fitWindowToWorkArea(win *mygo.Window) {
	ds := mygo.Screen.Displays()
	if len(ds) == 0 {
		return
	}
	wa := ds[0].WorkArea
	const margin = 16
	maxW, maxH := wa.Width-margin, wa.Height-margin
	if maxW < 400 || maxH < 300 {
		return // no meaningful room; leave the window as it is
	}
	b := win.Bounds()
	if b.X >= wa.X && b.Y >= wa.Y && b.X+b.Width <= wa.X+wa.Width && b.Y+b.Height <= wa.Y+wa.Height {
		return
	}
	w, h := min(969, maxW), min(840, maxH)
	win.SetMinimumSize(min(890, maxW), min(600, maxH))
	win.SetContentSize(w, h)
	win.SetPosition(wa.X+(wa.Width-w)/2, wa.Y+(wa.Height-h)/2)
	log.Printf("app: fitted the window to the work area %dx%d (%dx%d)", wa.Width, wa.Height, w, h)
}

// Window returns the main window, nil before StartUI or after it closed.
func (a *App) Window() *mygo.Window {
	a.uiMu.Lock()
	defer a.uiMu.Unlock()
	return a.win
}

// Tray returns the tray icon, nil when it could not be created.
func (a *App) Tray() *mygo.Tray {
	a.uiMu.Lock()
	defer a.uiMu.Unlock()
	return a.tray
}

func (a *App) hasTray() bool {
	a.uiMu.Lock()
	defer a.uiMu.Unlock()
	return a.tray != nil
}

// showMainWindow restores and focuses the main window, recreating it if the
// user closed it while the tray was gone.
func (a *App) showMainWindow() {
	a.uiMu.Lock()
	win := a.win
	a.uiMu.Unlock()
	if win == nil {
		return
	}
	if !win.IsVisible() {
		win.Show()
	}
	win.Restore()
	win.Focus()
}

// hideMainWindow hides the main window, leaving the app running in the tray.
func (a *App) hideMainWindow() {
	a.uiMu.Lock()
	win := a.win
	a.uiMu.Unlock()
	if win != nil && win.IsVisible() {
		win.Hide()
	}
}

// toggleMainWindow is the tray left click: hide when visible, show and focus
// otherwise.
func (a *App) toggleMainWindow() {
	a.uiMu.Lock()
	win := a.win
	a.uiMu.Unlock()
	if win != nil && win.IsVisible() {
		win.Hide()
		return
	}
	a.showMainWindow()
}

// OnWindowAllClosed keeps Charker alive in the tray; without a tray icon
// there would be no way back, so it quits instead.
func (a *App) OnWindowAllClosed() {
	if a.hasTray() {
		return
	}
	a.quit()
}

// quit asks the app to exit: windows close (listeners see IsQuitting) and the
// process ends.
func (a *App) quit() {
	a.SetQuitting()
	mygo.App.Quit()
}

// updateTrayToolTip refreshes the tray hover text with the live readout.
func (a *App) updateTrayToolTip(st AppState) {
	text := a.trayToolTip(st)
	a.uiMu.Lock()
	tray := a.tray
	a.uiMu.Unlock()
	if tray == nil {
		return
	}
	a.mu.Lock()
	same := a.lastTooltip == text
	if !same {
		a.lastTooltip = text
	}
	a.mu.Unlock()
	if same {
		return
	}
	tray.SetToolTip(text)
}

// updateTray refreshes tray text after a locale change.
func (a *App) updateTray() {
	st := a.currentState()
	a.updateTrayToolTip(st)
}

// currentState builds the current AppState without marking the page as served.
func (a *App) currentState() AppState {
	now := time.Now().UnixMilli()
	a.mu.Lock()
	st := a.buildStateLocked(now)
	a.mu.Unlock()
	return st
}

// diagnosticLogPath is where release builds write charker.log; the error
// dialog points the user at it.
func diagnosticLogPath() string {
	if dir, err := os.UserCacheDir(); err == nil {
		return filepath.Join(dir, "Charker", "charker.log")
	}
	return filepath.Join(os.TempDir(), "Charker", "charker.log")
}
