package cortexsync

import (
	"context"
	"errors"
	"slices"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/liliang-cn/noted/internal/store"
)

func TestCleanExtraction(t *testing.T) {
	x := Clean(Extraction{
		Entities: []Entity{
			{Name: "  CortexDB ", Type: "Technology", Aliases: []string{"cortexdb", "Cortex", " ", "C", "Cortex"}},
			{Name: "cortexdb", Type: "product"}, // duplicate ignoring case
			{Name: "X", Type: "person"},         // one rune
			{Name: "Ollama", Type: "gadget"},    // unknown type
			{Name: "三宝", Type: "person"},
			{Name: "orange", Type: "place"},
		},
		Relations: []Relation{
			{From: "Cortex", To: "ollama", Type: "Depends On"}, // Ollama was dropped
			{From: "cortex", To: "三宝", Type: "Runs-On!"},       // alias resolves
			{From: "CortexDB", To: "CortexDB", Type: "uses"},
			{From: "cortexdb", To: "orange", Type: "mentions"},
			{From: "cortexdb", To: "orange", Type: "  "},
			{From: "cortexdb", To: "orange", Type: "mentions"},
		},
	})
	var names []string
	for _, e := range x.Entities {
		names = append(names, e.Name+"/"+e.Type)
	}
	if !slices.Equal(names, []string{"CortexDB/technology", "三宝/person", "orange/place"}) {
		t.Fatalf("entities %v", names)
	}
	if a := x.Entities[0].Aliases; !slices.Equal(a, []string{"Cortex"}) {
		t.Errorf("aliases %v", a)
	}
	var rels []string
	for _, r := range x.Relations {
		rels = append(rels, r.From+" "+r.Type+" "+r.To)
	}
	if !slices.Equal(rels, []string{"CortexDB runs_on 三宝", "CortexDB related_to orange"}) {
		t.Errorf("relations %v", rels)
	}
	many := Extraction{}
	for i := 0; i < 40; i++ {
		many.Entities = append(many.Entities, Entity{Name: "thing" + string(rune('a'+i%26)) + string(rune('a'+i/26)), Type: "concept"})
	}
	if n := len(Clean(many).Entities); n != maxEntities {
		t.Errorf("kept %d entities", n)
	}
}

func TestParseExtraction(t *testing.T) {
	x, err := ParseExtraction("Here:\n```json\n{\"entities\":[{\"name\":\"Ollama\",\"type\":\"technology\"}],\"relations\":[]}\n```")
	if err != nil || len(x.Entities) != 1 {
		t.Fatalf("%+v %v", x, err)
	}
	if _, err := ParseExtraction("no json"); err == nil {
		t.Error("text without JSON must fail")
	}
	if _, err := ParseExtraction("{\"entities\": 3}"); err == nil {
		t.Error("malformed JSON must fail")
	}
}

func canned() map[string]Extraction {
	return map[string]Extraction{
		"n1": {
			Entities: []Entity{
				{Name: "CortexDB", Type: "technology"},
				{Name: "Ollama", Type: "technology", Aliases: []string{"ollama server"}},
				{Name: "三宝", Type: "person"},
				{Name: "Liang", Type: "person", Aliases: []string{"liang li"}}, // not a noted person
			},
			Relations: []Relation{{From: "CortexDB", To: "Ollama", Type: "depends_on"}, {From: "三宝", To: "CortexDB", Type: "uses"}},
		},
		"n2": {Entities: []Entity{{Name: "  cortexdb ", Type: "technology"}}},
	}
}

