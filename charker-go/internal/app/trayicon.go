package app

import (
	"bytes"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"math"
	"os"
	"path/filepath"
	"sync"

	"golang.org/x/image/draw"
	"golang.org/x/image/font"
	"golang.org/x/image/font/opentype"
	"golang.org/x/image/math/fixed"
)

// The live tray icon: Windows shows no text in the notification area, so
// the Mac's menu bar title becomes digits drawn on the icon itself, as
// battery and sensor tray icons do. The digits are the total output in
// whole watts, without a unit; anything not live shows the app icon.

// trayDigits is what the icon shows: the whole-watt total while live
// telemetry arrives, ok=false for the app icon.
func trayDigits(st AppState) (text string, stale, ok bool) {
	s := st.Session
	if st.Prefs.ShowIconOnly || s.Phase != PhasePolling || s.Telemetry == nil {
		return "", false, false
	}
	var total float64
	for _, p := range s.Telemetry.Ports {
		if p.StatusCode != 0 {
			total += p.Power
		}
	}
	total = math.Min(math.Max(total, 0), 999)
	return fmt.Sprintf("%.0f", total), s.IsStale, true
}

// trayFontPaths are tried in order: Segoe UI Bold, then Semibold, from the
// Windows font folder; the macOS and Linux entries only serve the browser
// dev server's preview.
func trayFontPaths() []string {
	windir := os.Getenv("WINDIR")
	if windir == "" {
		windir = `C:\Windows`
	}
	fonts := filepath.Join(windir, "Fonts")
	return []string{
		filepath.Join(fonts, "segoeuib.ttf"),
		filepath.Join(fonts, "seguisb.ttf"),
		"/System/Library/Fonts/Supplemental/Arial Bold.ttf",
		"/Library/Fonts/Arial Bold.ttf",
		"/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
	}
}

var (
	trayFontOnce sync.Once
	trayFont     *opentype.Font
)

// loadTrayFont parses the first font that loads, once; nil when none does
// (the icon then stays the app icon).
func loadTrayFont() *opentype.Font {
	trayFontOnce.Do(func() {
		for _, path := range trayFontPaths() {
			data, err := os.ReadFile(path)
			if err != nil {
				continue
			}
			if f, err := opentype.Parse(data); err == nil {
				trayFont = f
				return
			}
		}
	})
	return trayFont
}

// trayInk is the colour of the digits.
type trayInk struct {
	// light draws white digits (a dark taskbar), else near-black.
	light bool
	// dim is stale data: the digits fade.
	dim bool
}

func (k trayInk) color() color.NRGBA {
	c := color.NRGBA{R: 0x1a, G: 0x1a, B: 0x1a, A: 0xff}
	if k.light {
		c = color.NRGBA{R: 0xff, G: 0xff, B: 0xff, A: 0xff}
	}
	if k.dim {
		c.A = 0x73 // 45 %
	}
	return c
}

// renderTrayDigits draws text as bold digits filling a size×size square
// and returns it as a PNG. Two digits fill the height; three are
// condensed, and shortened when condensing alone would make them too
// narrow to read.
func renderTrayDigits(f *opentype.Font, text string, size int, ink trayInk) ([]byte, error) {
	if f == nil || text == "" || size <= 0 {
		return nil, fmt.Errorf("tray icon: nothing to draw")
	}
	const oversample = 8
	face, err := opentype.NewFace(f, &opentype.FaceOptions{
		Size:    float64(size * oversample),
		DPI:     72,
		Hinting: font.HintingNone,
	})
	if err != nil {
		return nil, err
	}
	defer face.Close()

	// The ink box of the digits at the oversampled size.
	bounds, _ := font.BoundString(face, text)
	minX, minY := bounds.Min.X.Floor(), bounds.Min.Y.Floor()
	w, h := bounds.Max.X.Ceil()-minX, bounds.Max.Y.Ceil()-minY
	if w <= 0 || h <= 0 {
		return nil, fmt.Errorf("tray icon: %q has no ink", text)
	}
	mask := image.NewAlpha(image.Rect(0, 0, w, h))
	d := font.Drawer{
		Dst:  mask,
		Src:  image.Opaque,
		Face: face,
		Dot:  fixed.P(-minX, -minY),
	}
	d.DrawString(text)

	// Fit the ink into the square, keeping a hairline margin.
	margin := 0.0
	if size >= 24 {
		margin = float64(size) / 32
	}
	box := float64(size) - 2*margin
	scaleY := box / float64(h)
	scaleX := scaleY
	if float64(w)*scaleX > box {
		scaleX = box / float64(w)
	}
	// Condensed below 62 % of the natural width, digits blur together at
	// 16 px: give up height instead.
	const minCondense = 0.62
	if scaleX/scaleY < minCondense {
		scaleY = scaleX / minCondense
	}
	tw, th := float64(w)*scaleX, float64(h)*scaleY
	x0 := (float64(size) - tw) / 2
	y0 := (float64(size) - th) / 2
	target := image.Rect(int(math.Round(x0)), int(math.Round(y0)),
		int(math.Round(x0+tw)), int(math.Round(y0+th)))

	src := image.NewNRGBA(mask.Bounds())
	c := ink.color()
	for i, a := range mask.Pix {
		src.Pix[i*4+0], src.Pix[i*4+1], src.Pix[i*4+2] = c.R, c.G, c.B
		src.Pix[i*4+3] = uint8(uint16(a) * uint16(c.A) / 0xff)
	}
	dst := image.NewNRGBA(image.Rect(0, 0, size, size))
	draw.CatmullRom.Scale(dst, target, src, src.Bounds(), draw.Over, nil)

	var out bytes.Buffer
	if err := png.Encode(&out, dst); err != nil {
		return nil, err
	}
	return out.Bytes(), nil
}

// trayIconCache keeps the last few renders: the digits change at most
// once per telemetry sample and repeat often.
type trayIconCache struct {
	mu    sync.Mutex
	items map[string][]byte
	order []string
}

func (c *trayIconCache) get(text string, size int, ink trayInk) ([]byte, error) {
	key := fmt.Sprintf("%s/%d/%v/%v", text, size, ink.light, ink.dim)
	c.mu.Lock()
	if data, ok := c.items[key]; ok {
		c.mu.Unlock()
		return data, nil
	}
	c.mu.Unlock()
	data, err := renderTrayDigits(loadTrayFont(), text, size, ink)
	if err != nil {
		return nil, err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.items == nil {
		c.items = map[string][]byte{}
	}
	if len(c.order) >= 32 {
		delete(c.items, c.order[0])
		c.order = c.order[1:]
	}
	c.items[key] = data
	c.order = append(c.order, key)
	return data, nil
}

var trayIcons trayIconCache
