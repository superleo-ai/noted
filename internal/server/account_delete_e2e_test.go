package server_test

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/liliang-cn/cortexdb/v2/pkg/cortexdb"
	pb "github.com/liliang-cn/noted/gen/noted/v1"
	"github.com/liliang-cn/noted/internal/ai"
	"github.com/liliang-cn/noted/internal/auth"
	"github.com/liliang-cn/noted/internal/cortexsync"
	"github.com/liliang-cn/noted/internal/reminder"
	"github.com/liliang-cn/noted/internal/server"
	"github.com/liliang-cn/noted/internal/store"
	"google.golang.org/grpc/codes"
	"google.golang.org/protobuf/types/known/timestamppb"
	_ "modernc.org/sqlite"
)

// indexSpy is an AI engine that only records which notes left the index.
type indexSpy struct {
	ai.Engine
	mu      sync.Mutex
	removed map[string]string // note id -> user id
	forgot  []string          // users whose conversations were dropped
}

func (s *indexSpy) ForgetUser(_ context.Context, userID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.forgot = append(s.forgot, userID)
	return nil
}

func (s *indexSpy) Status() ai.Status { return ai.Status{} }

func (s *indexSpy) RemoveNote(_ context.Context, userID, noteID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.removed[noteID] = userID
	return nil
}

// brainSpy is a CortexDB brain that records the deletes it was sent.
type brainSpy struct {
	mu      sync.Mutex
	deleted []string // knowledge ids
}

func (b *brainSpy) Call(_ context.Context, tool string, args, _ any) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if tool == "knowledge_delete" {
		b.deleted = append(b.deleted, args.(cortexdb.KnowledgeDeleteRequest).KnowledgeID)
	}
	return nil
}

// startWithAccount is start() with an index and a brain on the account service.
func startWithAccount(t *testing.T, ix *indexSpy, brain *brainSpy) *env {
	t.Helper()
	ctx := context.Background()
	db := filepath.Join(t.TempDir(), "noted.db")
	st, err := store.Open(db)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	a, err := auth.New(ctx, st, false)
	if err != nil {
		t.Fatal(err)
	}
	e := &env{st: st, hub: reminder.NewHub(), db: db}
	for name, dst := range map[string]*string{"alice": &e.alice, "bob": &e.bob} {
		u, _ := st.EnsureUser(ctx, name)
		*dst, _ = st.CreateToken(ctx, u.ID, "test")
	}
	deps := server.Deps{Store: st, Auth: a, Hub: e.hub, Location: time.UTC}
	deps.Account = server.NewAccount(deps)
	deps.Account.Engine = ix
	deps.Account.Brain = &cortexsync.Syncer{Store: st, Brain: brain, Target: "brain/test", Users: []string{"alice"}}
	g := server.New(deps)
	lis, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go g.Serve(lis)
	t.Cleanup(g.Stop)
	e.addr = lis.Addr().String()
	return e
}

