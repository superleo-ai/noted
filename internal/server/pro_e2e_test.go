package server_test

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/asn1"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"net"
	"strings"
	"testing"
	"time"

	pb "github.com/liliang-cn/noted/gen/noted/v1"
	"github.com/liliang-cn/noted/internal/ai"
	"github.com/liliang-cn/noted/internal/auth"
	"github.com/liliang-cn/noted/internal/server"
	"github.com/liliang-cn/noted/internal/service"
	"github.com/liliang-cn/noted/internal/storekit"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/timestamppb"
)

// serveWith serves old's store and tokens again with these extra deps.
func serveWith(t *testing.T, old *env, engine ai.Engine, d server.Deps) *env {
	t.Helper()
	a, err := auth.New(context.Background(), old.st, false)
	if err != nil {
		t.Fatal(err)
	}
	d.Store, d.Auth, d.Hub, d.Engine, d.Location = old.st, a, old.hub, engine, time.UTC
	g := server.New(d)
	lis, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go g.Serve(lis)
	t.Cleanup(g.Stop)
	return &env{st: old.st, hub: old.hub, db: old.db, alice: old.alice, bob: old.bob, addr: lis.Addr().String()}
}

func (f *fakeProvider) calls() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.chatReqs)
}

func TestAIIsForProUsersOnly(t *testing.T) {
	f := &fakeProvider{script: func(map[string]any) (string, []map[string]any) { return "ok", nil }}
	e, _ := startWithAI(t, f, false)
	ctx := context.Background()
	if err := e.st.SetUserPro(ctx, "bob", false); err != nil {
		t.Fatal(err)
	}
	conn := e.conn(t)
	aiC, notes := pb.NewAIServiceClient(conn), pb.NewNoteServiceClient(conn)
	n, err := notes.CreateNote(as(e.bob), &pb.CreateNoteRequest{Note: &pb.Note{Title: "Plan", Content: "call the bank, buy milk"}})
	if err != nil {
		t.Fatal(err)
	}

	bob := as(e.bob)
	refused := map[string]error{}
	_, refused["Ask"] = aiC.Ask(bob, &pb.AskRequest{Message: "hi"})
	_, refused["PlanFromText"] = aiC.PlanFromText(bob, &pb.PlanFromTextRequest{Text: "move house in March"})
	_, refused["DailyBriefing"] = aiC.DailyBriefing(bob, &pb.DailyBriefingRequest{})
	_, refused["SummarizeNote"] = aiC.SummarizeNote(bob, &pb.SummarizeNoteRequest{NoteId: n.Id})
	_, refused["SuggestTags"] = aiC.SuggestTags(bob, &pb.SuggestTagsRequest{NoteId: n.Id})
	_, refused["ExtractTasks"] = aiC.ExtractTasks(bob, &pb.ExtractTasksRequest{NoteId: n.Id})
	for rpc, err := range refused {
		if code(err) != codes.FailedPrecondition || !strings.Contains(status.Convert(err).Message(), "Noted Pro") {
			t.Errorf("%s for a free user: %v", rpc, err)
		}
	}
	if f.calls() != 0 {
		t.Fatalf("a free user's request reached the model %d times", f.calls())
	}

	// What runs on rules stays free.
	sugg := pb.NewSuggestionServiceClient(conn)
	if _, err := sugg.GetWeeklyReview(bob, &pb.GetWeeklyReviewRequest{}); err != nil {
		t.Errorf("weekly review: %v", err)
	}
	if _, err := sugg.ListProposals(bob, &pb.ListProposalsRequest{}); err != nil {
		t.Errorf("list proposals: %v", err)
	}
	if _, err := sugg.ListChanges(bob, &pb.ListChangesRequest{}); err != nil {
		t.Errorf("list changes: %v", err)
	}
	if st, err := aiC.GetStatus(bob, &pb.GetStatusRequest{}); err != nil || !st.Enabled {
		t.Errorf("status: %+v %v", st, err)
	}

	// Pro (here granted by the server) unlocks it.
	if r, err := aiC.Ask(as(e.alice), &pb.AskRequest{Message: "hi"}); err != nil || r.Reply != "ok" {
		t.Fatalf("pro ask: %+v %v", r, err)
	}
	if err := e.st.SetUserPro(ctx, "bob", true); err != nil {
		t.Fatal(err)
	}
	if _, err := aiC.SummarizeNote(bob, &pb.SummarizeNoteRequest{NoteId: n.Id}); err != nil {
		t.Fatalf("after granting pro: %v", err)
	}
}

