// Command winres writes the Windows resources linked into Charker.exe:
// the app icon with the rounded corners of Windows 11 app icons, and the
// version the macOS app ships. build.ps1 runs it before go build.
//
//	go run ./tools/winres -version 0.5.6
package main

import (
	"bytes"
	"flag"
	"image"
	"image/png"
	"log"
	"os"

	"charker/internal/app"

	"github.com/tc-hib/winres"
	"github.com/tc-hib/winres/version"
)

func main() {
	ver := flag.String("version", "", "the version (CFBundleShortVersionString)")
	out := flag.String("out", "rsrc_windows_amd64.syso", "the object file go build links")
	flag.Parse()
	if *ver == "" {
		log.Fatal("winres: -version is required")
	}
	data, err := os.ReadFile("web/assets/app-icon.png")
	if err != nil {
		log.Fatal(err)
	}

	var images []image.Image
	for _, size := range []int{16, 20, 24, 32, 40, 48, 64, 256} {
		img, err := png.Decode(bytes.NewReader(app.RoundPNG(app.ResizePNG(data, size))))
		if err != nil {
			log.Fatal(err)
		}
		images = append(images, img)
	}
	icon, err := winres.NewIconFromImages(images)
	if err != nil {
		log.Fatal(err)
	}
	rs := winres.ResourceSet{}
	if err := rs.SetIcon(winres.Name("APPICON"), icon); err != nil {
		log.Fatal(err)
	}

	vi := version.Info{}
	vi.SetFileVersion(*ver)
	vi.SetProductVersion(*ver)
	for key, value := range map[string]string{
		version.ProductName:      "Charker",
		version.FileDescription:  "Charker",
		version.OriginalFilename: "Charker.exe",
		version.LegalCopyright:   "© qzz0518",
	} {
		if err := vi.Set(version.LangDefault, key, value); err != nil {
			log.Fatal(err)
		}
	}
	rs.SetVersionInfo(vi)

	f, err := os.Create(*out)
	if err != nil {
		log.Fatal(err)
	}
	defer f.Close()
	if err := rs.WriteObject(f, winres.ArchAMD64); err != nil {
		log.Fatal(err)
	}
}
