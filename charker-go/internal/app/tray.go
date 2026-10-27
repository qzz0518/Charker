package app

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"math"
	"sync"

	"github.com/egoist/mygo"
)

// The notification-area icon: StatusItemController on macOS. Windows shows
// no text there, so the menu bar title splits in two: the icon itself shows
// the live total in digits (trayicon.go) and its tooltip the configured
// layout (menubar.go). A left click opens the popover's twin, a flyout
// above the icon showing web/tray.html (MenuBarReadout); a right click a
// small menu.

// trayPanelWidth is the popover's width (MenuBarReadout: 340 pt).
const trayPanelWidth = 340

// trayUI is the tray's own state, apart from the icon in App.tray.
type trayUI struct {
	mu sync.Mutex
	// panel is the flyout while it shows.
	panel *mygo.Window
	// iconKey is what the icon shows now ("" = the app icon), so it is set
	// again only when the digits, their fade or the pixel size change.
	iconKey string
}

// createTray puts Charker in the notification area.
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
	tray.OnClick(a.toggleTrayPanel)
	tray.OnRightClick(a.showTrayMenu)
	mygo.App.OnWillQuit(func(*mygo.QuitEvent) { tray.Destroy() })
	log.Printf("app: tray icon created")
}

// toggleTrayPanel opens the readout flyout above the icon, or closes it. A
// press on the icon does not dismiss a focusable flyout, so the icon's own
// click closes it, as a second click on the Mac status item does.
func (a *App) toggleTrayPanel() {
	a.uiMu.Lock()
	tray := a.tray
	a.uiMu.Unlock()
	a.trayUI.mu.Lock()
	panel := a.trayUI.panel
	a.trayUI.mu.Unlock()
	if panel != nil {
		panel.Close()
		return
	}
	if tray == nil {
		return
	}
	// Built per open and gone on close, as the popover's content is: a
	// closed readout must not keep rendering every telemetry update.
	panel = mygo.NewFlyout(mygo.FlyoutOptions{
		Tray:       tray,
		Placement:  mygo.PlacementBottom, // above an icon of a bottom taskbar
		Gap:        8,
		Width:      trayPanelWidth,
		Height:     300,
		FitContent: true,
		MinWidth:   trayPanelWidth,
		MaxWidth:   trayPanelWidth,
		MaxHeight:  640,
		Focusable:  true,
		Shadow:     true,
		Hidden:     true,
		URL:        "/tray.html",
		Page:       mygo.PageOptions{PreloadScript: a.preloadScript},
	})
	panel.OnReadyToShow(panel.Show)
	panel.OnClosed(func() {
		a.trayUI.mu.Lock()
		if a.trayUI.panel == panel {
			a.trayUI.panel = nil
		}
		a.trayUI.mu.Unlock()
	})
	a.trayUI.mu.Lock()
	a.trayUI.panel = panel
	a.trayUI.mu.Unlock()
}

// closeTrayPanel closes the flyout if it shows.
func (a *App) closeTrayPanel() {
	a.trayUI.mu.Lock()
	panel := a.trayUI.panel
	a.trayUI.mu.Unlock()
	if panel != nil {
		panel.Close()
	}
}

// showTrayMenu opens the context menu with the strings of the current
// locale. The menu is set only for this popup so left clicks keep reaching
// OnClick (a tray menu would otherwise open on the next left click).
func (a *App) showTrayMenu() {
	a.closeTrayPanel()
	a.uiMu.Lock()
	tray := a.tray
	a.uiMu.Unlock()
	if tray == nil {
		return
	}
	demo := a.Prefs().DemoMode
	menu := mygo.NewMenu([]*mygo.MenuItem{
		{Label: a.tr(textTrayShow), Click: func(*mygo.MenuItem, *mygo.Window) { a.showMainWindow() }},
		{
			Label:   a.tr(textTrayDemo),
			Type:    mygo.MenuItemCheckbox,
			Checked: demo,
			Click: func(*mygo.MenuItem, *mygo.Window) {
				// The engine swap blocks; keep it off the UI thread.
				go func() {
					patch, _ := json.Marshal(map[string]bool{"demoMode": !demo})
					if err := a.SetPrefs(patch); err != nil {
						log.Printf("app: demo mode: %v", err)
					}
				}()
			},
		},
		mygo.Separator(),
		{Label: a.tr(textTrayQuit), Click: func(*mygo.MenuItem, *mygo.Window) { a.quit() }},
	})
	tray.SetMenu(menu)
	defer tray.SetMenu(nil)
	tray.PopUpMenu()
}

// trayIconSize is the notification area's icon in pixels: 16 DIPs at the
// primary display's scale.
func trayIconSize() int {
	scale := 1.0
	if d := mygo.Screen.PrimaryDisplay(); d.ScaleFactor > 0 {
		scale = d.ScaleFactor
	}
	return int(math.Round(16 * scale))
}

// updateTrayIcon shows the live digits, or the app icon when nothing is
// live. The digits are a template image: MyGo draws them white on a dark
// taskbar and keeps them near-black on a light one, and redraws them when
// the taskbar's mode changes.
func (a *App) updateTrayIcon(tray *mygo.Tray, st AppState) {
	text, stale, live := trayDigits(st)
	key, size := "", 0
	if live && loadTrayFont() != nil {
		size = trayIconSize()
		key = fmt.Sprintf("%s/%v/%d", text, stale, size)
	}
	a.trayUI.mu.Lock()
	same := a.trayUI.iconKey == key
	a.trayUI.iconKey = key
	a.trayUI.mu.Unlock()
	if same {
		return
	}
	png, template := a.trayIconPNG, false
	if key != "" {
		if data, err := trayIcons.get(text, size, trayInk{dim: stale}); err != nil {
			log.Printf("app: tray digits: %v", err)
		} else {
			png, template = data, true
		}
	}
	if err := tray.SetIcon(png, template); err != nil {
		log.Printf("app: tray icon: %v", err)
	}
}

// TrayPreview is what the taskbar page draws for the icon.
type TrayPreview struct {
	// Icon is the live digits as a PNG data URL, "" for the app icon.
	Icon string `json:"icon"`
	// Dark is the taskbar's mode.
	Dark bool `json:"dark"`
	// ToolTip is the icon's hover text.
	ToolTip string `json:"toolTip"`
}

// trayPreview renders the icon as the taskbar shows it now, at 32 px.
func (a *App) trayPreview() TrayPreview {
	st := a.currentState()
	dark := true
	a.uiMu.Lock()
	tray := a.tray
	a.uiMu.Unlock()
	if tray != nil {
		dark = tray.Dark()
	}
	p := TrayPreview{Dark: dark, ToolTip: a.trayToolTip(st)}
	if text, stale, live := trayDigits(st); live && loadTrayFont() != nil {
		if data, err := trayIcons.get(text, 32, trayInk{light: dark, dim: stale}); err == nil {
			p.Icon = "data:image/png;base64," + base64.StdEncoding.EncodeToString(data)
		}
	}
	return p
}