func TestAIDailyLimit(t *testing.T) {
	f := &fakeProvider{script: func(map[string]any) (string, []map[string]any) { return "summary", nil }}
	probe := start(t, nil, false)
	eng := newEngine(t, probe, f, false)
	restart(t, probe, eng) // makes alice and bob Pro
	e := serveWith(t, probe, eng, server.Deps{AIDailyLimit: 2})
	conn := e.conn(t)
	aiC, notes := pb.NewAIServiceClient(conn), pb.NewNoteServiceClient(conn)
	n, _ := notes.CreateNote(as(e.alice), &pb.CreateNoteRequest{Note: &pb.Note{Title: "a", Content: "b"}})

	// A request refused before reaching the model costs nothing.
	if _, err := aiC.Ask(as(e.alice), &pb.AskRequest{Message: " "}); code(err) != codes.InvalidArgument {
		t.Fatalf("empty ask: %v", err)
	}
	for i := 0; i < 2; i++ {
		if _, err := aiC.SummarizeNote(as(e.alice), &pb.SummarizeNoteRequest{NoteId: n.Id}); err != nil {
			t.Fatalf("call %d: %v", i+1, err)
		}
	}
	_, err := aiC.DailyBriefing(as(e.alice), &pb.DailyBriefingRequest{Day: timestamppb.Now()})
	if code(err) != codes.ResourceExhausted || !strings.Contains(status.Convert(err).Message(), "明天") {
		t.Fatalf("over the cap: %v", err)
	}
	before := f.calls()
	if _, err := aiC.Ask(as(e.alice), &pb.AskRequest{Message: "hi"}); code(err) != codes.ResourceExhausted {
		t.Fatalf("still over the cap: %v", err)
	}
	if f.calls() != before {
		t.Fatal("a capped request reached the model")
	}
	// The cap is per user.
	if _, err := aiC.Ask(as(e.bob), &pb.AskRequest{Message: "hi"}); err != nil {
		t.Fatalf("bob has his own allowance: %v", err)
	}
	// And it survives a restart.
	e2 := serveWith(t, probe, eng, server.Deps{AIDailyLimit: 2})
	if _, err := pb.NewAIServiceClient(e2.conn(t)).Ask(as(e.alice), &pb.AskRequest{Message: "hi"}); code(err) != codes.ResourceExhausted {
		t.Fatalf("after restart: %v", err)
	}
	// 0 means no cap.
	e3 := serveWith(t, probe, eng, server.Deps{})
	if _, err := pb.NewAIServiceClient(e3.conn(t)).Ask(as(e.alice), &pb.AskRequest{Message: "hi"}); err != nil {
		t.Fatalf("no cap: %v", err)
	}
}

// fakeAppStore is a CA shaped like Apple's: root, intermediate and leaf, with
// the marker extensions Apple puts on App Store signing certificates.
type fakeAppStore struct {
	roots *x509.CertPool
	x5c   []string
	key   *ecdsa.PrivateKey
}

func newFakeAppStore(t *testing.T) *fakeAppStore {
	t.Helper()
	mk := func(tmpl, parent *x509.Certificate, pub, signer any) *x509.Certificate {
		if parent == nil {
			parent = tmpl // self-signed
		}
		der, err := x509.CreateCertificate(rand.Reader, tmpl, parent, pub, signer)
		if err != nil {
			t.Fatal(err)
		}
		c, _ := x509.ParseCertificate(der)
		return c
	}
	key := func() *ecdsa.PrivateKey {
		k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		if err != nil {
			t.Fatal(err)
		}
		return k
	}
	marker := func(oid asn1.ObjectIdentifier) []pkix.Extension {
		return []pkix.Extension{{Id: oid, Value: []byte{5, 0}}}
	}
	from, to := time.Now().Add(-time.Hour), time.Now().Add(24*time.Hour)
	rootKey, midKey, leafKey := key(), key(), key()
	rootTmpl := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "Test Root"}, NotBefore: from, NotAfter: to,
		IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign}
	root := mk(rootTmpl, rootTmpl, &rootKey.PublicKey, rootKey) // self-signed
	mid := mk(&x509.Certificate{SerialNumber: big.NewInt(2), Subject: pkix.Name{CommonName: "Test WWDR"}, NotBefore: from, NotAfter: to,
		IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign,
		ExtraExtensions: marker(asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 6, 2, 1})}, root, &midKey.PublicKey, rootKey)
	leaf := mk(&x509.Certificate{SerialNumber: big.NewInt(3), Subject: pkix.Name{CommonName: "Test StoreKit"}, NotBefore: from, NotAfter: to,
		KeyUsage:        x509.KeyUsageDigitalSignature,
		ExtraExtensions: marker(asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 6, 11, 1})}, mid, &leafKey.PublicKey, midKey)
	pool := x509.NewCertPool()
	pool.AddCert(root)
	b64 := base64.StdEncoding.EncodeToString
	return &fakeAppStore{roots: pool, key: leafKey, x5c: []string{b64(leaf.Raw), b64(mid.Raw), b64(root.Raw)}}
}

