package ai

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/liliang-cn/agent-go/v3/pkg/domain"
	"github.com/liliang-cn/agent-go/v3/pkg/pool"
	"github.com/liliang-cn/noted/internal/config"
)

// A Noted Pro user may bring their own model ("自带 API key"). The service
// puts it on the request context with WithUserModel; every model call made
// for that request (the assistant's turns and tool rounds, the one-shot
// generations) then goes to that endpoint instead of the server's. The
// assistant, its tools and its conversations are the same either way: only
// the generator underneath is swapped.

type userModelKey struct{}

// UserModel is the endpoint one request runs against.
type UserModel struct {
	UserID   string
	Endpoint config.Endpoint
}

// WithUserModel routes the model calls made with ctx to m.
func WithUserModel(ctx context.Context, m UserModel) context.Context {
	return context.WithValue(ctx, userModelKey{}, m)
}

// UserModelFrom returns the user model WithUserModel put on ctx.
func UserModelFrom(ctx context.Context) (UserModel, bool) {
	m, ok := ctx.Value(userModelKey{}).(UserModel)
	return m, ok && m.UserID != "" && m.Endpoint.Configured()
}

// ModelChecker is implemented by engines that can run on a user's own model.
type ModelChecker interface {
	// CheckModel makes one tiny call to e and reports whether it answered.
	CheckModel(ctx context.Context, e config.Endpoint) error
	// ForgetModel drops what was cached for the user's own model.
	ForgetModel(userID string)
}

func newPool(name string, e config.Endpoint) (*pool.Pool, error) {
	return pool.NewPool(pool.PoolConfig{
		Enabled:  true,
		Strategy: pool.StrategyRoundRobin,
		Providers: []pool.Provider{{
			Name: name, BaseURL: e.BaseURL, Key: e.APIKey,
			ModelName: e.Model, MaxConcurrency: 4, Capability: 4,
		}},
	})
}

// router is the generator the assistant is built with. It answers with the
// server's model unless the context names the user's own.
type router struct {
	def *pool.Pool

	mu    sync.Mutex
	users map[string]cachedPool // by user id
}

type cachedPool struct {
	sum  [32]byte // of base url, model and key: a change builds a new pool
	pool *pool.Pool
}

func newRouter(def *pool.Pool) *router { return &router{def: def, users: map[string]cachedPool{}} }

func fingerprint(e config.Endpoint) [32]byte {
	return sha256.Sum256([]byte(e.BaseURL + "\x00" + e.Model + "\x00" + e.APIKey))
}

func (r *router) pick(ctx context.Context) (domain.Generator, error) {
	m, ok := UserModelFrom(ctx)
	if !ok {
		return r.def, nil
	}
	sum := fingerprint(m.Endpoint)
	r.mu.Lock()
	defer r.mu.Unlock()
	if c, ok := r.users[m.UserID]; ok && c.sum == sum {
		return c.pool, nil
	}
	p, err := newPool("user", m.Endpoint)
	if err != nil {
		return nil, fmt.Errorf("user model: %w", err)
	}
	// The pool it replaces may still be serving a request; it holds no
	// background work, so it is left to the garbage collector.
	r.users[m.UserID] = cachedPool{sum: sum, pool: p}
	return p, nil
}

func (r *router) forget(userID string) {
	r.mu.Lock()
	delete(r.users, userID)
	r.mu.Unlock()
}

func (r *router) Generate(ctx context.Context, prompt string, opts *domain.GenerationOptions) (string, error) {
	g, err := r.pick(ctx)
	if err != nil {
		return "", err
	}
	return g.Generate(ctx, prompt, opts)
}

func (r *router) Stream(ctx context.Context, prompt string, opts *domain.GenerationOptions, cb func(string)) error {
	g, err := r.pick(ctx)
	if err != nil {
		return err
	}
	return g.Stream(ctx, prompt, opts, cb)
}

func (r *router) GenerateWithTools(ctx context.Context, msgs []domain.Message, tools []domain.ToolDefinition, opts *domain.GenerationOptions) (*domain.GenerationResult, error) {
	g, err := r.pick(ctx)
	if err != nil {
		return nil, err
	}
	return g.GenerateWithTools(ctx, msgs, tools, opts)
}

func (r *router) StreamWithTools(ctx context.Context, msgs []domain.Message, tools []domain.ToolDefinition, opts *domain.GenerationOptions, cb domain.ToolCallCallback) error {
	g, err := r.pick(ctx)
	if err != nil {
		return err
	}
	return g.StreamWithTools(ctx, msgs, tools, opts, cb)
}

func (r *router) GenerateStructured(ctx context.Context, prompt string, schema interface{}, opts *domain.GenerationOptions) (*domain.StructuredResult, error) {
	g, err := r.pick(ctx)
	if err != nil {
		return nil, err
	}
	return g.GenerateStructured(ctx, prompt, schema, opts)
}

func (r *router) RecognizeIntent(ctx context.Context, request string) (*domain.IntentResult, error) {
	g, err := r.pick(ctx)
	if err != nil {
		return nil, err
	}
	return g.RecognizeIntent(ctx, request)
}

// The agent reads these once, when it is built, to size its context window:
// they describe the server's model.
func (r *router) GetModelName() string { return r.def.GetModelName() }
func (r *router) GetBaseURL() string   { return r.def.GetBaseURL() }
func (r *router) UsageModel() string   { return r.def.UsageModel() }

// CheckModel sends one short prompt to e.
func (a *Agent) CheckModel(ctx context.Context, e config.Endpoint) error {
	if !e.Configured() {
		return errors.New("base url and model are required")
	}
	p, err := newPool("check", e)
	if err != nil {
		return err
	}
	defer func() { _ = p.Close() }()
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	// No answer text is required: a reasoning model may spend this whole
	// budget thinking. Being answered without an error is the test.
	_, err = p.Generate(ctx, "Reply with the single word OK.", &domain.GenerationOptions{Temperature: 0, MaxTokens: 64})
	return err
}

// ForgetModel drops the user's cached pool (after they change or clear it).
func (a *Agent) ForgetModel(userID string) {
	if a.router != nil {
		a.router.forget(userID)
	}
}
