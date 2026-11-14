package store

import (
	"context"
	"encoding/json"
	"errors"
)

// AIConsentKey is the preference the apps write when the person agrees to (or
// withdraws) sending item text to the model provider (App Store 5.1.2(i)):
// {"granted": true, "version": 1, "at": "..."}. Calls the person starts are
// gated by the app; background work on the server (the semantic index) is
// gated here.
const AIConsentKey = "ai.consent"

// AIConsented reports whether the user has agreed. No record, or a damaged
// one, means no.
func (s *Store) AIConsented(ctx context.Context, userID string) (bool, error) {
	p, err := s.GetPreference(ctx, userID, AIConsentKey)
	if errors.Is(err, ErrNotFound) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	var c struct {
		Granted bool `json:"granted"`
	}
	if json.Unmarshal([]byte(p.Value), &c) != nil {
		return false, nil
	}
	return c.Granted, nil
}

// consentChanged re-queues the user's notes for the indexer when consent was
// given or withdrawn, so they are embedded, or removed from the index.
func (s *Store) consentChanged(ctx context.Context, userID string, before bool) error {
	after, err := s.AIConsented(ctx, userID)
	if err != nil || after == before {
		return err
	}
	_, err = s.db.ExecContext(ctx, `UPDATE notes SET ai_indexed_ms = NULL WHERE user_id = ?`, userID)
	return err
}
