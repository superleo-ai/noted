package server_test

import (
	"testing"

	pb "github.com/liliang-cn/noted/gen/noted/v1"
	"google.golang.org/grpc/codes"
)

func TestPeopleOverGRPC(t *testing.T) {
	e := start(t, nil, false)
	ppl := pb.NewPeopleServiceClient(e.conn(t))
	ctx := as(e.alice)

	if _, err := ppl.UpsertPerson(ctx, &pb.UpsertPersonRequest{}); code(err) != codes.InvalidArgument {
		t.Fatalf("no name: %v", err)
	}
	p, err := ppl.UpsertPerson(ctx, &pb.UpsertPersonRequest{Name: "Rene", Fields: map[string]string{"relation": "colleague"}})
	if err != nil || p.Id == "" || p.Fields["relation"] != "colleague" || p.CreateTime == nil {
		t.Fatalf("create: %+v %v", p, err)
	}
	p, err = ppl.UpsertPerson(ctx, &pb.UpsertPersonRequest{Name: "rene", Fields: map[string]string{"birthday": "03-14"}})
	if err != nil || len(p.Fields) != 2 {
		t.Fatalf("merge: %+v %v", p, err)
	}
	if g, err := ppl.GetPerson(ctx, &pb.GetPersonRequest{Id: p.Id}); err != nil || g.Name != "Rene" {
		t.Fatalf("get: %+v %v", g, err)
	}
	if l, err := ppl.ListPeople(ctx, &pb.ListPeopleRequest{Query: "colleague"}); err != nil || len(l.People) != 1 {
		t.Fatalf("list: %+v %v", l, err)
	}

	// Bob sees none of Alice's people.
	if _, err := ppl.GetPerson(as(e.bob), &pb.GetPersonRequest{Id: p.Id}); code(err) != codes.NotFound {
		t.Fatalf("bob get: %v", err)
	}
	if l, _ := ppl.ListPeople(as(e.bob), &pb.ListPeopleRequest{}); len(l.GetPeople()) != 0 {
		t.Fatalf("bob list: %+v", l)
	}
	if _, err := ppl.DeletePerson(as(e.bob), &pb.DeletePersonRequest{Id: p.Id}); code(err) != codes.NotFound {
		t.Fatalf("bob delete: %v", err)
	}

	if _, err := ppl.DeletePerson(ctx, &pb.DeletePersonRequest{Name: "RENE"}); err != nil {
		t.Fatal(err)
	}
	if _, err := ppl.GetPerson(ctx, &pb.GetPersonRequest{Id: p.Id}); code(err) != codes.NotFound {
		t.Fatalf("after delete: %v", err)
	}
}

func TestMCPPeople(t *testing.T) {
	e := start(t, nil, false)
	cs := mcpSession(t, e, e.alice)

	_, sc, isErr := callS(t, cs, "upsert_person", map[string]any{"name": "小张", "fields": map[string]any{"relation": "朋友", "phone": "138"}})
	if isErr || sc["kind"] != "person" || sc["name"] != "小张" {
		t.Fatalf("upsert: %v", sc)
	}
	id, _ := sc["id"].(string)
	_, sc, isErr = callS(t, cs, "upsert_person", map[string]any{"name": "小张", "fields": map[string]any{"phone": "", "notes": "喜欢咖啡"}})
	f, _ := sc["fields"].(map[string]any)
	if isErr || sc["id"] != id || f["relation"] != "朋友" || f["notes"] != "喜欢咖啡" || f["phone"] != nil {
		t.Fatalf("merge: %v", sc)
	}

	if _, isErr := call(t, cs, "get_person", map[string]any{}); !isErr {
		t.Fatal("get_person with nothing should fail")
	}
	if _, sc, isErr = callS(t, cs, "get_person", map[string]any{"name": "小张"}); isErr || sc["id"] != id {
		t.Fatalf("get: %v", sc)
	}
	_, sc, isErr = callS(t, cs, "list_people", map[string]any{"query": "咖啡"})
	if its, _ := sc["items"].([]any); isErr || len(its) != 1 {
		t.Fatalf("list: %v", sc)
	}
	_, sc, isErr = callS(t, cs, "delete_person", map[string]any{"name": "小张"})
	if isErr || sc["deleted"] != id || sc["kind"] != "person" {
		t.Fatalf("delete: %v", sc)
	}
	if _, isErr := call(t, cs, "get_person", map[string]any{"id": id}); !isErr {
		t.Fatal("deleted person still found")
	}
}