func (f *fakeAppStore) sign(t *testing.T, tx map[string]any) string {
	t.Helper()
	enc := func(v any) string {
		b, _ := json.Marshal(v)
		return base64.RawURLEncoding.EncodeToString(b)
	}
	head := enc(map[string]any{"alg": "ES256", "x5c": f.x5c})
	body := enc(tx)
	sum := sha256.Sum256([]byte(head + "." + body))
	r, s, err := ecdsa.Sign(rand.Reader, f.key, sum[:])
	if err != nil {
		t.Fatal(err)
	}
	sig := make([]byte, 64)
	r.FillBytes(sig[:32])
	s.FillBytes(sig[32:])
	return head + "." + body + "." + base64.RawURLEncoding.EncodeToString(sig)
}

func purchase(orig string, mod func(map[string]any)) map[string]any {
	tx := map[string]any{
		"transactionId": orig, "originalTransactionId": orig, "bundleId": service.AppBundleID,
		"productId": service.ProProductID, "type": "Non-Consumable", "environment": "Sandbox",
		"purchaseDate": time.Now().UnixMilli(), "signedDate": time.Now().UnixMilli(),
	}
	if mod != nil {
		mod(tx)
	}
	return tx
}

func TestVerifyPurchase(t *testing.T) {
	store := newFakeAppStore(t)
	probe := start(t, nil, false)
	e := serveWith(t, probe, nil, server.Deps{Purchases: &storekit.Verifier{
		BundleID: service.AppBundleID, ProductID: service.ProProductID, Roots: store.roots}})
	acct := pb.NewAccountServiceClient(e.conn(t))
	verify := func(tok, jws string) (*pb.Account, error) {
		return acct.VerifyPurchase(as(tok), &pb.VerifyPurchaseRequest{SignedTransaction: jws})
	}

	good := store.sign(t, purchase("2000000111", nil))
	parts := strings.Split(good, ".")
	forgedBody := base64.RawURLEncoding.EncodeToString([]byte(`{"originalTransactionId":"9","bundleId":"cn.superleo.noted","productId":"cn.superleo.noted.pro.lifetime","environment":"Production"}`))
	stranger := newFakeAppStore(t) // a well-formed chain that does not end in the pinned root
	for name, jws := range map[string]string{
		"empty":            "",
		"garbage":          "not-a-jws",
		"three dots":       "a.b.c",
		"tampered payload": parts[0] + "." + forgedBody + "." + parts[2],
		"unsigned":         parts[0] + "." + parts[1] + ".",
		"stranger's chain": stranger.sign(t, purchase("2000000222", nil)),
		"other product":    store.sign(t, purchase("2000000333", func(m map[string]any) { m["productId"] = "cn.superleo.noted.pro.yearly" })),
		"other app":        store.sign(t, purchase("2000000444", func(m map[string]any) { m["bundleId"] = "com.example.other" })),
		"refunded":         store.sign(t, purchase("2000000555", func(m map[string]any) { m["revocationDate"] = time.Now().UnixMilli() })),
		"xcode":            store.sign(t, purchase("2000000666", func(m map[string]any) { m["environment"] = "Xcode" })),
	} {
		a, err := verify(e.bob, jws)
		if code(err) != codes.InvalidArgument {
			t.Errorf("%s: %+v %v", name, a, err)
		}
	}
	if a, _ := acct.GetAccount(as(e.bob), &pb.GetAccountRequest{}); a.Pro {
		t.Fatal("a refused purchase made bob Pro")
	}

	a, err := verify(e.bob, good)
	if err != nil || !a.Pro {
		t.Fatalf("good purchase: %+v %v", a, err)
	}
	// Restoring on another device binds it to the same account again.
	if a, err := verify(e.bob, store.sign(t, purchase("2000000111", func(m map[string]any) { m["environment"] = "Production" }))); err != nil || !a.Pro {
		t.Fatalf("restore: %+v %v", a, err)
	}
	// One purchase does not unlock a second account.
	if _, err := verify(e.alice, good); code(err) != codes.PermissionDenied {
		t.Fatalf("replay onto alice: %v", err)
	}
	if a, _ := acct.GetAccount(as(e.alice), &pb.GetAccountRequest{}); a.Pro {
		t.Fatal("replay made alice Pro")
	}
	if _, err := acct.VerifyPurchase(context.Background(), &pb.VerifyPurchaseRequest{SignedTransaction: good}); code(err) != codes.Unauthenticated {
		t.Fatalf("anonymous: %v", err)
	}

	// The production verifier trusts only Apple's root.
	prod := serveWith(t, probe, nil, server.Deps{})
	if _, err := pb.NewAccountServiceClient(prod.conn(t)).VerifyPurchase(as(e.alice),
		&pb.VerifyPurchaseRequest{SignedTransaction: store.sign(t, purchase("2000000777", nil))}); code(err) != codes.InvalidArgument {
		t.Fatalf("test CA against Apple's root: %v", err)
	}
	if storekit.AppleRoots() == nil {
		t.Fatal("embedded Apple root")
	}
}
