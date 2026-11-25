package ai

import (
	"context"
	"strings"
	"unicode/utf8"

	"github.com/liliang-cn/noted/internal/cortexsync"
)

const maxEntityText = cortexsync.MaxExtractText

// EntitiesJSON asks the model for the entities and relations of a note and
// returns its raw answer; the caller parses and validates it.
func (a *Agent) EntitiesJSON(ctx context.Context, title, content string) (string, error) {
	text := strings.TrimSpace(content)
	if utf8.RuneCountInString(text) > maxEntityText {
		text = string([]rune(text)[:maxEntityText])
	}
	return a.generate(ctx, cortexsync.ExtractionPrompt, "Title: "+strings.TrimSpace(title)+"\n\n"+text, tokensLong)
}