// seed gives a user rows in most tables, through the API where there is one.
func seed(t *testing.T, e *env, tok string) (noteID string) {
	t.Helper()
	conn := e.conn(t)
	ctx := as(tok)
	must := func(_ any, err error) {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
	}
	cal := pb.NewCalendarServiceClient(conn)
	n, err := pb.NewNoteServiceClient(conn).CreateNote(ctx, &pb.CreateNoteRequest{Note: &pb.Note{Title: "diary", Content: "secret", Tags: []string{"private"}}})
	must(n, err)
	proj, err := pb.NewProjectServiceClient(conn).CreateProject(ctx, &pb.CreateProjectRequest{Project: &pb.Project{Title: "Japan"}})
	must(proj, err)
	tk, err := cal.CreateTask(ctx, &pb.CreateTaskRequest{Task: &pb.Task{Title: "book flights", Tags: []string{"travel"}, ProjectId: proj.Id,
		DueTime: timestamppb.New(time.Now().Add(48 * time.Hour))}})
	must(tk, err)
	must(cal.LogTaskWork(ctx, &pb.LogTaskWorkRequest{TaskId: tk.Id, Minutes: 30}))
	must(cal.CreateEvent(ctx, &pb.CreateEventRequest{Event: &pb.Event{Title: "dentist", StartTime: timestamppb.New(time.Now().Add(time.Hour))}}))
	must(pb.NewAlarmServiceClient(conn).CreateAlarm(ctx, &pb.CreateAlarmRequest{Alarm: &pb.Alarm{Label: "wake", Schedule: &pb.AlarmSchedule{Kind: "recurring", Anchor: time.Now().Format("2006-01-02"), Time: "07:00", Recurrence: &pb.AlarmRecurrence{Freq: "daily"}}}}))
	goals := pb.NewGoalServiceClient(conn)
	g, err := goals.CreateGoal(ctx, &pb.CreateGoalRequest{Goal: &pb.Goal{Title: "run", Period: pb.GoalPeriod_GOAL_PERIOD_WEEK, Target: 3,
		Milestones: []*pb.Milestone{{Title: "5k"}}}})
	must(g, err)
	must(goals.RecordCheckIn(ctx, &pb.RecordCheckInRequest{GoalId: g.Id, Amount: 1}))
	objs := pb.NewObjectiveServiceClient(conn)
	ob, err := objs.CreateObjective(ctx, &pb.CreateObjectiveRequest{Objective: &pb.Objective{Title: "weight", MetricName: "体重", MetricUnit: "kg", MetricStart: 75, MetricTarget: 68,
		Milestones: []*pb.Milestone{{Title: "72"}}}})
	must(ob, err)
	must(objs.RecordMeasurement(ctx, &pb.RecordMeasurementRequest{ObjectiveId: ob.Id, Value: 74}))
	tm := pb.NewTimeServiceClient(conn)
	must(tm.CreateTimeEntry(ctx, &pb.CreateTimeEntryRequest{Entry: &pb.TimeEntry{Title: "swim", Minutes: 40, GoalId: g.Id}}))
	must(tm.StartTimer(ctx, &pb.StartTimerRequest{Title: "read"}))
	must(pb.NewPreferenceServiceClient(conn).SetPreference(ctx, &pb.SetPreferenceRequest{Key: "ui.theme", Value: `{"id":"paper"}`}))
	must(pb.NewCompassServiceClient(conn).SetCompass(ctx, &pb.SetCompassRequest{Compass: &pb.Compass{Vision: "build things that last"}}))
	must(pb.NewHoldingServiceClient(conn).CreateHolding(ctx, &pb.CreateHoldingRequest{Holding: &pb.Holding{Symbol: "VOO"}}))
	acct := pb.NewAccountServiceClient(conn)
	must(acct.CreateToken(ctx, &pb.CreateTokenRequest{Label: "Claude Code"}))
	return n.Id
}

// ownedRows counts, in every table, the rows that belong to userID: by a
// user_id column, or through a parent row that does.
func ownedRows(t *testing.T, path, userID string, parents map[string][]string) map[string]int {
	t.Helper()
	db, err := sql.Open("sqlite", "file:"+path+"?mode=ro&_pragma=busy_timeout(5000)")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	rows, err := db.Query(`SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'`)
	if err != nil {
		t.Fatal(err)
	}
	var tables []string
	for rows.Next() {
		var n string
		rows.Scan(&n)
		tables = append(tables, n)
	}
	rows.Close()
	out := map[string]int{}
	for _, tb := range tables {
		var has int
		if err := db.QueryRow(`SELECT COUNT(*) FROM pragma_table_info(?) WHERE name = 'user_id'`, tb).Scan(&has); err != nil {
			t.Fatal(err)
		}
		if has > 0 {
			var n int
			if err := db.QueryRow(`SELECT COUNT(*) FROM "`+tb+`" WHERE user_id = ?`, userID).Scan(&n); err != nil {
				t.Fatalf("%s: %v", tb, err)
			}
			if n > 0 {
				out[tb] = n
			}
		}
	}
	var n int
	if err := db.QueryRow(`SELECT COUNT(*) FROM users WHERE id = ?`, userID).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n > 0 {
		out["users"] = n
	}
	// Child rows keyed by a parent id the user had.
	for child, ids := range parents {
		col := map[string]string{"note_tags": "note_id", "task_tags": "task_id", "goal_milestones": "goal_id", "objective_milestones": "objective_id"}[child]
		for _, id := range ids {
			var c int
			if err := db.QueryRow(`SELECT COUNT(*) FROM `+child+` WHERE `+col+` = ?`, id).Scan(&c); err != nil {
				t.Fatal(err)
			}
			out[child] += c
		}
		if out[child] == 0 {
			delete(out, child)
		}
	}
	return out
}

