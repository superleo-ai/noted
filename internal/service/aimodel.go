package service

import (
	"context"
	"errors"
	"log/slog"
	"net"
	"net/netip"
	"net/url"
	"strings"
	"unicode"

	pb "github.com/liliang-cn/noted/gen/noted/v1"
	"github.com/liliang-cn/noted/internal/ai"
	"github.com/liliang-cn/noted/internal/auth"
	"github.com/liliang-cn/noted/internal/config"
	"github.com/liliang-cn/noted/internal/store"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// A Noted Pro user may run the assistant on their own model: an
// OpenAI-compatible endpoint and key of theirs. Their provider bills them, so
// those calls are not capped. It never makes AI available without Pro: need
// refuses a free user before a model is chosen, and a stored key of someone
// who lost Pro is kept but not used.

var errOwnModelNotPro = status.Error(codes.FailedPrecondition, "自带模型 Key 是 Noted Pro 的功能")

// ownModel is the user's own model when they have one and its key opens.
func (s *AI) ownModel(ctx context.Context, userID string) (ai.UserModel, bool) {
	if s.Secret == nil {
		return ai.UserModel{}, false
	}
	m, err := s.Store.GetAIModel(ctx, userID)
	if err != nil {
		if !errors.Is(err, store.ErrNotFound) {
			slog.Warn("own model: read", "err", err)
		}
		return ai.UserModel{}, false
	}
	key, err := s.Secret.Open(m.KeySealed, userID)
	if err != nil {
		// The server key changed: fall back to the server's model until the
		// user enters their key again.
		slog.Warn("own model: key does not open", "user", userID, "err", err)
		return ai.UserModel{}, false
	}
	return ai.UserModel{UserID: userID, Endpoint: config.Endpoint{BaseURL: m.BaseURL, Model: m.Model, APIKey: key}}, true
}

func (s *AI) modelSettings(ctx context.Context, userID string) (*pb.ModelSettings, error) {
	m, err := s.Store.GetAIModel(ctx, userID)
	if errors.Is(err, store.ErrNotFound) {
		return &pb.ModelSettings{}, nil
	}
	if err != nil {
		return nil, toStatus(err)
	}
	out := &pb.ModelSettings{BaseUrl: m.BaseURL, Model: m.Model, KeySet: true, KeyHint: m.KeyHint}
	if u, err := url.Parse(m.BaseURL); err == nil {
		out.Host = u.Hostname()
	}
	pro, err := s.Store.UserPro(ctx, userID)
	if err != nil {
		return nil, toStatus(err)
	}
	if _, ok := s.ownModel(ctx, userID); ok && pro {
		out.Active = true
	}
	return out, nil
}

func (s *AI) GetModelSettings(ctx context.Context, _ *pb.GetModelSettingsRequest) (*pb.ModelSettings, error) {
	u, ok := auth.User(ctx)
	if !ok {
		return nil, status.Error(codes.Unauthenticated, "not authenticated")
	}
	return s.modelSettings(ctx, u.ID)
}

func (s *AI) SetModelSettings(ctx context.Context, req *pb.SetModelSettingsRequest) (*pb.ModelSettings, error) {
	u, ok := auth.User(ctx)
	if !ok {
		return nil, status.Error(codes.Unauthenticated, "not authenticated")
	}
	if s.Engine == nil || !s.Engine.Status().Chat {
		return nil, errDisabled
	}
	checker, ok := s.Engine.(ai.ModelChecker)
	if !ok || s.Secret == nil {
		return nil, status.Error(codes.FailedPrecondition, "这台服务器不支持自带模型 Key")
	}
	pro, err := s.Store.UserPro(ctx, u.ID)
	if err != nil {
		return nil, toStatus(err)
	}
	if !pro {
		return nil, errOwnModelNotPro
	}
	base, err := s.checkBaseURL(req.BaseUrl)
	if err != nil {
		return nil, err
	}
	model := strings.TrimSpace(req.Model)
	if model == "" || len(model) > 200 {
		return nil, status.Error(codes.InvalidArgument, "请填写模型名")
	}
	key := strings.TrimSpace(req.ApiKey)
	if key == "" {
		// Keep the stored key: the user is changing only the address or model.
		old, ok := s.ownModel(ctx, u.ID)
		if !ok {
			return nil, status.Error(codes.InvalidArgument, "请填写 API Key")
		}
		key = old.Endpoint.APIKey
	}
	if len(key) > 1024 || strings.ContainsFunc(key, unicode.IsSpace) {
		return nil, status.Error(codes.InvalidArgument, "API Key 的格式不对")
	}
	ep := config.Endpoint{BaseURL: base, Model: model, APIKey: key}
	if err := checker.CheckModel(ctx, ep); err != nil {
		if ctx.Err() != nil {
			return nil, toStatus(ctx.Err())
		}
		slog.Info("own model: test call failed", "user", u.ID, "host", hostOf(base), "err", err)
		return nil, status.Error(codes.InvalidArgument, checkFailure(err))
	}
	if err := s.Store.SetAIModel(ctx, u.ID, store.AIModel{
		BaseURL: base, Model: model, KeySealed: s.Secret.Seal(key, u.ID), KeyHint: maskKey(key),
	}); err != nil {
		return nil, toStatus(err)
	}
	checker.ForgetModel(u.ID)
	return s.modelSettings(ctx, u.ID)
}

// ClearModelSettings needs no Pro: anyone may remove a key they stored.
func (s *AI) ClearModelSettings(ctx context.Context, _ *pb.ClearModelSettingsRequest) (*pb.ModelSettings, error) {
	u, ok := auth.User(ctx)
	if !ok {
		return nil, status.Error(codes.Unauthenticated, "not authenticated")
	}
	if err := s.Store.ClearAIModel(ctx, u.ID); err != nil {
		return nil, toStatus(err)
	}
	if c, ok := s.Engine.(ai.ModelChecker); ok {
		c.ForgetModel(u.ID)
	}
	return &pb.ModelSettings{}, nil
}

// checkBaseURL accepts an https origin with an optional path such as /v1.
// The server calls it, so it must not point back into the server's own
// network: localhost and private addresses are refused (except in tests).
func (s *AI) checkBaseURL(raw string) (string, error) {
	bad := status.Error(codes.InvalidArgument, "接口地址要是 https:// 开头的完整地址，例如 https://api.openai.com/v1")
	raw = strings.TrimRight(strings.TrimSpace(raw), "/")
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || len(raw) > 500 {
		return "", bad
	}
	local := isLocalHost(u.Hostname())
	switch {
	case local && !s.LocalModels:
		return "", status.Error(codes.InvalidArgument, "接口地址不能是本机或内网地址")
	case u.Scheme == "https":
	case u.Scheme == "http" && local && s.LocalModels:
	default:
		return "", bad
	}
	return raw, nil
}

func isLocalHost(h string) bool {
	h = strings.ToLower(strings.TrimSuffix(h, "."))
	if h == "localhost" || strings.HasSuffix(h, ".localhost") || strings.HasSuffix(h, ".local") || strings.HasSuffix(h, ".internal") {
		return true
	}
	ip, err := netip.ParseAddr(h)
	if err != nil {
		return false
	}
	ip = ip.Unmap()
	return ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() || ip.IsUnspecified() ||
		ip.IsLinkLocalMulticast() || ip.IsInterfaceLocalMulticast() ||
		netip.MustParsePrefix("100.64.0.0/10").Contains(ip) // carrier-grade NAT, Tailscale
}

func hostOf(base string) string {
	if u, err := url.Parse(base); err == nil {
		return u.Hostname()
	}
	return ""
}

// maskKey shows enough of a key to recognise it and never most of it.
func maskKey(k string) string {
	r := []rune(k)
	switch {
	case len(r) >= 16:
		return string(r[:3]) + "…" + string(r[len(r)-4:])
	case len(r) >= 8:
		return "…" + string(r[len(r)-2:])
	}
	return "…"
}

// checkFailure turns a failed test call into a sentence for the user,
// without the provider's raw reply.
func checkFailure(err error) string {
	msg := strings.ToLower(err.Error())
	var dnsErr *net.DNSError
	var opErr *net.OpError
	has := func(words ...string) bool {
		for _, w := range words {
			if strings.Contains(msg, w) {
				return true
			}
		}
		return false
	}
	switch {
	case has("401", "403", "unauthorized", "forbidden", "invalid api key", "invalid_api_key", "incorrect api key", "authentication"):
		return "API Key 无效或没有权限：服务商拒绝了这个 key"
	case has("429", "quota", "insufficient", "rate limit", "balance"):
		return "服务商说额度不足或请求太频繁，稍后再试或检查账户余额"
	case has("404", "model_not_found", "does not exist", "not found", "unknown model"):
		return "接口地址或模型名不对：服务商找不到它"
	case errors.As(err, &dnsErr) || errors.As(err, &opErr) ||
		has("no such host", "connection refused", "timeout", "deadline", "tls", "certificate", "eof", "dial"):
		return "连不上这个接口地址，检查一下地址是否正确"
	}
	return "测试调用失败：这个接口没有正常回答，检查地址、模型名和 key"
}
