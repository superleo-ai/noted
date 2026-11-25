package mcpserver

import (
	"context"

	pb "github.com/liliang-cn/noted/gen/noted/v1"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

type extractionPendingIn struct {
	Limit int32 `json:"limit,omitempty" jsonschema:"max notes (default 10, max 50)"`
}
type pendingNoteOut struct {
	NoteID  string `json:"note_id"`
	Hash    string `json:"hash" jsonschema:"send back unchanged with the result"`
	Title   string `json:"title"`
	Content string `json:"content" jsonschema:"trimmed to 6000 characters"`
}
type extractionPendingOut struct {
	Notes        []pendingNoteOut `json:"notes"`
	Instructions string           `json:"instructions" jsonschema:"what to extract and the JSON to answer with"`
	Remaining    int32            `json:"remaining" jsonschema:"pending notes beyond this list"`
}
type extractionSubmitIn struct {
	NoteID string `json:"note_id"`
	Hash   string `json:"hash" jsonschema:"the hash extraction_pending gave for this note"`
	Result string `json:"result" jsonschema:"the JSON object {entities, relations} as a string, as the instructions describe"`
}
type extractionSubmitOut struct {
	Status    string `json:"status" jsonschema:"stored, or stale when the note changed since the hash was made (fetch it again)"`
	Entities  int32  `json:"entities" jsonschema:"kept after cleaning"`
	Relations int32  `json:"relations" jsonschema:"kept after cleaning"`
}

// registerExtraction adds the two tools an outside reader (the person's own
// agent) uses to tell the CortexDB sync what their notes are about. They
// answer only when the server's [cortexdb] extract is "external".
func (t *tools) registerExtraction(s *mcp.Server) {
	mcp.AddTool(s, &mcp.Tool{Name: "extraction_pending", Description: "Notes whose entities have not been extracted yet, or changed since (only notes the person lets AI read), with instructions for what to extract. Read each note, then answer with extraction_submit. Works only when the server has [cortexdb] extract = \"external\".", Annotations: readOnly},
		func(ctx context.Context, _ *mcp.CallToolRequest, in extractionPendingIn) (*mcp.CallToolResult, *extractionPendingOut, error) {
			r, err := t.extract.ListPendingExtractions(ctx, &pb.ListPendingExtractionsRequest{Limit: in.Limit})
			if err != nil {
				return nil, nil, err
			}
			out := &extractionPendingOut{Notes: []pendingNoteOut{}, Instructions: r.Instructions, Remaining: r.Remaining}
			for _, n := range r.Notes {
				out.Notes = append(out.Notes, pendingNoteOut{NoteID: n.NoteId, Hash: n.Hash, Title: n.Title, Content: n.Content})
			}
			return reply(r, out)
		})
	mcp.AddTool(s, &mcp.Tool{Name: "extraction_submit", Description: "Store the entities and relations you extracted from one note. The result is validated and cleaned; it is refused as stale when the note changed since extraction_pending gave the hash.", Annotations: editing},
		func(ctx context.Context, _ *mcp.CallToolRequest, in extractionSubmitIn) (*mcp.CallToolResult, *extractionSubmitOut, error) {
			r, err := t.extract.SubmitExtraction(ctx, &pb.SubmitExtractionRequest{NoteId: in.NoteID, Hash: in.Hash, Result: in.Result})
			if err != nil {
				return nil, nil, err
			}
			return reply(r, &extractionSubmitOut{Status: r.Status, Entities: r.Entities, Relations: r.Relations})
		})
}
