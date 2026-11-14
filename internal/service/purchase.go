package service

import (
	"context"
	"errors"
	"log/slog"

	pb "github.com/liliang-cn/noted/gen/noted/v1"
	"github.com/liliang-cn/noted/internal/auth"
	"github.com/liliang-cn/noted/internal/store"
	"github.com/liliang-cn/noted/internal/storekit"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// The App Store identity of Noted Pro: a one-time, non-consumable purchase.
const (
	AppBundleID  = "cn.superleo.noted"
	ProProductID = "cn.superleo.noted.pro.lifetime"
)

func (s *Account) purchases() *storekit.Verifier {
	if s.Purchases != nil {
		return s.Purchases
	}
	return &storekit.Verifier{BundleID: AppBundleID, ProductID: ProProductID}
}

// VerifyPurchase checks a StoreKit 2 signed transaction for Noted Pro and,
// when it holds, makes the caller Pro. A purchase unlocks one account.
func (s *Account) VerifyPurchase(ctx context.Context, req *pb.VerifyPurchaseRequest) (*pb.Account, error) {
	u, ok := auth.User(ctx)
	if !ok {
		return nil, status.Error(codes.Unauthenticated, "not authenticated")
	}
	if req.GetSignedTransaction() == "" {
		return nil, status.Error(codes.InvalidArgument, "signed_transaction is empty")
	}
	tx, err := s.purchases().Verify(req.GetSignedTransaction())
	if err != nil {
		slog.Warn("purchase refused", "user", u.Name, "err", err)
		return nil, status.Error(codes.InvalidArgument, "the purchase could not be verified")
	}
	err = s.Store.BindPurchase(ctx, tx.OriginalTransactionID, u.ID, tx.ProductID, tx.Environment)
	if errors.Is(err, store.ErrPurchaseTaken) {
		return nil, status.Error(codes.PermissionDenied, "这笔购买已绑定到另一个 Noted 账号")
	}
	if err != nil {
		return nil, toStatus(err)
	}
	slog.Info("noted pro purchased", "user", u.Name, "environment", tx.Environment)
	return s.account(ctx)
}
