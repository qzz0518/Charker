package app

import (
	"bytes"
	"image"
	"image/color"
	"image/png"
	"testing"
)

func TestResizePNG(t *testing.T) {
	src := image.NewRGBA(image.Rect(0, 0, 8, 8))
	for y := 0; y < 8; y++ {
		for x := 0; x < 8; x++ {
			src.Set(x, y, color.RGBA{R: 10, G: 120, B: 200, A: 255})
		}
	}
	var buf bytes.Buffer
	if err := png.Encode(&buf, src); err != nil {
		t.Fatal(err)
	}
	out := TrayIconPNG(buf.Bytes())
	img, err := png.Decode(bytes.NewReader(out))
	if err != nil {
		t.Fatalf("resized bytes are not a PNG: %v", err)
	}
	if b := img.Bounds(); b.Dx() != 32 || b.Dy() != 32 {
		t.Fatalf("tray icon is %dx%d, want 32x32", b.Dx(), b.Dy())
	}
	r, g, b, a := img.At(16, 16).RGBA()
	if r>>8 != 10 || g>>8 != 120 || b>>8 != 200 || a>>8 != 255 {
		t.Fatalf("pixel = %d,%d,%d,%d, want 10,120,200,255", r>>8, g>>8, b>>8, a>>8)
	}
}

func TestResizePNGKeepsExactSize(t *testing.T) {
	// An icon that already is 32x32 must be returned byte for byte.
	src := image.NewRGBA(image.Rect(0, 0, 32, 32))
	var buf bytes.Buffer
	if err := png.Encode(&buf, src); err != nil {
		t.Fatal(err)
	}
	in := buf.Bytes()
	if out := ResizePNG(in, 32); !bytes.Equal(out, in) {
		t.Fatal("exact-size icon should not be re-encoded")
	}
}

func TestResizePNGBadData(t *testing.T) {
	in := []byte("not a png")
	if out := ResizePNG(in, 32); !bytes.Equal(out, in) {
		t.Fatal("undecodable data should be returned unchanged")
	}
}
