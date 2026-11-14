package service

import (
	"context"
	"errors"
	"log/slog"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"
	pb "github.com/liliang-cn/noted/gen/noted/v1"
	"github.com/liliang-cn/noted/internal/ai"
	"github.com/liliang-cn/noted/internal/apple"
	"github.com/liliang-cn/noted/internal/auth"
	"github.com/liliang-cn/noted/internal/store"
	"github.com/liliang-cn/noted/internal/storekit"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/emptypb"
	"google.golang.org/protobuf/types/known/timestamppb"
)

// Account is how a person gets into the server without pasting a token.
type Account struct {
	pb.UnimplementedAccountServiceServer
	Store  *store.Store
	Apple  *apple.Verifier // nil: Sign in with Apple is off
	Signup bool            // an unknown Apple ID creates a user instead of being refused
	// EmailSignup lets anyone create a user with an email + password (SignUp).
	EmailSignup bool
	Guard       *Guard // sign-in lockout; share one between the gRPC API and the web portal
	// PasswordCost is the bcrypt cost of new password hashes; 0 means 12.
	PasswordCost int
	Purchases    *storekit.Verifier // VerifyPurchase; nil: Apple roots, noted's bundle and product
	// Engine, when set, has its semantic index cleared of a deleted user's
	// notes, and its assistant conversations with them dropped when it can
	// (ForgetUser, as ai.Agent has).
	Engine ai.Engine
	// Brain, when set, takes what the CortexDB sync sent for a deleted user
	// out of the brain (cortexsync.Syncer).
	Brain Forgetter
}

// Forgetter removes what was copied out of the database for a user.
type Forgetter interface {
	Forget(ctx context.Context, userID, name string) error
}

// DeleteConfirm is the word DeleteAccount must be sent, so a stray call
// cannot delete an account.
const DeleteConfirm = "DELETE"

// DeleteAccount deletes the caller's user and everything they own. The
// token making the call, and every other, stops working.
//
// Apple: Sign in with Apple is only verified here (identity tokens); the
// server keeps no Apple refresh token and has no client secret, so there is
// nothing to send to appleid.apple.com/auth/revoke. The link is dropped with
// the user, and the person can remove the app under their Apple ID's
// "Sign in with Apple" settings.
func (s *Account) DeleteAccount(ctx context.Context, req *pb.DeleteAccountRequest) (*emptypb.Empty, error) {
	u, ok := auth.User(ctx)
	if !ok {
		return nil, status.Error(codes.Unauthenticated, "not authenticated")
	}
	if req.GetConfirm() != DeleteConfirm {
		return nil, status.Errorf(codes.InvalidArgument, "confirm must be %q", DeleteConfirm)
	}
	if auth.TokenID(ctx) == "" {
		// Auth is off: every caller is the one built-in user, and deleting it
		// would pull the floor out from under the server.
		return nil, status.Error(codes.FailedPrecondition, "accounts cannot be deleted while auth is disabled")
	}
	// The rest of the work must not stop halfway because the caller hung up.
	bg := context.WithoutCancel(ctx)
	if s.Brain != nil {
		fctx, cancel := context.WithTimeout(bg, 2*time.Minute)
		if err := s.Brain.Forget(fctx, u.ID, u.Name); err != nil {
			slog.Warn("delete account: cortexdb items left behind", "user", u.ID, "err", err)
		}
		cancel()
	}
	gone, err := s.Store.DeleteUser(bg, u.ID)
	if errors.Is(err, store.ErrNotFound) {
		return nil, status.Error(codes.Unauthenticated, "not authenticated")
	}
	if err != nil {
		return nil, toStatus(err)
	}
	if s.Engine != nil {
		for _, id := range gone.NoteIDs {
			if err := s.Engine.RemoveNote(bg, u.ID, id); err != nil {
				slog.Warn("delete account: note left in the semantic index", "user", u.ID, "note", id, "err", err)
			}
		}
		if f, ok := s.Engine.(interface {
			ForgetUser(ctx context.Context, userID string) error
		}); ok {
			if err := f.ForgetUser(bg, u.ID); err != nil {
				slog.Warn("delete account: assistant conversations left behind", "user", u.ID, "err", err)
			}
		}
	}
	slog.Info("account deleted", "user", u.ID, "notes", len(gone.NoteIDs), "apple_linked", gone.AppleSub != "")
	return &emptypb.Empty{}, nil
}

func (s *Account) verify(ctx context.Context, token, nonce string) (apple.Identity, error) {
	if s.Apple == nil {
		return apple.Identity{}, status.Error(codes.FailedPrecondition, "Sign in with Apple is not enabled on this server")
	}
	id, err := s.Apple.Verify(ctx, token, nonce)
	if err != nil {
		slog.Warn("apple sign-in refused", "err", err)
		return apple.Identity{}, status.Error(codes.Unauthenticated, "Apple sign-in could not be verified: "+err.Error())
	}
	return id, nil
}

