package anker

import (
	"errors"
	"fmt"
	"strings"
)

// Text is one user-facing message in the macOS app's L10n form. Key is the
// Chinese source string exactly as the Swift code passes it to L10n.text /
// L10n.format (the generated web/l10n/en.json is keyed on it); Args fill its
// %@ and %d placeholders in order. An Arg may itself be a Text, which is
// rendered (and translated) first.
type Text struct {
	Key  string `json:"key"`
	Args []any  `json:"args,omitempty"`
}

// T builds a Text.
func T(key string, args ...any) Text { return Text{Key: key, Args: args} }

// IsZero reports whether t carries no message.
func (t Text) IsZero() bool { return t.Key == "" }

// String renders the Chinese source text with its arguments, the way
// L10n.format does with the source table.
func (t Text) String() string {
	if len(t.Args) == 0 {
		return t.Key
	}
	args := make([]any, len(t.Args))
	for i, a := range t.Args {
		if nested, ok := a.(Text); ok {
			args[i] = nested.String()
		} else {
			args[i] = a
		}
	}
	return fmt.Sprintf(strings.ReplaceAll(t.Key, "%@", "%v"), args...)
}

// Localized is implemented by every error of this package (and of
// cloudsession) that has a Mac-identical message.
type Localized interface {
	Text() Text
}

// TextOf returns the localized message of err, or err.Error() as an
// untranslated key — the Swift fallback is `error.localizedDescription`.
func TextOf(err error) Text {
	if err == nil {
		return Text{}
	}
	var l Localized
	if errors.As(err, &l) {
		return l.Text()
	}
	return Text{Key: err.Error()}
}
