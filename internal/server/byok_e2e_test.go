package server_test

import (
	"bytes"
	"context"
	"database/sql"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	pb "github.com/liliang-cn/noted/gen/noted/v1"
	"github.com/liliang-cn/noted/internal/secretbox"
	"github.com/liliang-cn/noted/internal/server"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
	_ "modernc.org/sqlite"
)

// A fake key: long enough to be masked as "fak…6789".
const userKey = "fake-user-key-0123456789"

// ownLLM is a second fake provider standing in for the user's own, recording
// the bearer token each request carried.
type ownLLM struct {
	*fakeProvider
	url  string
	mu   sync.Mutex
	auth []string
}

func newOwnLLM(t *testing.T, f *fakeProvider) *ownLLM {
	t.Helper()
	o := &ownLLM{fakeProvider: f}
	h := f.handler()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		o.mu.Lock()
		o.auth = append(o.auth, r.Header.Get("Authorization"))
		o.mu.Unlock()
		h.ServeHTTP(w, r)
	}))
	t.Cleanup(srv.Close)
	o.url = srv.URL + "/v1"
	return o
}

func (o *ownLLM) lastAuth() string {
	o.mu.Lock()
	defer o.mu.Unlock()
	if len(o.auth) == 0 {
		return ""
	}
	return o.auth[len(o.auth)-1]
}

