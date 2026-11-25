// Package server wires the gRPC services, auth and health into one grpc.Server.
package server

import (
	"crypto/rand"
	"encoding/hex"
	"time"

	pb "github.com/liliang-cn/noted/gen/noted/v1"
	"github.com/liliang-cn/noted/internal/ai"
	"github.com/liliang-cn/noted/internal/apple"
	"github.com/liliang-cn/noted/internal/auth"
	"github.com/liliang-cn/noted/internal/plan"
	"github.com/liliang-cn/noted/internal/reminder"
	"github.com/liliang-cn/noted/internal/secretbox"
	"github.com/liliang-cn/noted/internal/service"
	"github.com/liliang-cn/noted/internal/store"
	"github.com/liliang-cn/noted/internal/storekit"
	"google.golang.org/grpc"
	"google.golang.org/grpc/health"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/reflection"
)

type Deps struct {
	Store        *store.Store
	Auth         *auth.Authenticator
	Hub          *reminder.Hub
	Engine       ai.Engine // nil: AI disabled
	Location     *time.Location
	Locale       plan.Locale // language of the sentences suggestions carry; default Chinese
	Changed      func()      // called after note writes; may be nil
	Reflection   bool
	Apple        *apple.Verifier // nil: Sign in with Apple is off
	AppleSignup  bool
	EmailSignup  bool               // anyone may create an email + password account
	Account      *service.Account   // nil: built from the fields above; set it to share one with the web portal
	Purchases    *storekit.Verifier // VerifyPurchase; nil: Apple's roots, noted's bundle and product
	AIDailyLimit int                // model calls per user per UTC day; 0: no cap
	// Secret seals Pro users' own model API keys. Nil: a random one for this
	// process only (keys stored under it do not survive a restart).
	Secret *secretbox.Box
	// LocalModels lets users' own model endpoints be on localhost (tests).
	LocalModels bool
}

// NewAccount builds the account service for d, with its own sign-in lockout.
func NewAccount(d Deps) *service.Account {
	return &service.Account{Store: d.Store, Apple: d.Apple, Signup: d.AppleSignup, EmailSignup: d.EmailSignup, Guard: service.NewGuard(),
		Engine: d.Engine, Purchases: d.Purchases}
}

func New(d Deps, opts ...grpc.ServerOption) *grpc.Server {
	if d.Locale == "" {
		d.Locale = plan.ZH
	}
	opts = append(opts,
		grpc.ChainUnaryInterceptor(d.Auth.Unary()),
		grpc.ChainStreamInterceptor(d.Auth.Stream()),
		grpc.MaxRecvMsgSize(4<<20), // notes are capped at 1 MiB; leave headroom
	)
	g := grpc.NewServer(opts...)
	if d.Account == nil {
		d.Account = NewAccount(d)
	}
	pb.RegisterAccountServiceServer(g, d.Account)
	pb.RegisterNoteServiceServer(g, &service.Notes{Store: d.Store, AI: d.Engine, Changed: d.Changed})
	pb.RegisterCalendarServiceServer(g, &service.Calendar{Store: d.Store, Hub: d.Hub, Location: d.Location})
	pb.RegisterGoalServiceServer(g, &service.Goals{Store: d.Store})
	pb.RegisterObjectiveServiceServer(g, &service.Objectives{Store: d.Store})
	pb.RegisterCompassServiceServer(g, &service.Compass{Store: d.Store})
	pb.RegisterPeopleServiceServer(g, &service.People{Store: d.Store})
	pb.RegisterHoldingServiceServer(g, &service.Holdings{Store: d.Store, Location: d.Location})
	pb.RegisterTimeServiceServer(g, &service.Time{Store: d.Store, Location: d.Location})
	pb.RegisterAlarmServiceServer(g, &service.Alarms{Store: d.Store, Location: d.Location})
	pb.RegisterHolidayServiceServer(g, &service.Holidays{Location: d.Location})
	pb.RegisterProjectServiceServer(g, &service.Projects{Store: d.Store, Location: d.Location})
	pb.RegisterFocusServiceServer(g, &service.Focus{Store: d.Store, Location: d.Location})
	sugg := &service.Suggestions{Store: d.Store, Location: d.Location, Locale: d.Locale}
	pb.RegisterSuggestionServiceServer(g, sugg)
	pb.RegisterExportServiceServer(g, &service.Export{Store: d.Store})
	pb.RegisterPreferenceServiceServer(g, &service.Preferences{Store: d.Store})
	if d.Secret == nil {
		d.Secret = ephemeralSecret()
	}
	pb.RegisterAIServiceServer(g, &service.AI{Store: d.Store, Engine: d.Engine, Location: d.Location, Locale: d.Locale, Sugg: sugg, Changed: d.Changed,
		DailyLimit: d.AIDailyLimit, Secret: d.Secret, LocalModels: d.LocalModels})

	h := health.NewServer()
	healthpb.RegisterHealthServer(g, h)
	if d.Reflection {
		reflection.Register(g)
	}
	return g
}

func ephemeralSecret() *secretbox.Box {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	box, err := secretbox.New(hex.EncodeToString(b))
	if err != nil {
		panic(err)
	}
	return box
}
