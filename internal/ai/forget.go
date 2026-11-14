package ai

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"strings"

	_ "modernc.org/sqlite"
)

// sessionColumns are the agentgo.db columns that hold an assistant session
// id. Ask keys every session "<user id>:<session id>", so a user's
// conversations, plans, task runs and checkpoints are the rows whose session
// id starts with their id and a colon.
var sessionColumns = []struct{ table, col string }{
	{"chat_messages", "session_id"},
	{"agent_plans", "session_id"},
	{"task_checkpoints", "session_id"},
	{"tasks", "session_id"},
	{"tasks", "runtime_session_id"},
	{"chat_sessions", "id"},
	{"agent_sessions", "id"},
}

// ForgetUser deletes the assistant's conversations with a user whose account
// is being deleted. A table agentgo.db does not have is skipped.
func (a *Agent) ForgetUser(ctx context.Context, userID string) error {
	if a.sessionsDB == "" || userID == "" {
		return nil
	}
	if _, err := os.Stat(a.sessionsDB); errors.Is(err, os.ErrNotExist) {
		return nil
	}
	db, err := sql.Open("sqlite", "file:"+a.sessionsDB+"?_pragma=busy_timeout(5000)")
	if err != nil {
		return err
	}
	defer func() { _ = db.Close() }()
	prefix := userID + ":"
	var errs []error
	for _, c := range sessionColumns {
		q := fmt.Sprintf(`DELETE FROM %s WHERE substr(%s, 1, ?) = ?`, c.table, c.col)
		if _, err := db.ExecContext(ctx, q, len(prefix), prefix); err != nil {
			if strings.Contains(err.Error(), "no such table") || strings.Contains(err.Error(), "no such column") {
				continue
			}
			errs = append(errs, fmt.Errorf("%s.%s: %w", c.table, c.col, err))
		}
	}
	return errors.Join(errs...)
}
