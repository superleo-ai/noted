package service

import (
	"context"
	"slices"
	"strings"
	"unicode/utf8"

	pb "github.com/liliang-cn/noted/gen/noted/v1"
	"github.com/liliang-cn/noted/internal/auth"
	"github.com/liliang-cn/noted/internal/cortexsync"
	"github.com/liliang-cn/noted/internal/store"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// Extraction lets an outside reader feed the CortexDB sync with what notes
// are about. Users names who may be read (the sync users, with extract
// "external"); empty means nobody, and every call is refused.
type Extraction struct {
	pb.UnimplementedExtractionServiceServer
	Store *store.Store
	Users []string
}

const (
	defaultPending = 10
	maxPending     = 50
)

func (s *Extraction) allowed(ctx context.Context) (string, error) {
	u, ok := auth.User(ctx)
	if !ok {
		return "", status.Error(codes.Unauthenticated, "not authenticated")
	}
	if !slices.Contains(s.Users, u.Name) {
		return "", status.Error(codes.FailedPrecondition, "extraction is not on for this user: set [cortexdb] extract = \"external\" and list the user in sync_users")
	}
	return u.ID, nil
}

func (s *Extraction) ListPendingExtractions(ctx context.Context, req *pb.ListPendingExtractionsRequest) (*pb.ListPendingExtractionsResponse, error) {
	u, err := s.allowed(ctx)
	if err != nil {
		return nil, err
	}
	limit := int(req.GetLimit())
	if limit <= 0 {
		limit = defaultPending
	}
	if limit > maxPending {
		limit = maxPending
	}
	ps, more, err := cortexsync.PendingNotes(ctx, s.Store, u, limit)
	if err != nil {
		return nil, toStatus(err)
	}
	out := &pb.ListPendingExtractionsResponse{Instructions: cortexsync.ExtractionPrompt + "\n\nSubmit one answer per note with extraction_submit(note_id, hash, result); result is the JSON object as a string.", Remaining: int32(more)}
	for _, p := range ps {
		c := strings.TrimSpace(p.Note.Content)
		if utf8.RuneCountInString(c) > cortexsync.MaxExtractText {
			c = string([]rune(c)[:cortexsync.MaxExtractText])
		}
		out.Notes = append(out.Notes, &pb.PendingExtraction{NoteId: p.Note.ID, Hash: p.Hash, Title: p.Note.Title, Content: c})
	}
	return out, nil
}

func (s *Extraction) SubmitExtraction(ctx context.Context, req *pb.SubmitExtractionRequest) (*pb.SubmitExtractionResponse, error) {
	u, err := s.allowed(ctx)
	if err != nil {
		return nil, err
	}
	if req.GetNoteId() == "" || req.GetHash() == "" {
		return nil, status.Error(codes.InvalidArgument, "note_id and hash are required")
	}
	ok, x, err := cortexsync.Submit(ctx, s.Store, u, req.GetNoteId(), req.GetHash(), req.GetResult())
	if err != nil {
		if strings.Contains(err.Error(), "the model") { // unreadable answer
			return nil, status.Error(codes.InvalidArgument, strings.ReplaceAll(err.Error(), "the model", "the result"))
		}
		return nil, toStatus(err)
	}
	if !ok {
		return &pb.SubmitExtractionResponse{Status: "stale"}, nil
	}
	return &pb.SubmitExtractionResponse{Status: "stored", Entities: int32(len(x.Entities)), Relations: int32(len(x.Relations))}, nil
}
