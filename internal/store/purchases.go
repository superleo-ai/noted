package store

import (
	"context"
	"database/sql"
	"errors"
	"time"
)

// ErrPurchaseTaken: the App Store purchase is already bound to another user.
var ErrPurchaseTaken = errors.New("purchase belongs to another account")

// BindPurchase records that an App Store purchase belongs to userID and turns
// Pro on for them. Binding the same purchase to the same user again is fine
// (restore, a new device); binding it to someone else is ErrPurchaseTaken, so
// one purchase cannot unlock any number of accounts.
func (s *Store) BindPurchase(ctx context.Context, originalTxID, userID, productID, environment string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	if _, err := tx.ExecContext(ctx, `INSERT INTO purchases (original_transaction_id, user_id, product_id, environment, created_ms)
		VALUES (?, ?, ?, ?, ?) ON CONFLICT(original_transaction_id) DO NOTHING`,
		originalTxID, userID, productID, environment, time.Now().UnixMilli()); err != nil {
		return err
	}
	var owner string
	if err := tx.QueryRowContext(ctx, `SELECT user_id FROM purchases WHERE original_transaction_id = ?`, originalTxID).Scan(&owner); err != nil {
		return err
	}
	if owner != userID {
		return ErrPurchaseTaken
	}
	res, err := tx.ExecContext(ctx, `UPDATE users SET pro = 1 WHERE id = ?`, userID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	return tx.Commit()
}

func usageDay(now time.Time) string { return now.UTC().Format("2006-01-02") }

// SpendAI counts one language-model call for the user today (UTC) and
// reports false, counting nothing, when limit calls were already made.
// limit <= 0 means no limit.
func (s *Store) SpendAI(ctx context.Context, userID string, now time.Time, limit int) (bool, error) {
	if limit <= 0 {
		return true, nil
	}
	day := usageDay(now)
	// Earlier days no longer matter.
	if _, err := s.db.ExecContext(ctx, `DELETE FROM ai_usage WHERE user_id = ? AND day < ?`, userID, day); err != nil {
		return false, err
	}
	var n int
	err := s.db.QueryRowContext(ctx, `INSERT INTO ai_usage (user_id, day, n) VALUES (?, ?, 1)
		ON CONFLICT(user_id, day) DO UPDATE SET n = n + 1 WHERE n < ?
		RETURNING n`, userID, day, limit).Scan(&n)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return true, nil
}

// RefundAI gives back a call SpendAI counted when the model never answered.
func (s *Store) RefundAI(ctx context.Context, userID string, now time.Time) error {
	_, err := s.db.ExecContext(ctx, `UPDATE ai_usage SET n = n - 1 WHERE user_id = ? AND day = ? AND n > 0`, userID, usageDay(now))
	return err
}
