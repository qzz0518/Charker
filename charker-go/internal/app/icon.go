package app

import (
	"bytes"
	"image"
	"image/draw"
	"image/png"
)

// TrayIconPNG scales the embedded app icon down to the 32×32 pixels a Windows
// notification-area icon wants. A decode failure returns the original bytes:
// a big icon is better than no icon.
func TrayIconPNG(data []byte) []byte {
	return RoundPNG(ResizePNG(data, 32))
}

// iconCornerRadius is the share of the side the corners are rounded by,
// the rounded square of Windows 11 app icons. The artwork is full bleed.
const iconCornerRadius = 0.22

// RoundPNG rounds the corners of a square icon, antialiased. It returns
// data unchanged when it cannot decode it.
func RoundPNG(data []byte) []byte {
	src, err := png.Decode(bytes.NewReader(data))
	if err != nil {
		return data
	}
	b := src.Bounds()
	dst := image.NewNRGBA(image.Rect(0, 0, b.Dx(), b.Dy()))
	draw.Draw(dst, dst.Bounds(), src, b.Min, draw.Src)
	w, h := float64(b.Dx()), float64(b.Dy())
	r := iconCornerRadius * min(w, h)
	// Coverage of each corner pixel by the rounded square, 4×4 samples.
	const n = 4
	for y := 0; y < b.Dy(); y++ {
		for x := 0; x < b.Dx(); x++ {
			cx, cy := float64(x)+0.5, float64(y)+0.5
			if (cx > r && cx < w-r) || (cy > r && cy < h-r) {
				continue
			}
			inside := 0
			for sy := 0; sy < n; sy++ {
				for sx := 0; sx < n; sx++ {
					px := float64(x) + (float64(sx)+0.5)/n
					py := float64(y) + (float64(sy)+0.5)/n
					ox := max(r-px, px-(w-r), 0)
					oy := max(r-py, py-(h-r), 0)
					if ox*ox+oy*oy <= r*r {
						inside++
					}
				}
			}
			i := dst.PixOffset(x, y)
			dst.Pix[i+3] = uint8(int(dst.Pix[i+3]) * inside / (n * n))
		}
	}
	var out bytes.Buffer
	if err := png.Encode(&out, dst); err != nil {
		return data
	}
	return out.Bytes()
}

// ResizePNG scales a PNG to size×size with a box filter (average of the source
// pixels each destination pixel covers), which is what a photo-like app icon
// needs when shrunk. It returns data unchanged when it cannot decode it.
func ResizePNG(data []byte, size int) []byte {
	if size <= 0 || len(data) == 0 {
		return data
	}
	src, err := png.Decode(bytes.NewReader(data))
	if err != nil {
		return data
	}
	b := src.Bounds()
	if b.Dx() == size && b.Dy() == size {
		return data
	}
	dst := image.NewRGBA(image.Rect(0, 0, size, size))
	for y := 0; y < size; y++ {
		y0 := b.Min.Y + y*b.Dy()/size
		y1 := b.Min.Y + (y+1)*b.Dy()/size
		if y1 <= y0 {
			y1 = y0 + 1
		}
		for x := 0; x < size; x++ {
			x0 := b.Min.X + x*b.Dx()/size
			x1 := b.Min.X + (x+1)*b.Dx()/size
			if x1 <= x0 {
				x1 = x0 + 1
			}
			var r, g, bl, al uint64
			var n uint64
			for sy := y0; sy < y1; sy++ {
				for sx := x0; sx < x1; sx++ {
					cr, cg, cb, ca := src.At(sx, sy).RGBA() // 16-bit, premultiplied
					r += uint64(cr)
					g += uint64(cg)
					bl += uint64(cb)
					al += uint64(ca)
					n++
				}
			}
			if n == 0 {
				continue
			}
			i := dst.PixOffset(x, y)
			dst.Pix[i+0] = uint8(r / n >> 8)
			dst.Pix[i+1] = uint8(g / n >> 8)
			dst.Pix[i+2] = uint8(bl / n >> 8)
			dst.Pix[i+3] = uint8(al / n >> 8)
		}
	}
	var out bytes.Buffer
	if err := png.Encode(&out, dst); err != nil {
		return data
	}
	return out.Bytes()
}