func TestProjectionOfExtractions(t *testing.T) {
	s := Snapshot{
		User: "u", Location: shanghai(t), Lang: "en",
		People:      []store.Person{{ID: "p1", Name: "三宝"}},
		Notes:       []store.Note{{ID: "n1", Title: "Embeddings", Content: "CortexDB uses Ollama; 三宝 asked."}, {ID: "n2", Title: "Other", Content: "more"}, {ID: "n3", Title: "Plain", Content: "none"}},
		Extractions: canned(),
	}
	// n2's entity names are cleaned on the way in; mimic the stored shape.
	x := s.Extractions["n2"]
	x.Entities[0].Name = "cortexdb"
	s.Extractions["n2"] = x
	out := Project(s)
	items := map[string]Item{}
	for _, it := range out.Items {
		items[it.Key] = it
	}
	cortex := TopicID("u", "technology", "CortexDB")
	if cortex != "entity:noted:u:topic:technology:cortexdb" {
		t.Fatalf("topic id %q", cortex)
	}
	n1, n2 := items["note:n1"], items["note:n2"]
	about := func(it Item) []string {
		var to []string
		for _, r := range it.Save.Relations {
			if r.Type == RelAbout {
				to = append(to, r.To)
			}
		}
		slices.Sort(to)
		return to
	}
	want1 := []string{cortex, TopicID("u", "person", "Liang"), TopicID("u", "technology", "Ollama"), EntityID("u", "person:p1")}
	slices.Sort(want1)
	if got := about(n1); !slices.Equal(got, want1) {
		t.Errorf("n1 about %v want %v", got, want1)
	}
	if got := about(n2); !slices.Equal(got, []string{cortex}) {
		t.Errorf("two notes must share one topic node: n2 about %v", got)
	}
	if got := about(items["note:n3"]); len(got) != 0 {
		t.Errorf("n3 about %v", got)
	}
	var topic bool
	for _, e := range n1.Save.Entities {
		if e.ID == TopicID("u", "technology", "Ollama") {
			topic = e.Type == "noted_topic_technology" && e.Name == "Ollama" && e.Metadata["source"] == "noted" && e.Metadata["aliases"] == "ollama server"
		}
		if e.ID == TopicID("u", "person", "三宝") {
			t.Error("a noted person must not also get a topic node")
		}
	}
	if !topic {
		t.Error("Ollama topic node missing or wrong")
	}
	var dep, uses bool
	for _, r := range n1.Save.Relations {
		if r.Type == "depends_on" && r.From == cortex && r.To == TopicID("u", "technology", "Ollama") && r.Metadata["from_note"] == "note:n1" {
			dep = true
		}
		if r.Type == "uses" && r.From == EntityID("u", "person:p1") && r.To == cortex {
			uses = true
		}
	}
	if !dep || !uses {
		t.Errorf("entity edges: depends_on %v uses(person) %v", dep, uses)
	}
	if !slices.ContainsFunc(n1.Targets, func(k string) bool { return k == "person:p1" }) {
		t.Errorf("the person's entity must travel with the note: %v", n1.Targets)
	}
	if !strings.Contains(n1.Save.Content, "Topics: CortexDB, Ollama, 三宝, Liang") {
		t.Errorf("content lacks the topics line: %q", n1.Save.Content)
	}
	// The extraction is part of the hash: without it the note hashes differently.
	s.Extractions = nil
	for _, it := range Project(s).Items {
		if it.Key == "note:n1" && it.Hash == n1.Hash {
			t.Error("the record hash ignores the extraction")
		}
	}
}

type fakeExtractor struct {
	calls atomic.Int32
	res   Extraction
	err   error
}

func (f *fakeExtractor) Extract(ctx context.Context, title, content string) (Extraction, error) {
	f.calls.Add(1)
	return f.res, f.err
}

