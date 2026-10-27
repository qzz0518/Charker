// Command l10n turns the macOS app's English .strings tables into the JSON the
// Windows pages read, so both apps share one set of translations. Run it from
// charker-go after the macOS strings change:
//
//	go run ./tools/l10n
package main

import (
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

var entry = regexp.MustCompile(`(?m)^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";`)

func unescape(s string) string {
	r := strings.NewReplacer(`\"`, `"`, `\n`, "\n", `\t`, "\t", `\\`, `\`)
	return r.Replace(s)
}

func main() {
	src := filepath.Join("..", "Resources", "Localizations", "en.lproj")
	out := map[string]string{}
	for _, table := range []string{"Core.strings", "Localizable.strings"} {
		data, err := os.ReadFile(filepath.Join(src, table))
		if err != nil {
			log.Fatal(err)
		}
		for _, m := range entry.FindAllStringSubmatch(string(data), -1) {
			out[unescape(m[1])] = unescape(m[2])
		}
	}
	data, err := json.MarshalIndent(out, "", " ")
	if err != nil {
		log.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join("web", "l10n", "en.json"), append(data, '\n'), 0o644); err != nil {
		log.Fatal(err)
	}
	log.Printf("wrote %d strings", len(out))
}
