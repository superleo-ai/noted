package mcpserver

import (
	"context"
	"fmt"
	"strings"

	pb "github.com/liliang-cn/noted/gen/noted/v1"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

type upsertPersonIn struct {
	Name    string            `json:"name" jsonschema:"who; matched to someone already saved ignoring case, else a new person"`
	Fields  map[string]string `json:"fields,omitempty" jsonschema:"what to remember, merged into what is there: e.g. relation (colleague/friend/家人), phone, birthday (YYYY-MM-DD or MM-DD), email, notes (preferences, recent news). Any key works; an empty value removes that field; keys not given keep their value"`
	NewName string            `json:"new_name,omitempty" jsonschema:"rename them; must not be someone else's name"`
}
type personRefIn struct {
	ID   string `json:"id,omitempty" jsonschema:"the person's id"`
	Name string `json:"name,omitempty" jsonschema:"or their name, ignoring case"`
}
type listPeopleIn struct {
	Query string `json:"query,omitempty" jsonschema:"words to look for in names, field names and values (e.g. colleague, a city); omit for everyone"`
	Limit int32  `json:"limit,omitempty" jsonschema:"max people (default 100)"`
}

type personOut struct {
	Kind       string            `json:"kind" jsonschema:"always person"`
	ID         string            `json:"id"`
	Name       string            `json:"name"`
	Fields     map[string]string `json:"fields" jsonschema:"relation, phone, birthday, notes, ..."`
	CreateTime string            `json:"createTime,omitempty"`
	UpdateTime string            `json:"updateTime,omitempty"`
}

func (t *tools) person(p *pb.Person) *personOut {
	if p == nil {
		return nil
	}
	f := p.Fields
	if f == nil {
		f = map[string]string{}
	}
	return &personOut{Kind: "person", ID: p.Id, Name: p.Name, Fields: f,
		CreateTime: t.ts(p.CreateTime), UpdateTime: t.ts(p.UpdateTime)}
}

func (in personRefIn) check() error {
	if strings.TrimSpace(in.ID) == "" && strings.TrimSpace(in.Name) == "" {
		return fmt.Errorf("give id or name")
	}
	return nil
}

// registerPeople adds the people in the person's life (人物/联系人).
func (t *tools) registerPeople(s *mcp.Server) {
	mcp.AddTool(s, &mcp.Tool{Name: "upsert_person", Description: "Remember someone in the person's life (人物/联系人): creates them, or merges into the one of that name. Save unprompted when the person mentions someone with a detail worth keeping (who they are to them, a birthday, a phone number, a preference, recent news). Fields merge; to add to notes, read get_person first and send the whole new text.", Annotations: editing},
		func(ctx context.Context, _ *mcp.CallToolRequest, in upsertPersonIn) (*mcp.CallToolResult, *personOut, error) {
			r, err := t.people.UpsertPerson(ctx, &pb.UpsertPersonRequest{Name: in.Name, Fields: in.Fields, NewName: in.NewName})
			if err != nil {
				return nil, nil, err
			}
			return reply(r, t.person(r))
		})
	mcp.AddTool(s, &mcp.Tool{Name: "get_person", Description: "Read one person by id or name (ignoring case), with everything saved about them.", Annotations: readOnly},
		func(ctx context.Context, _ *mcp.CallToolRequest, in personRefIn) (*mcp.CallToolResult, *personOut, error) {
			if err := in.check(); err != nil {
				return nil, nil, err
			}
			r, err := t.people.GetPerson(ctx, &pb.GetPersonRequest{Id: in.ID, Name: in.Name})
			if err != nil {
				return nil, nil, err
			}
			return reply(r, t.person(r))
		})
	mcp.AddTool(s, &mcp.Tool{Name: "list_people", Description: "List the people saved, by name; with query, only those whose name or fields contain every word (who is a colleague, whose birthday is in March).", Annotations: readOnly},
		func(ctx context.Context, _ *mcp.CallToolRequest, in listPeopleIn) (*mcp.CallToolResult, *listOut[*personOut], error) {
			r, err := t.people.ListPeople(ctx, &pb.ListPeopleRequest{Query: in.Query, PageSize: in.Limit})
			if err != nil {
				return nil, nil, err
			}
			return reply(r, &listOut[*personOut]{Items: items(r.People, t.person)})
		})
	mcp.AddTool(s, &mcp.Tool{Name: "delete_person", Description: "Permanently delete a person and everything saved about them, by id or name.", Annotations: deleting},
		func(ctx context.Context, _ *mcp.CallToolRequest, in personRefIn) (*mcp.CallToolResult, *deletedOut, error) {
			if err := in.check(); err != nil {
				return nil, nil, err
			}
			p, err := t.people.GetPerson(ctx, &pb.GetPersonRequest{Id: in.ID, Name: in.Name})
			if err != nil {
				return nil, nil, err
			}
			if _, err := t.people.DeletePerson(ctx, &pb.DeletePersonRequest{Id: p.Id}); err != nil {
				return nil, nil, err
			}
			return deleted("person", "person "+p.Name, p.Id)
		})
}
