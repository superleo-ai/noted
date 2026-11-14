package store

import (
	"context"
	"database/sql"
	"fmt"
)

// DeletedAccount is what DeleteUser removed that lives on outside this
// database too: the notes (for the semantic index) and the Apple ID that was
// linked ("" when none).
type DeletedAccount struct {
	NoteIDs  []string
	AppleSub string
}

// userTables lists every table with a user_id column, read from the schema
// so a table added later is covered without touching this file. Most also
// cascade from users, but task_work has no foreign key on users and
// notes_fts is a virtual table; deleting by user_id everywhere keeps the
// delete complete whether or not foreign keys are enforced.
func userTables(ctx context.Context, tx *sql.Tx) ([]string, error) {
	rows, err := tx.QueryContext(ctx, `
		SELECT m.name FROM sqlite_master m
		WHERE m.type = 'table' AND m.name NOT LIKE 'sqlite_%'
		  AND EXISTS (SELECT 1 FROM pragma_table_info(m.name) WHERE name = 'user_id')
		ORDER BY m.name`)
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }()
	var out []string
	for rows.Next() {
		var n string
		if err := rows.Scan(&n); err != nil {
			return nil, err
		}
		out = append(out, n)
	}
	return out, rows.Err()
}

// childTables hang off a user's rows by the parent's id instead of a user_id.
var childTables = []struct{ table, col, parent string }{
	{"note_tags", "note_id", "notes"},
	{"task_tags", "task_id", "tasks"},
	{"task_work", "task_id", "tasks"},
	{"goal_milestones", "goal_id", "goals"},
	{"goal_checkins", "goal_id", "goals"},
	{"objective_milestones", "objective_id", "objectives"},
	{"objective_measurements", "objective_id", "objectives"},
	{"holding_trades", "holding_id", "holdings"},
}

// DeleteUser removes a user and every row they own, in one transaction. A
// token of theirs stops working the moment it commits. ErrNotFound when there
// is no such user.
func (s *Store) DeleteUser(ctx context.Context, userID string) (DeletedAccount, error) {
	var out DeletedAccount
	err := s.tx(ctx, func(tx *sql.Tx) error {
		var n int
		if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM users WHERE id = ?`, userID).Scan(&n); err != nil {
			return err
		}
		if n == 0 {
			return ErrNotFound
		}
		rows, err := tx.QueryContext(ctx, `SELECT id FROM notes WHERE user_id = ?`, userID)
		if err != nil {
			return err
		}
		for rows.Next() {
			var id string
			if err := rows.Scan(&id); err != nil {
				_ = rows.Close()
				return err
			}
			out.NoteIDs = append(out.NoteIDs, id)
		}
		_ = rows.Close()
		if err := rows.Err(); err != nil {
			return err
		}
		err = tx.QueryRowContext(ctx, `SELECT sub FROM apple_ids WHERE user_id = ?`, userID).Scan(&out.AppleSub)
		if err != nil && err != sql.ErrNoRows {
			return err
		}
		for _, c := range childTables {
			q := fmt.Sprintf(`DELETE FROM %s WHERE %s IN (SELECT id FROM %s WHERE user_id = ?)`, c.table, c.col, c.parent)
			if _, err := tx.ExecContext(ctx, q, userID); err != nil {
				return fmt.Errorf("delete %s: %w", c.table, err)
			}
		}
		tables, err := userTables(ctx, tx)
		if err != nil {
			return err
		}
		for _, t := range tables {
			if _, err := tx.ExecContext(ctx, `DELETE FROM "`+t+`" WHERE user_id = ?`, userID); err != nil {
				return fmt.Errorf("delete %s: %w", t, err)
			}
		}
		_, err = tx.ExecContext(ctx, `DELETE FROM users WHERE id = ?`, userID)
		return err
	})
	if err != nil {
		return DeletedAccount{}, err
	}
	return out, nil
}
