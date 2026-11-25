package server_test

import (
	"context"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/liliang-cn/noted/internal/auth"
	"github.com/liliang-cn/noted/internal/server"
	"github.com/liliang-cn/noted/internal/store"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// withExtraction serves e's store again with alice allowed to be read for the brain.
func withExtraction(t *testing.T, e *env) *env {
	t.Helper()
	a, err := auth.New(context.Background(), e.st, false)
	if err != nil {
		t.Fatal(err)
	}
	g := server.New(server.Deps{Store: e.st, Auth: a, Hub: e.hub, Location: time.UTC, ExtractionUsers: []string{"alice"}})
	lis, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go g.Serve(lis)
	t.Cleanup(g.Stop)
	return &env{st: e.st, hub: e.hub, alice: e.alice, bob: e.bob, addr: lis.Addr().String()}
}

func TestMCPExtraction(t *testing.T) {
	e0 := start(t, nil, false)
	ctx := context.Background()
	alice, _ := e0.st.EnsureUser(ctx, "alice")
	bob, _ := e0.st.EnsureUser(ctx, "bob")
	work, _ := e0.st.CreateNote(ctx, store.Note{UserID: alice.ID, Title: "Embeddings", Content: "CortexDB runs on orange", Space: store.SpaceWork})
	life, _ := e0.st.CreateNote(ctx, store.Note{UserID: alice.ID, Title: "Family", Content: "三宝 swims on Saturday", Space: store.SpaceLife})
	if _, err := e0.st.CreateNote(ctx, store.Note{UserID: bob.ID, Title: "Bob's", Content: "Bob's private text here"}); err != nil {
		t.Fatal(err)
	}

	// Off by default: nobody is allowed.
	if _, isErr := callErr(t, mcpSession(t, e0, e0.alice), "extraction_pending", map[string]any{}); !isErr {
		t.Fatal("extraction_pending must be refused unless extract is external")
	}

	e := withExtraction(t, e0)
	cs := mcpSession(t, e, e.alice)
	if _, isErr := callErr(t, mcpSession(t, e, e.bob), "extraction_pending", map[string]any{}); !isErr {
		t.Fatal("bob is not a sync user")
	}
	if _, err := e.st.SetAIAccess(ctx, alice.ID, false, true); err != nil {
		t.Fatal(err)
	}
	_, sc, isErr := callS(t, cs, "extraction_pending", map[string]any{"limit": 10})
	notes, _ := sc["notes"].([]any)
	if isErr || len(notes) != 1 || notes[0].(map[string]any)["note_id"] != life.ID {
		t.Fatalf("a space closed to AI must not be listed: %v", sc)
	}
	if ins, _ := sc["instructions"].(string); !strings.Contains(ins, "entities") || !strings.Contains(ins, "extraction_submit") {
		t.Errorf("instructions: %q", ins)
	}
	if _, err := e.st.SetAIAccess(ctx, alice.ID, true, true); err != nil {
		t.Fatal(err)
	}
	_, sc, _ = callS(t, cs, "extraction_pending", map[string]any{})
	notes, _ = sc["notes"].([]any)
	if len(notes) != 2 {
		t.Fatalf("pending: %v", sc)
	}
	var hash string
	for _, n := range notes {
		if m := n.(map[string]any); m["note_id"] == work.ID {
			hash, _ = m["hash"].(string)
		}
	}
	res := `{"entities":[{"name":"CortexDB","type":"technology"},{"name":"orange","type":"place"},{"name":"x","type":"person"}],"relations":[{"from":"CortexDB","to":"orange","type":"runs_on"}]}`
	_, sc, isErr = callS(t, cs, "extraction_submit", map[string]any{"note_id": work.ID, "hash": "old", "result": res})
	if isErr || sc["status"] != "stale" {
		t.Fatalf("stale: %v", sc)
	}
	_, sc, isErr = callS(t, cs, "extraction_submit", map[string]any{"note_id": work.ID, "hash": hash, "result": res})
	if isErr || sc["status"] != "stored" || sc["entities"] != float64(2) || sc["relations"] != float64(1) {
		t.Fatalf("stored: %v", sc)
	}
	if _, isErr := callErr(t, cs, "extraction_submit", map[string]any{"note_id": life.ID, "hash": "h", "result": "not json"}); !isErr {
		t.Fatal("garbage must be an error")
	}
	_, sc, _ = callS(t, cs, "extraction_pending", map[string]any{})
	if notes, _ = sc["notes"].([]any); len(notes) != 1 {
		t.Fatalf("the stored note is no longer pending: %v", sc)
	}
	// Bob cannot submit for Alice's note.
	if _, err := e.st.GetNote(ctx, bob.ID, work.ID); err == nil {
		t.Fatal("isolation broken")
	}
}

// callErr calls a tool that is expected to fail and returns its text.
func callErr(t *testing.T, cs *mcp.ClientSession, tool string, args map[string]any) (string, bool) {
	t.Helper()
	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{Name: tool, Arguments: args})
	if err != nil {
		return err.Error(), true
	}
	var b strings.Builder
	for _, c := range res.Content {
		if tc, ok := c.(*mcp.TextContent); ok {
			b.WriteString(tc.Text)
		}
	}
	return b.String(), res.IsError
}