func idsOf(t *testing.T, path, table, userID string) []string {
	t.Helper()
	db, err := sql.Open("sqlite", "file:"+path+"?mode=ro&_pragma=busy_timeout(5000)")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	rows, err := db.Query(`SELECT id FROM `+table+` WHERE user_id = ?`, userID)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var id string
		rows.Scan(&id)
		out = append(out, id)
	}
	return out
}

func TestDeleteAccount(t *testing.T) {
	ix := &indexSpy{removed: map[string]string{}}
	brain := &brainSpy{}
	e := startWithAccount(t, ix, brain)
	ctx := context.Background()
	alice, _ := e.st.UserForToken(ctx, e.alice)
	bob, _ := e.st.UserForToken(ctx, e.bob)

	aliceNote := seed(t, e, e.alice)
	seed(t, e, e.bob)
	// What has no API of its own: an Apple ID, the sign-in email, proposals,
	// the change log and the CortexDB ledger.
	if err := e.st.LinkApple(ctx, alice.ID, "apple-sub-alice"); err != nil {
		t.Fatal(err)
	}
	if err := e.st.LinkApple(ctx, bob.ID, "apple-sub-bob"); err != nil {
		t.Fatal(err)
	}
	acct := pb.NewAccountServiceClient(e.conn(t))
	if _, err := acct.SetEmailPassword(as(e.alice), &pb.SetEmailPasswordRequest{Email: "alice@example.com", Password: "alice-pass"}); err != nil {
		t.Fatal(err)
	}
	if _, _, err := e.st.SaveProposal(ctx, store.Proposal{UserID: alice.ID, Kind: "plan", Status: "pending", Title: "x", Source: "rules",
		Ops: json.RawMessage(`[{"op":"noop"}]`)}); err != nil {
		t.Fatal(err)
	}
	if _, err := e.st.SaveChange(ctx, store.Change{UserID: alice.ID, Summary: "x", Entries: json.RawMessage(`[]`)}); err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	if err := e.st.CortexBegin(ctx, alice.ID, "brain/test", now); err != nil {
		t.Fatal(err)
	}
	for _, k := range []string{"note:a", "task:b"} {
		if err := e.st.CortexMark(ctx, alice.ID, k, "h", now); err != nil {
			t.Fatal(err)
		}
	}

	// Pro, the AI allowance, a fired reminder and an MCP sign-in in flight.
	if err := e.st.BindPurchase(ctx, "tx-alice", alice.ID, "pro", "Sandbox"); err != nil {
		t.Fatal(err)
	}
	if err := e.st.BindPurchase(ctx, "tx-bob", bob.ID, "pro", "Sandbox"); err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{alice.ID, bob.ID} {
		if ok, err := e.st.SpendAI(ctx, id, now, 10); err != nil || !ok {
			t.Fatalf("spend ai: %v %v", ok, err)
		}
		if err := e.st.SetAIModel(ctx, id, store.AIModel{BaseURL: "https://llm.example.com/v1", Model: "m", KeySealed: []byte{1}, KeyHint: "…"}); err != nil {
			t.Fatal(err)
		}
	}
	client, err := e.st.CreateOAuthClient(ctx, "Claude", []string{"http://127.0.0.1:43510/cb"})
	if err != nil {
		t.Fatal(err)
	}
	rw, err := sql.Open("sqlite", "file:"+e.db+"?_pragma=busy_timeout(5000)")
	if err != nil {
		t.Fatal(err)
	}
	ms := now.UnixMilli()
	for _, q := range []struct {
		sql  string
		args []any
	}{
		{`INSERT INTO reminders(id, user_id, kind, ref_id, title, due_ms, fire_ms) VALUES ('r-alice', ?, 1, 'x', 'dentist', ?, ?)`, []any{alice.ID, ms, ms}},
		{`INSERT INTO reminders(id, user_id, kind, ref_id, title, due_ms, fire_ms) VALUES ('r-bob', ?, 1, 'x', 'dentist', ?, ?)`, []any{bob.ID, ms, ms}},
		{`INSERT INTO pairings(code, poll_hash, client_id, redirect_uri, code_challenge, created_ms, expires_ms, user_id) VALUES ('p-alice', 'h-alice', ?, 'u', 'c', ?, ?, ?)`, []any{client.ID, ms, ms + 60000, alice.ID}},
		{`INSERT INTO oauth_codes(hash, client_id, redirect_uri, code_challenge, user_id, label, expires_ms) VALUES ('c-alice', ?, 'u', 'c', ?, 'Claude', ?)`, []any{client.ID, alice.ID, ms + 60000}},
	} {
		if _, err := rw.Exec(q.sql, q.args...); err != nil {
			t.Fatalf("%s: %v", q.sql, err)
		}
	}
	rw.Close()

	parents := map[string][]string{
		"note_tags": idsOf(t, e.db, "notes", alice.ID), "task_tags": idsOf(t, e.db, "tasks", alice.ID),
		"goal_milestones": idsOf(t, e.db, "goals", alice.ID), "objective_milestones": idsOf(t, e.db, "objectives", alice.ID),
	}
	before := ownedRows(t, e.db, alice.ID, parents)
	for _, tb := range []string{"users", "notes", "notes_fts", "note_tags", "tasks", "task_tags", "task_work", "events", "projects", "goals",
		"goal_milestones", "goal_checkins", "objectives", "objective_milestones", "objective_measurements", "time_entries", "preferences",
		"compass_revisions", "holdings", "tokens", "apple_ids", "user_emails", "proposals", "changes", "cortex_sync_state", "cortex_sync_items",
		"purchases", "ai_usage", "ai_models", "reminders", "pairings", "oauth_codes"} {
		if before[tb] == 0 {
			t.Errorf("seed left %s empty for alice; the test would not show it is deleted", tb)
		}
	}
	bobBefore := ownedRows(t, e.db, bob.ID, nil)

	// Without the word, nothing happens.
	for _, c := range []string{"", "delete", "删除", " DELETE"} {
		if _, err := acct.DeleteAccount(as(e.alice), &pb.DeleteAccountRequest{Confirm: c}); code(err) != codes.InvalidArgument {
			t.Fatalf("confirm %q: %v", c, err)
		}
	}
	if _, err := acct.DeleteAccount(as("noted_bogus"), &pb.DeleteAccountRequest{Confirm: "DELETE"}); code(err) != codes.Unauthenticated {
		t.Fatalf("bad token: %v", err)
	}
	if got := ownedRows(t, e.db, alice.ID, parents); len(got) != len(before) {
		t.Fatalf("a refused delete removed rows: %v -> %v", before, got)
	}

	if _, err := acct.DeleteAccount(as(e.alice), &pb.DeleteAccountRequest{Confirm: "DELETE"}); err != nil {
		t.Fatal(err)
	}

	// Every row is gone, and nothing is left dangling.
	if left := ownedRows(t, e.db, alice.ID, parents); len(left) != 0 {
		t.Fatalf("rows left after delete: %v", left)
	}
	db, _ := sql.Open("sqlite", "file:"+e.db+"?mode=ro")
	defer db.Close()
	if r, err := db.Query(`PRAGMA foreign_key_check`); err != nil {
		t.Fatal(err)
	} else {
		if r.Next() {
			t.Error("foreign key violations after delete")
		}
		r.Close()
	}

	// Both tokens fail; the Apple ID and the email no longer sign in.
	notes := pb.NewNoteServiceClient(e.conn(t))
	if _, err := notes.ListNotes(as(e.alice), &pb.ListNotesRequest{}); code(err) != codes.Unauthenticated {
		t.Fatalf("token after delete: %v", err)
	}
	if _, err := acct.GetAccount(as(e.alice), &pb.GetAccountRequest{}); code(err) != codes.Unauthenticated {
		t.Fatalf("account after delete: %v", err)
	}
	if _, err := acct.DeleteAccount(as(e.alice), &pb.DeleteAccountRequest{Confirm: "DELETE"}); code(err) != codes.Unauthenticated {
		t.Fatalf("second delete: %v", err)
	}
	if _, err := e.st.UserForApple(ctx, "apple-sub-alice"); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("apple id after delete: %v", err)
	}
	if _, err := acct.SignIn(context.Background(), &pb.SignInRequest{Email: "alice@example.com", Password: "alice-pass"}); err == nil {
		t.Fatal("email sign-in works after delete")
	}

	// Her notes left the semantic index, and the brain was told to drop her items.
	if ix.removed[aliceNote] != alice.ID {
		t.Fatalf("note not removed from the index: %v", ix.removed)
	}
	for _, uid := range ix.removed {
		if uid != alice.ID {
			t.Fatalf("someone else's note left the index: %v", ix.removed)
		}
	}
	if len(ix.forgot) != 1 || ix.forgot[0] != alice.ID {
		t.Fatalf("assistant conversations forgotten for %v, want only alice", ix.forgot)
	}
	brain.mu.Lock()
	gotBrain := append([]string(nil), brain.deleted...)
	brain.mu.Unlock()
	if len(gotBrain) != 2 || gotBrain[0] != cortexsync.KnowledgeID("alice", "note:a") || gotBrain[1] != cortexsync.KnowledgeID("alice", "task:b") {
		t.Fatalf("brain deletes: %v", gotBrain)
	}

	// Bob is untouched.
	if after := ownedRows(t, e.db, bob.ID, nil); len(after) != len(bobBefore) {
		t.Fatalf("bob's rows changed: %v -> %v", bobBefore, after)
	} else {
		for tb, n := range bobBefore {
			if after[tb] != n {
				t.Errorf("bob's %s: %d -> %d", tb, n, after[tb])
			}
		}
	}
	if l, err := notes.ListNotes(as(e.bob), &pb.ListNotesRequest{}); err != nil || len(l.Notes) != 1 {
		t.Fatalf("bob's notes: %v %d", err, len(l.GetNotes()))
	}
	if a, err := acct.GetAccount(as(e.bob), &pb.GetAccountRequest{}); err != nil || !a.AppleLinked {
		t.Fatalf("bob's account: %v %+v", err, a)
	}
	// The name is free again.
	if u, err := e.st.EnsureUser(ctx, "alice"); err != nil || u.ID == alice.ID {
		t.Fatalf("name after delete: %v %+v", err, u)
	}
}

func TestDeleteAccountRefusedWithAuthDisabled(t *testing.T) {
	e := start(t, nil, true)
	acct := pb.NewAccountServiceClient(e.conn(t))
	if _, err := acct.DeleteAccount(context.Background(), &pb.DeleteAccountRequest{Confirm: "DELETE"}); code(err) != codes.FailedPrecondition {
		t.Fatalf("auth disabled: %v", err)
	}
}
