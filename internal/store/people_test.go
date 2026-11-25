package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestPeopleUpsertMergesByName(t *testing.T) {
	ctx := context.Background()
	s, u := newStore(t)
	now := time.Now()

	if _, err := s.UpsertPerson(ctx, u, "  ", nil, "", now); !errors.Is(err, ErrInvalid) {
		t.Fatalf("no name: %v", err)
	}
	p, err := s.UpsertPerson(ctx, u, " Rene ", map[string]string{"relation": "colleague", "phone": " +43 1 234 "}, "", now)
	if err != nil || p.Name != "Rene" || p.Fields["relation"] != "colleague" || p.Fields["phone"] != "+43 1 234" || p.ID == "" {
		t.Fatalf("create: %+v %v", p, err)
	}

	// The same name in another case is the same person; fields merge, an
	// empty value removes one.
	q, err := s.UpsertPerson(ctx, u, "rene", map[string]string{"birthday": "03-14", "phone": ""}, "", now.Add(time.Minute))
	if err != nil || q.ID != p.ID || q.Name != "Rene" || q.Fields["relation"] != "colleague" || q.Fields["birthday"] != "03-14" {
		t.Fatalf("merge: %+v %v", q, err)
	}
	if _, ok := q.Fields["phone"]; ok {
		t.Fatalf("phone not removed: %+v", q.Fields)
	}
	if !q.Updated.After(q.Created) {
		t.Fatalf("updated not moved: %v %v", q.Created, q.Updated)
	}

	got, err := s.GetPerson(ctx, u, "", "RENE")
	if err != nil || got.ID != p.ID || len(got.Fields) != 2 {
		t.Fatalf("get by name: %+v %v", got, err)
	}
	if _, err := s.GetPerson(ctx, u, "", ""); !errors.Is(err, ErrInvalid) {
		t.Fatalf("get with nothing: %v", err)
	}

	// Renaming onto someone else is refused; renaming oneself works.
	if _, err := s.UpsertPerson(ctx, u, "小张", map[string]string{"relation": "朋友", "notes": "喜欢咖啡，住在上海"}, "", now); err != nil {
		t.Fatal(err)
	}
	if _, err := s.UpsertPerson(ctx, u, "Rene", nil, "小张", now); !errors.Is(err, ErrInvalid) {
		t.Fatalf("rename onto another: %v", err)
	}
	r, err := s.UpsertPerson(ctx, u, "Rene", nil, "René", now)
	if err != nil || r.ID != p.ID || r.Name != "René" {
		t.Fatalf("rename: %+v %v", r, err)
	}
	if _, err := s.GetPerson(ctx, u, "", "rene"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("old name still found: %v", err)
	}

	// Another user's people are their own.
	other, err := s.EnsureUser(ctx, "bob")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.GetPerson(ctx, other.ID, p.ID, ""); !errors.Is(err, ErrNotFound) {
		t.Fatalf("cross-user read: %v", err)
	}
}

func TestPeopleListSearchAndDelete(t *testing.T) {
	ctx := context.Background()
	s, u := newStore(t)
	now := time.Now()
	for name, f := range map[string]map[string]string{
		"Rene":  {"relation": "colleague", "city": "Vienna"},
		"Gabor": {"relation": "colleague", "city": "Budapest"},
		"小张":    {"relation": "朋友", "notes": "喜欢咖啡"},
	} {
		if _, err := s.UpsertPerson(ctx, u, name, f, "", now); err != nil {
			t.Fatal(err)
		}
	}
	all, err := s.ListPeople(ctx, u, "", 0)
	if err != nil || len(all) != 3 || all[0].Name != "Gabor" {
		t.Fatalf("all: %+v %v", all, err)
	}
	for q, want := range map[string]int{"colleague": 2, "colleague vienna": 1, "咖啡": 1, "relation": 3, "nobody": 0} {
		ps, err := s.ListPeople(ctx, u, q, 0)
		if err != nil || len(ps) != want {
			t.Errorf("query %q: %d people (%v), want %d", q, len(ps), err, want)
		}
	}
	if ps, _ := s.ListPeople(ctx, u, "", 1); len(ps) != 1 {
		t.Fatalf("limit: %d", len(ps))
	}

	if err := s.DeletePerson(ctx, u, "", "gabor"); err != nil {
		t.Fatal(err)
	}
	if err := s.DeletePerson(ctx, u, "", "gabor"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("second delete: %v", err)
	}
	if ps, _ := s.ListPeople(ctx, u, "colleague", 0); len(ps) != 1 || ps[0].Name != "Rene" {
		t.Fatalf("after delete: %+v", ps)
	}
}

func TestPeopleFieldLimits(t *testing.T) {
	ctx := context.Background()
	s, u := newStore(t)
	now := time.Now()
	if _, err := s.UpsertPerson(ctx, u, "x", map[string]string{" ": "v"}, "", now); !errors.Is(err, ErrInvalid) {
		t.Fatalf("blank key: %v", err)
	}
	long := make([]rune, maxPersonValue+1)
	for i := range long {
		long[i] = '字'
	}
	if _, err := s.UpsertPerson(ctx, u, "x", map[string]string{"notes": string(long)}, "", now); !errors.Is(err, ErrInvalid) {
		t.Fatalf("long value: %v", err)
	}
	if ps, _ := s.ListPeople(ctx, u, "", 0); len(ps) != 0 {
		t.Fatalf("a refused person was saved: %+v", ps)
	}
}