func (s *Account) SignInWithApple(ctx context.Context, req *pb.SignInWithAppleRequest) (*pb.SignInWithAppleResponse, error) {
	id, err := s.verify(ctx, req.GetIdentityToken(), req.GetNonce())
	if err != nil {
		return nil, err
	}
	u, err := s.Store.UserForApple(ctx, id.Sub)
	if errors.Is(err, store.ErrNotFound) {
		if !s.Signup {
			return nil, status.Error(codes.FailedPrecondition,
				"this Apple ID is not linked to a user. Connect once with a token, then link it in Settings")
		}
		name := "apple-" + strings.ReplaceAll(uuid.NewString(), "-", "")[:8]
		if u, err = s.Store.EnsureUser(ctx, name); err == nil {
			err = s.Store.LinkApple(ctx, u.ID, id.Sub)
		}
	}
	if err != nil {
		return nil, toStatus(err)
	}
	label := strings.TrimSpace(req.GetDeviceLabel())
	if label == "" {
		label = "Sign in with Apple"
	}
	tok, err := s.Store.CreateToken(ctx, u.ID, label)
	if err != nil {
		return nil, toStatus(err)
	}
	return &pb.SignInWithAppleResponse{Token: tok, UserName: u.Name}, nil
}

func (s *Account) account(ctx context.Context) (*pb.Account, error) {
	u, ok := auth.User(ctx)
	if !ok {
		return nil, status.Error(codes.Unauthenticated, "not authenticated")
	}
	linked, err := s.Store.AppleLinked(ctx, u.ID)
	if err != nil {
		return nil, toStatus(err)
	}
	pro, err := s.Store.UserPro(ctx, u.ID)
	if err != nil {
		return nil, toStatus(err)
	}
	email, _, err := s.Store.UserEmail(ctx, u.ID)
	if err != nil && !errors.Is(err, store.ErrNotFound) {
		return nil, toStatus(err)
	}
	return &pb.Account{UserName: u.Name, AppleEnabled: s.Apple != nil, AppleLinked: linked, Pro: pro, Email: email}, nil
}

func (s *Account) GetAccount(ctx context.Context, _ *pb.GetAccountRequest) (*pb.Account, error) {
	return s.account(ctx)
}

func (s *Account) LinkApple(ctx context.Context, req *pb.LinkAppleRequest) (*pb.Account, error) {
	u, ok := auth.User(ctx)
	if !ok {
		return nil, status.Error(codes.Unauthenticated, "not authenticated")
	}
	id, err := s.verify(ctx, req.GetIdentityToken(), req.GetNonce())
	if err != nil {
		return nil, err
	}
	if err := s.Store.LinkApple(ctx, u.ID, id.Sub); err != nil {
		return nil, toStatus(err)
	}
	return s.account(ctx)
}

func (s *Account) UnlinkApple(ctx context.Context, _ *pb.UnlinkAppleRequest) (*pb.Account, error) {
	u, ok := auth.User(ctx)
	if !ok {
		return nil, status.Error(codes.Unauthenticated, "not authenticated")
	}
	if err := s.Store.UnlinkApple(ctx, u.ID); err != nil {
		return nil, toStatus(err)
	}
	return s.account(ctx)
}

// DefaultTokenLabel names a token created without a label.
const DefaultTokenLabel = "AI 助手"

const maxTokenLabel = 60

// tokenLabel trims a token label, applies the default and checks the length.
func tokenLabel(raw, def string) (string, error) {
	label := strings.TrimSpace(raw)
	if label == "" {
		label = def
	}
	if utf8.RuneCountInString(label) > maxTokenLabel {
		return "", status.Errorf(codes.InvalidArgument, "label is longer than %d characters", maxTokenLabel)
	}
	return label, nil
}

func tokenInfo(t store.Token, current string) *pb.TokenInfo {
	ti := &pb.TokenInfo{Id: t.ID, Label: t.Label, CreateTime: timestamppb.New(t.Created), Current: t.ID == current}
	if !t.LastUsed.IsZero() {
		ti.LastUsedTime = timestamppb.New(t.LastUsed)
	}
	return ti
}

func (s *Account) CreateToken(ctx context.Context, req *pb.CreateTokenRequest) (*pb.CreateTokenResponse, error) {
	u, ok := auth.User(ctx)
	if !ok {
		return nil, status.Error(codes.Unauthenticated, "not authenticated")
	}
	label, err := tokenLabel(req.GetLabel(), DefaultTokenLabel)
	if err != nil {
		return nil, err
	}
	tok, t, err := s.Store.NewToken(ctx, u.ID, label)
	if err != nil {
		return nil, toStatus(err)
	}
	return &pb.CreateTokenResponse{Token: tok, Info: tokenInfo(t, auth.TokenID(ctx))}, nil
}

func (s *Account) ListTokens(ctx context.Context, _ *pb.ListTokensRequest) (*pb.ListTokensResponse, error) {
	u, ok := auth.User(ctx)
	if !ok {
		return nil, status.Error(codes.Unauthenticated, "not authenticated")
	}
	ts, err := s.Store.ListTokens(ctx, u.ID)
	if err != nil {
		return nil, toStatus(err)
	}
	cur := auth.TokenID(ctx)
	out := &pb.ListTokensResponse{Tokens: make([]*pb.TokenInfo, 0, len(ts))}
	for _, t := range ts {
		out.Tokens = append(out.Tokens, tokenInfo(t, cur))
	}
	return out, nil
}

