package store

import (
	"context"
	"database/sql"
	"errors"
	"time"
)

// AIModel is a user's own model endpoint. KeySealed is the API key as
// sealed by the service; the store never sees it in the clear.
type AIModel struct {
	BaseURL   string
	Model     string
	KeySealed []byte
	KeyHint   string
	Updated   time.Time
}

// GetAIModel returns the user's own model, ErrNotFound when they have none.
func (s *Store) GetAIModel(ctx context.Context, userID string) (AIModel, error) {
	var m AIModel
	var ms int64
	err := s.db.QueryRowContext(ctx, `SELECT base_url, model, key_sealed, key_hint, updated_ms FROM ai_models WHERE user_id = ?`, userID).
		Scan(&m.BaseURL, &m.Model, &m.KeySealed, &m.KeyHint, &ms)
	if errors.Is(err, sql.ErrNoRows) {
		return AIModel{}, ErrNotFound
	}
	if err != nil {
		return AIModel{}, err
	}
	m.Updated = time.UnixMilli(ms)
	return m, nil
}

// SetAIModel saves (or replaces) the user's own model.
func (s *Store) SetAIModel(ctx context.Context, userID string, m AIModel) error {
	_, err := s.db.ExecContext(ctx, `INSERT INTO ai_models (user_id, base_url, model, key_sealed, key_hint, updated_ms)
		VALUES (?, ?, ?, ?, ?, ?)
		ON CONFLICT(user_id) DO UPDATE SET base_url = excluded.base_url, model = excluded.model,
			key_sealed = excluded.key_sealed, key_hint = excluded.key_hint, updated_ms = excluded.updated_ms`,
		userID, m.BaseURL, m.Model, m.KeySealed, m.KeyHint, time.Now().UnixMilli())
	return err
}

// ClearAIModel removes the user's own model; no error when there was none.
func (s *Store) ClearAIModel(ctx context.Context, userID string) error {
	_, err := s.db.ExecContext(ctx, `DELETE FROM ai_models WHERE user_id = ?`, userID)
	return err
}