func TestOwnModelKey(t *testing.T) {
	def := &fakeProvider{script: func(map[string]any) (string, []map[string]any) { return "server model", nil }}
	own := newOwnLLM(t, &fakeProvider{})
	own.script = func(req map[string]any) (string, []map[string]any) {
		msgs, _ := req["messages"].([]any)
		booking := false
		for _, m := range msgs {
			mm, _ := m.(map[string]any)
			if c, _ := mm["content"].(string); mm["role"] == "user" && strings.Contains(c, "book a dentist") {
				booking = true
			}
		}
		if booking {
			if _, done := toolResult(req); !done {
				return "", []map[string]any{toolCall("call_1", "create_event", map[string]any{
					"title": "Dentist", "start": "2026-11-03T15:00:00+00:00"})}
			}
			return "Prepared it.", nil
		}
		return "own model", nil
	}
	box, err := secretbox.New("test-server-secret-0123456789")
	if err != nil {
		t.Fatal(err)
	}
	probe := start(t, nil, false)
	eng := newEngine(t, probe, def, false)
	restart(t, probe, eng) // makes alice and bob Pro
	deps := server.Deps{AIDailyLimit: 1, LocalModels: true, Secret: box}
	e := serveWith(t, probe, eng, deps)
	ctx := context.Background()
	aiC := pb.NewAIServiceClient(e.conn(t))
	alice, bob := as(e.alice), as(e.bob)
	set := func(tok context.Context, base, model, key string) (*pb.ModelSettings, error) {
		return aiC.SetModelSettings(tok, &pb.SetModelSettingsRequest{BaseUrl: base, Model: model, ApiKey: key})
	}
	noKey := func(what string, m proto.Message) {
		t.Helper()
		b, _ := proto.Marshal(m)
		if bytes.Contains(b, []byte(userKey)) || bytes.Contains(b, []byte("0123456789")) {
			t.Fatalf("%s carries the key: %v", what, m)
		}
	}

	// Without Pro there is no own key: it cannot buy its way around Pro.
	if err := e.st.SetUserPro(ctx, "bob", false); err != nil {
		t.Fatal(err)
	}
	if _, err := set(bob, own.url, "mine", userKey); code(err) != codes.FailedPrecondition || !strings.Contains(status.Convert(err).Message(), "Pro") {
		t.Fatalf("free user sets a key: %v", err)
	}
	if own.calls() != 0 {
		t.Fatal("a free user's key was tried")
	}

	// Endpoints that would not work are refused before anything is saved.
	dead := httptest.NewServer(http.NotFoundHandler())
	deadURL := dead.URL + "/v1"
	dead.Close()
	denied := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusUnauthorized)
		w.Write([]byte(`{"error":{"message":"Incorrect API key provided","type":"invalid_request_error","code":"invalid_api_key"}}`))
	}))
	t.Cleanup(denied.Close)
	for name, c := range map[string]struct{ base, model, key, want string }{
		"plain http":    {"http://api.example.com/v1", "m", userKey, "https"},
		"not a url":     {"api.example.com", "m", userKey, "https"},
		"no model":      {own.url, " ", userKey, "模型"},
		"no key":        {own.url, "m", "", "API Key"},
		"key refused":   {denied.URL + "/v1", "m", userKey, "API Key"},
		"nothing there": {deadURL, "m", userKey, "连不上"},
	} {
		_, err := set(alice, c.base, c.model, c.key)
		if code(err) != codes.InvalidArgument || !strings.Contains(status.Convert(err).Message(), c.want) {
			t.Errorf("%s: %v", name, err)
		}
	}
	// On a real server localhost and private addresses are refused.
	strict := serveWith(t, probe, eng, server.Deps{Secret: box})
	for _, base := range []string{own.url, "https://127.0.0.1/v1", "https://10.1.2.3/v1", "https://localhost/v1", "https://[::1]/v1"} {
		if _, err := pb.NewAIServiceClient(strict.conn(t)).SetModelSettings(alice,
			&pb.SetModelSettingsRequest{BaseUrl: base, Model: "m", ApiKey: userKey}); code(err) != codes.InvalidArgument {
			t.Errorf("strict server accepted %s: %v", base, err)
		}
	}
	if m, _ := aiC.GetModelSettings(alice, &pb.GetModelSettingsRequest{}); m.KeySet {
		t.Fatalf("a refused endpoint was saved: %v", m)
	}

	// A good one is tested with one call, then saved.
	m, err := set(alice, own.url+"/", "mine", userKey)
	if err != nil {
		t.Fatal(err)
	}
	if !m.KeySet || !m.Active || m.KeyHint != "fak…6789" || m.Model != "mine" || m.BaseUrl != own.url || m.Host != "127.0.0.1" {
		t.Fatalf("settings: %v", m)
	}
	noKey("set", m)
	if own.calls() != 1 || own.lastAuth() != "Bearer "+userKey {
		t.Fatalf("test call: %d calls", own.calls())
	}
	got, err := aiC.GetModelSettings(alice, &pb.GetModelSettingsRequest{})
	if err != nil || !proto.Equal(got, m) {
		t.Fatalf("get: %v %v", got, err)
	}
	noKey("get", got)

	// The key is encrypted at rest.
	db, err := sql.Open("sqlite", "file:"+probe.db+"?mode=ro&_pragma=busy_timeout(5000)")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var sealed []byte
	var hint string
	if err := db.QueryRow(`SELECT key_sealed, key_hint FROM ai_models`).Scan(&sealed, &hint); err != nil {
		t.Fatal(err)
	}
	if len(sealed) == 0 || bytes.Contains(sealed, []byte(userKey)) || bytes.Contains(sealed, []byte("0123456789")) || strings.Contains(hint, "0123") {
		t.Fatal("the key is stored readable")
	}

	// Alice's requests now go to her endpoint, with her key, and are not capped
	// (the cap here is 1 a day).
	defBefore := def.calls()
	for i := 0; i < 3; i++ {
		r, err := aiC.Ask(alice, &pb.AskRequest{Message: "hi"})
		if err != nil || r.Reply != "own model" {
			t.Fatalf("ask %d: %+v %v", i+1, r, err)
		}
	}
	// Tools and conversations work the same on her model.
	r, err := aiC.Ask(alice, &pb.AskRequest{Message: "book a dentist visit on Nov 3 at 3pm"})
	if err != nil || r.Proposal == nil || r.Reply != "Prepared it." {
		t.Fatalf("ask with a tool: %+v %v", r, err)
	}
	if r2, err := aiC.Ask(alice, &pb.AskRequest{Message: "hi again", SessionId: r.SessionId}); err != nil || r2.SessionId != r.SessionId {
		t.Fatalf("follow-up: %+v %v", r2, err)
	}
	if def.calls() != defBefore {
		t.Fatalf("the server's model was called %d times for alice's own-key requests", def.calls()-defBefore)
	}
	if own.lastAuth() != "Bearer "+userKey {
		t.Fatal("requests did not carry alice's key")
	}
	// Bob, Pro again and without a key of his own, stays on the server's model.
	if err := e.st.SetUserPro(ctx, "bob", true); err != nil {
		t.Fatal(err)
	}
	if r, err := aiC.Ask(bob, &pb.AskRequest{Message: "hi"}); err != nil || r.Reply != "server model" {
		t.Fatalf("bob: %+v %v", r, err)
	}

	// Changing only the model keeps the stored key.
	if m, err := set(alice, own.url, "mine-2", ""); err != nil || m.Model != "mine-2" || m.KeyHint != "fak…6789" {
		t.Fatalf("change model: %v %v", m, err)
	}

	// Losing Pro stops the key being used (it stays stored).
	if err := e.st.SetUserPro(ctx, "alice", false); err != nil {
		t.Fatal(err)
	}
	ownBefore := own.calls()
	if _, err := aiC.Ask(alice, &pb.AskRequest{Message: "hi"}); code(err) != codes.FailedPrecondition {
		t.Fatalf("ask after losing Pro: %v", err)
	}
	if m, _ := aiC.GetModelSettings(alice, &pb.GetModelSettingsRequest{}); !m.KeySet || m.Active {
		t.Fatalf("settings after losing Pro: %v", m)
	}
	if own.calls() != ownBefore {
		t.Fatal("a non-Pro request reached the own model")
	}
	if err := e.st.SetUserPro(ctx, "alice", true); err != nil {
		t.Fatal(err)
	}

	// A server whose secret changed cannot open the key: back to the server's model.
	other, _ := secretbox.New("another-secret-0123456789")
	rotated := serveWith(t, probe, eng, server.Deps{AIDailyLimit: 1, LocalModels: true, Secret: other})
	if m, _ := pb.NewAIServiceClient(rotated.conn(t)).GetModelSettings(alice, &pb.GetModelSettingsRequest{}); m.Active {
		t.Fatalf("active under another secret: %v", m)
	}

	// Clearing goes back to the server's model and its cap. Her own-key calls
	// did not count, so one is left today.
	if m, err := aiC.ClearModelSettings(alice, &pb.ClearModelSettingsRequest{}); err != nil || m.KeySet {
		t.Fatalf("clear: %v %v", m, err)
	}
	if r, err := aiC.Ask(alice, &pb.AskRequest{Message: "hi"}); err != nil || r.Reply != "server model" {
		t.Fatalf("after clear: %+v %v", r, err)
	}
	if _, err := aiC.Ask(alice, &pb.AskRequest{Message: "hi"}); code(err) != codes.ResourceExhausted {
		t.Fatalf("capped again: %v", err)
	}
	var n int
	db.QueryRow(`SELECT COUNT(*) FROM ai_models`).Scan(&n)
	if n != 0 {
		t.Fatalf("clear left %d rows", n)
	}
}
