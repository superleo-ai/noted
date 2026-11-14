package ai

import (
	"context"
	"database/sql"
	"path/filepath"
	"testing"
)

func TestForgetUser(t *testing.T) {
	path := filepath.Join(t.TempDir(), "agentgo.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	// A subset of agentgo.db: a missing table must not stop the rest.
	for _, q := range []string{
		`CREATE TABLE chat_sessions (id TEXT PRIMARY KEY)`,
		`CREATE TABLE chat_messages (id TEXT PRIMARY KEY, session_id TEXT NOT NULL)`,
		`CREATE TABLE tasks (id TEXT PRIMARY KEY, session_id TEXT, runtime_session_id TEXT)`,
		`INSERT INTO chat_sessions VALUES ('u1:a'), ('u1:b'), ('u10:a'), ('u2:a')`,
		`INSERT INTO chat_messages VALUES ('m1', 'u1:a'), ('m2', 'u10:a'), ('m3', 'u2:a')`,
		`INSERT INTO tasks VALUES ('t1', 'u1:a', NULL), ('t2', NULL, 'u1:b'), ('t3', 'u2:a', 'u2:a')`,
	} {
		if _, err := db.Exec(q); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}
	a := &Agent{sessionsDB: path}
	if err := a.ForgetUser(context.Background(), "u1"); err != nil {
		t.Fatal(err)
	}
	for table, want := range map[string]int{"chat_sessions": 2, "chat_messages": 2, "tasks": 1} {
		var n int
		if err := db.QueryRow(`SELECT COUNT(*) FROM ` + table).Scan(&n); err != nil {
			t.Fatal(err)
		}
		if n != want {
			t.Errorf("%s: %d rows left, want %d", table, n, want)
		}
	}
	var n int
	db.QueryRow(`SELECT COUNT(*) FROM chat_sessions WHERE id LIKE 'u1:%'`).Scan(&n)
	if n != 0 {
		t.Errorf("u1 sessions left: %d", n)
	}
	// No database yet: nothing to do.
	if err := (&Agent{sessionsDB: filepath.Join(t.TempDir(), "none.db")}).ForgetUser(context.Background(), "u1"); err != nil {
		t.Fatal(err)
	}
}
