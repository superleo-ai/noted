package cortexsync

import (
	"strings"
	"testing"

	"github.com/liliang-cn/noted/internal/store"
)

func TestPeopleAreEntitiesItemsInvolve(t *testing.T) {
	s := Snapshot{
		User: "u", Location: shanghai(t), Lang: "zh",
		People: []store.Person{
			{ID: "p1", Name: "三宝", Fields: map[string]string{"关系": "儿子", "生日": "2018-05-01"}, Updated: at("2026-11-20T01:00:00Z")},
			{ID: "p2", Name: "三宝妈", Fields: map[string]string{"关系": "妻子"}},
			{ID: "p3", Name: "A"},
		},
		Tasks: []store.Task{{ID: "t1", Title: "给三宝报名游泳课"}, {ID: "t2", Title: "和三宝妈商量周末"}, {ID: "t3", Title: "Buy milk"}},
	}
	out := Project(s)
	byKey := map[string]Item{}
	for _, it := range out.Items {
		byKey[it.Key] = it
	}
	p, ok := byKey["person:p1"]
	if !ok {
		t.Fatal("person p1 not projected")
	}
	if !strings.Contains(p.Save.Content, "关系：儿子") || !strings.Contains(p.Save.Content, "生日：2018-05-01") {
		t.Errorf("person content = %q", p.Save.Content)
	}
	involves := func(k string) []string {
		var to []string
		for _, r := range byKey[k].Save.Relations {
			if r.Type == RelInvolves {
				to = append(to, r.To)
			}
		}
		return to
	}
	if got := involves("task:t1"); len(got) != 1 || got[0] != EntityID("u", "person:p1") {
		t.Errorf("t1 involves %v, want only 三宝", got)
	}
	if got := involves("task:t2"); len(got) != 1 || got[0] != EntityID("u", "person:p2") {
		t.Errorf("t2 involves %v, want only 三宝妈, not 三宝 inside it", got)
	}
	if got := involves("task:t3"); len(got) != 0 {
		t.Errorf("t3 involves %v, want none (one-letter names are not matched)", got)
	}
}