func (s *Account) RevokeToken(ctx context.Context, req *pb.RevokeTokenRequest) (*emptypb.Empty, error) {
	u, ok := auth.User(ctx)
	if !ok {
		return nil, status.Error(codes.Unauthenticated, "not authenticated")
	}
	if strings.TrimSpace(req.GetId()) == "" {
		return nil, status.Error(codes.InvalidArgument, "id is required")
	}
	if err := s.Store.RevokeToken(ctx, u.ID, req.GetId()); err != nil {
		return nil, toStatus(err)
	}
	return &emptypb.Empty{}, nil
}

// Pairing approves an MCP client's browser sign-in from the App. A code is
// eight characters out of 31; failed lookups count against the caller like
// failed sign-ins, so codes cannot be guessed at any useful rate.
const tooManyPairings = "too many wrong pairing codes; try again in 10 minutes"

// NormalizePairingCode uppercases a code and drops spaces and dashes.
func NormalizePairingCode(raw string) string {
	return strings.Map(func(r rune) rune {
		switch {
		case r == ' ' || r == '-' || r == '\t':
			return -1
		case r >= 'a' && r <= 'z':
			return r - 'a' + 'A'
		}
		return r
	}, raw)
}

func pairingKeys(userID, ip string) []string {
	ks := []string{"pair-user:" + userID}
	if ip != "" {
		ks = append(ks, "pair-ip:"+ip)
	}
	return ks
}

// livePairing finds a pairing the caller may act on, counting a miss as a
// failed attempt.
func (s *Account) livePairing(ctx context.Context, raw string) (store.User, store.Pairing, error) {
	u, ok := auth.User(ctx)
	if !ok {
		return store.User{}, store.Pairing{}, status.Error(codes.Unauthenticated, "not authenticated")
	}
	code := NormalizePairingCode(raw)
	if code == "" {
		return u, store.Pairing{}, status.Error(codes.InvalidArgument, "code is required")
	}
	keys := pairingKeys(u.ID, ClientIP(ctx))
	g := s.guard()
	if g.Locked(keys...) {
		return u, store.Pairing{}, status.Error(codes.ResourceExhausted, tooManyPairings)
	}
	p, err := s.Store.LivePairing(ctx, code, u.ID)
	if errors.Is(err, store.ErrNotFound) {
		g.Fail(keys...)
		return u, store.Pairing{}, status.Error(codes.NotFound, "no such pairing code, or it has expired")
	}
	if err != nil {
		return u, store.Pairing{}, toStatus(err)
	}
	g.Reset(keys[0])
	return u, p, nil
}

func pairingProto(p store.Pairing) *pb.Pairing {
	return &pb.Pairing{
		Code: p.Code, ClientName: p.ClientName, Approved: p.UserID != "",
		CreateTime: timestamppb.New(p.Created), ExpireTime: timestamppb.New(p.Expires),
	}
}

func (s *Account) GetPairing(ctx context.Context, req *pb.GetPairingRequest) (*pb.Pairing, error) {
	_, p, err := s.livePairing(ctx, req.GetCode())
	if err != nil {
		return nil, err
	}
	return pairingProto(p), nil
}

// ApprovePairing binds the pairing to the caller. Its token is minted only
// when the client redeems the authorization code, so a sign-in that is
// approved but never completed leaves no token behind.
func (s *Account) ApprovePairing(ctx context.Context, req *pb.ApprovePairingRequest) (*pb.Pairing, error) {
	u, p, err := s.livePairing(ctx, req.GetCode())
	if err != nil {
		return nil, err
	}
	def := p.ClientName
	if utf8.RuneCountInString(def) > maxTokenLabel {
		def = string([]rune(def)[:maxTokenLabel])
	}
	label, err := tokenLabel(req.GetLabel(), def)
	if err != nil {
		return nil, err
	}
	p, err = s.Store.ApprovePairing(ctx, p.Code, u.ID, label)
	if errors.Is(err, store.ErrNotFound) { // expired or ended in between
		return nil, status.Error(codes.NotFound, "no such pairing code, or it has expired")
	}
	if err != nil {
		return nil, toStatus(err)
	}
	return pairingProto(p), nil
}

func (s *Account) DenyPairing(ctx context.Context, req *pb.DenyPairingRequest) (*emptypb.Empty, error) {
	u, p, err := s.livePairing(ctx, req.GetCode())
	if err != nil {
		return nil, err
	}
	if err := s.Store.DenyPairing(ctx, p.Code, u.ID); errors.Is(err, store.ErrNotFound) {
		return nil, status.Error(codes.NotFound, "no such pairing code, or it has expired")
	} else if err != nil {
		return nil, toStatus(err)
	}
	return &emptypb.Empty{}, nil
}
