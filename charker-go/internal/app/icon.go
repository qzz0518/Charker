package app

import (
	"bytes"
	"image"
	"image/png"
)

// TrayIconPNG scales the embedded app icon down to the 32×32 pixels a Windows
// notification-area icon wants (spec-mygo §4.1: NewTray takes a PNG, ideally
// 16×16 points / 32×32 pixels). A decode failure returns the original bytes:
// a big icon is better than no icon.
func TrayIconPNG(data []byte) []byte {
	return ResizePNG(data, 32)
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