func TestExtractionCache(t *testing.T) {
	e := newEnv(t)
	fx := &fakeExtractor{res: Extraction{Entities: []Entity{{Name: "Ollama", Type: "technology"}}}}
	e.sync.Extract, e.sync.Extractor = true, fx
	n, err := e.st.CreateNote(e.ctx, store.Note{UserID: e.uid, Title: "Embeddings", Content: "Moved Ollama to orange"})
	if err != nil {
		t.Fatal(err)
	}
	rep := e.run(t, Options{})
	if fx.calls.Load() != 1 || rep.Extracted != 1 {
		t.Fatalf("first run: %d calls, %+v", fx.calls.Load(), rep)
	}
	if !slices.ContainsFunc(e.edges(t, "note:"+n.ID), func(s string) bool {
		return strings.HasPrefix(s, "about ") && strings.HasSuffix(s, "topic:technology:ollama")
	}) {
		t.Errorf("no about edge to the topic: %v", e.edges(t, "note:"+n.ID))
	}
	rep = e.run(t, Options{Full: true})
	if fx.calls.Load() != 1 || rep.Extracted != 0 {
		t.Fatalf("unchanged text must not be read again: %d calls", fx.calls.Load())
	}
	// Changed text is read again; a failure keeps the old result and retries.
	nc := "Moved Ollama and CortexDB to orange"
	if _, err := e.st.UpdateNote(e.ctx, e.uid, n.ID, store.NotePatch{Content: &nc}); err != nil {
		t.Fatal(err)
	}
	fx.err = errors.New("model down")
	rep = e.run(t, Options{})
	if fx.calls.Load() != 2 || rep.ExtractFailed != 1 || rep.Extracted != 0 {
		t.Fatalf("failed run: %d calls %+v", fx.calls.Load(), rep)
	}
	got, _ := e.st.CortexExtractions(e.ctx, e.uid)
	if !strings.Contains(got[n.ID].Result, "Ollama") || got[n.ID].Hash != TextHash("Embeddings", "Moved Ollama to orange") {
		t.Fatalf("the old result must stay: %+v", got[n.ID])
	}
	fx.err = nil
	fx.res = Extraction{Entities: []Entity{{Name: "CortexDB", Type: "technology"}}}
	e.run(t, Options{})
	if fx.calls.Load() != 3 {
		t.Fatalf("retry: %d calls", fx.calls.Load())
	}
	got, _ = e.st.CortexExtractions(e.ctx, e.uid)
	if got[n.ID].Hash != TextHash("Embeddings", nc) || !strings.Contains(got[n.ID].Result, "CortexDB") {
		t.Fatalf("new result not stored: %+v", got[n.ID])
	}
	// A deleted note's row goes away.
	if err := e.st.DeleteNote(e.ctx, e.uid, n.ID); err != nil {
		t.Fatal(err)
	}
	e.run(t, Options{})
	if got, _ = e.st.CortexExtractions(e.ctx, e.uid); len(got) != 0 {
		t.Fatalf("rows left: %v", got)
	}
}

func TestExtractionPerRunCapAndDryRun(t *testing.T) {
	e := newEnv(t)
	fx := &fakeExtractor{}
	e.sync.Extract, e.sync.Extractor, e.sync.PerRun = true, fx, 2
	for i := 0; i < 5; i++ {
		if _, err := e.st.CreateNote(e.ctx, store.Note{UserID: e.uid, Title: "Note " + string(rune('a'+i)), Content: "some text about things"}); err != nil {
			t.Fatal(err)
		}
	}
	e.run(t, Options{DryRun: true})
	if fx.calls.Load() != 0 {
		t.Fatal("a dry run must not call the model")
	}
	e.run(t, Options{})
	e.run(t, Options{})
	if fx.calls.Load() != 4 {
		t.Fatalf("2 per run over two runs: %d calls", fx.calls.Load())
	}
	e.run(t, Options{})
	e.run(t, Options{})
	if fx.calls.Load() != 5 {
		t.Fatalf("all five read once: %d calls", fx.calls.Load())
	}
}

