package server_test

import (
	"context"
	"strings"
	"testing"
	"time"

	pb "github.com/liliang-cn/noted/gen/noted/v1"
	"github.com/liliang-cn/noted/internal/ai"
	"google.golang.org/grpc"
)

// consentToAI records the agreement the app's consent sheet writes.
func consentToAI(t *testing.T, conn *grpc.ClientConn, ctx context.Context) {
	t.Helper()
	if _, err := pb.NewPreferenceServiceClient(conn).SetPreference(ctx, &pb.SetPreferenceRequest{
		Key: "ai.consent", Value: `{"granted":true,"version":1,"at":"2026-11-11T00:00:00Z"}`,
	}); err != nil {
		t.Fatal(err)
	}
}

// Nothing is sent to the embedding endpoint until the person agrees in the
// app; agreeing queues their notes, withdrawing takes them out of the index.
func TestSemanticIndexWaitsForConsent(t *testing.T) {
	f := &fakeProvider{script: func(map[string]any) (string, []map[string]any) { return "ok", nil }}
	e, eng := startWithAI(t, f, true)
	conn := e.conn(t)
	ctx := as(e.alice)
	notes, prefs := pb.NewNoteServiceClient(conn), pb.NewPreferenceServiceClient(conn)
	notes.CreateNote(ctx, &pb.CreateNoteRequest{Note: &pb.Note{Title: "Trip", Content: "osaka flights " + secret}})
	u, _ := e.st.EnsureUser(context.Background(), "alice")

	ix := ai.NewIndexer(e.st, eng)
	run, cancel := context.WithCancel(context.Background())
	defer cancel()
	go ix.Run(run)
	ix.Wake()

	waitFor := func(what string, cond func() bool) {
		t.Helper()
		deadline := time.Now().Add(15 * time.Second)
		for !cond() {
			if time.Now().After(deadline) {
				t.Fatalf("timed out waiting for %s", what)
			}
			time.Sleep(50 * time.Millisecond)
		}
	}
	sentSecret := func() bool {
		f.mu.Lock()
		defer f.mu.Unlock()
		return strings.Contains(strings.Join(f.embedded, "\n"), secret)
	}
	indexed := func() int {
		ms, _ := eng.Search(context.Background(), u.ID, "osaka", 10)
		return len(ms)
	}

	waitFor("the indexer to pass over the note", func() bool {
		stale, _ := e.st.NotesNeedingIndex(context.Background(), 10)
		return len(stale) == 0
	})
	if sentSecret() || indexed() != 0 {
		t.Fatal("a note was embedded before the user agreed to AI processing")
	}

	consentToAI(t, conn, ctx)
	ix.Wake()
	waitFor("the note to be indexed once agreed", func() bool { return indexed() == 1 })

	if _, err := prefs.SetPreference(ctx, &pb.SetPreferenceRequest{Key: "ai.consent", Value: `{"granted":false,"version":1}`}); err != nil {
		t.Fatal(err)
	}
	ix.Wake()
	waitFor("the note to leave the index once withdrawn", func() bool { return indexed() == 0 })
}