func TestExternalPendingAndSubmit(t *testing.T) {
	e := newEnv(t)
	work, _ := e.st.CreateNote(e.ctx, store.Note{UserID: e.uid, Title: "Work note", Content: "CortexDB runs on orange", Space: store.SpaceWork})
	life, _ := e.st.CreateNote(e.ctx, store.Note{UserID: e.uid, Title: "Life note", Content: "三宝 swims on Saturday", Space: store.SpaceLife})
	if _, err := e.st.CreateNote(e.ctx, store.Note{UserID: e.uid, Title: "hi", Content: "x"}); err != nil {
		t.Fatal(err) // too short to read
	}
	ps, more, err := PendingNotes(e.ctx, e.st, e.uid, 10)
	if err != nil || len(ps) != 2 || more != 0 {
		t.Fatalf("pending %d more %d %v", len(ps), more, err)
	}
	if _, more, _ = PendingNotes(e.ctx, e.st, e.uid, 1); more != 1 {
		t.Errorf("more = %d", more)
	}
	var wh string
	for _, p := range ps {
		if p.Note.ID == work.ID {
			wh = p.Hash
		}
	}
	res := `{"entities":[{"name":"CortexDB","type":"technology"},{"name":"orange","type":"place"}],"relations":[{"from":"CortexDB","to":"orange","type":"runs_on"}]}`
	if ok, x, err := Submit(e.ctx, e.st, e.uid, work.ID, "stale-hash", res); err != nil || ok || len(x.Entities) != 2 {
		t.Fatalf("stale hash must be refused: %v %v", ok, err)
	}
	if got, _ := e.st.CortexExtractions(e.ctx, e.uid); len(got) != 0 {
		t.Fatal("a stale submit stored something")
	}
	if ok, x, err := Submit(e.ctx, e.st, e.uid, work.ID, wh, res); err != nil || !ok || len(x.Relations) != 1 {
		t.Fatalf("submit: %v %+v %v", ok, x, err)
	}
	if _, _, err := Submit(e.ctx, e.st, e.uid, work.ID, wh, "garbage"); err == nil {
		t.Error("an unreadable result must be an error")
	}
	if ps, _, _ = PendingNotes(e.ctx, e.st, e.uid, 10); len(ps) != 1 || ps[0].Note.ID != life.ID {
		t.Fatalf("only the unread note is pending: %+v", ps)
	}
	// A change makes it pending again, and the old hash is now stale.
	nc := "CortexDB runs on orange and hp"
	if _, err := e.st.UpdateNote(e.ctx, e.uid, work.ID, store.NotePatch{Content: &nc}); err != nil {
		t.Fatal(err)
	}
	if ps, _, _ = PendingNotes(e.ctx, e.st, e.uid, 10); len(ps) != 2 {
		t.Fatalf("changed note pending again: %d", len(ps))
	}
	if ok, _, _ := Submit(e.ctx, e.st, e.uid, work.ID, wh, res); ok {
		t.Fatal("the hash of the old text must be refused")
	}
	// Closing work to AI hides it from the list and from submit.
	if _, err := e.st.SetAIAccess(e.ctx, e.uid, false, true); err != nil {
		t.Fatal(err)
	}
	if ps, _, _ = PendingNotes(e.ctx, e.st, e.uid, 10); len(ps) != 1 || ps[0].Note.ID != life.ID {
		t.Fatalf("a closed space must not be listed: %+v", ps)
	}
	if ok, _, _ := Submit(e.ctx, e.st, e.uid, work.ID, TextHash("Work note", nc), res); ok {
		t.Fatal("submit into a closed space")
	}

	// A stored result reaches the projection through a sync run, without any extractor.
	if _, err := e.st.SetAIAccess(e.ctx, e.uid, true, true); err != nil {
		t.Fatal(err)
	}
	if ok, _, err := Submit(e.ctx, e.st, e.uid, work.ID, TextHash("Work note", nc), res); err != nil || !ok {
		t.Fatal(ok, err)
	}
	e.sync.Extract = true
	e.run(t, Options{})
	if !slices.ContainsFunc(e.edges(t, "note:"+work.ID), func(s string) bool { return strings.HasSuffix(s, "topic:place:orange") }) {
		t.Errorf("submitted result not in the graph: %v", e.edges(t, "note:"+work.ID))
	}
}
