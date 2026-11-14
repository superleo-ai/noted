// Package storekit verifies StoreKit 2 signed transactions
// (Transaction.jwsRepresentation) offline: the x5c chain must lead to a
// pinned Apple root, and the leaf must have signed the JWS.
package storekit

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/sha256"
	"crypto/x509"
	_ "embed"
	"encoding/asn1"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"strings"
	"time"
)

// AppleRootG3PEM is Apple Root CA - G3, from
// https://www.apple.com/certificateauthority/AppleRootCA-G3.cer
// (SHA-256 63:34:3A:BF:B8:9A:6A:03:EB:B5:7E:9B:3F:5F:A7:BE:7C:4F:5C:75:6F:30:17:B3:A8:C4:88:C3:65:3E:91:79).
//
//go:embed AppleRootCA-G3.pem
var AppleRootG3PEM []byte

// AppleRoots is a pool holding only Apple Root CA - G3.
func AppleRoots() *x509.CertPool {
	p := x509.NewCertPool()
	if !p.AppendCertsFromPEM(AppleRootG3PEM) {
		panic("storekit: embedded Apple root does not parse")
	}
	return p
}

// Marker extensions Apple puts on the certificates that sign App Store data.
var (
	oidLeaf         = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 6, 11, 1}
	oidIntermediate = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 6, 2, 1}
)

// Transaction is the part of the signed payload noted looks at.
type Transaction struct {
	TransactionID         string `json:"transactionId"`
	OriginalTransactionID string `json:"originalTransactionId"`
	BundleID              string `json:"bundleId"`
	ProductID             string `json:"productId"`
	Environment           string `json:"environment"` // Production, Sandbox (Xcode: local testing, never Apple-signed)
	Type                  string `json:"type"`
	PurchaseDate          int64  `json:"purchaseDate"`
	SignedDate            int64  `json:"signedDate"`
	RevocationDate        int64  `json:"revocationDate,omitempty"`
}

// Verifier checks transactions for one app and product.
type Verifier struct {
	BundleID  string
	ProductID string
	// Roots the chain must end in. nil: AppleRoots(). Tests pass their own CA.
	Roots *x509.CertPool
}

var ErrInvalid = errors.New("invalid signed transaction")

func invalid(format string, a ...any) error {
	return fmt.Errorf("%w: %s", ErrInvalid, fmt.Sprintf(format, a...))
}

// Verify checks the signature, the chain and what was bought. Every failure
// wraps ErrInvalid.
func (v *Verifier) Verify(jws string) (Transaction, error) {
	parts := strings.Split(strings.TrimSpace(jws), ".")
	if len(parts) != 3 {
		return Transaction{}, invalid("not a compact JWS")
	}
	var head struct {
		Alg string   `json:"alg"`
		X5c []string `json:"x5c"`
	}
	if err := decodeJSON(parts[0], &head); err != nil {
		return Transaction{}, invalid("header: %v", err)
	}
	if head.Alg != "ES256" {
		return Transaction{}, invalid("alg %q", head.Alg)
	}
	if len(head.X5c) != 3 {
		return Transaction{}, invalid("x5c has %d certificates, want 3", len(head.X5c))
	}
	var tx Transaction
	if err := decodeJSON(parts[1], &tx); err != nil {
		return Transaction{}, invalid("payload: %v", err)
	}
	certs := make([]*x509.Certificate, 2)
	for i := range certs {
		der, err := base64.StdEncoding.DecodeString(head.X5c[i])
		if err != nil {
			return Transaction{}, invalid("x5c[%d]: %v", i, err)
		}
		if certs[i], err = x509.ParseCertificate(der); err != nil {
			return Transaction{}, invalid("x5c[%d]: %v", i, err)
		}
	}
	leaf, mid := certs[0], certs[1]
	if !hasExt(leaf, oidLeaf) || !hasExt(mid, oidIntermediate) {
		return Transaction{}, invalid("certificates are not App Store signing certificates")
	}
	roots := v.Roots
	if roots == nil {
		roots = AppleRoots()
	}
	inter := x509.NewCertPool()
	inter.AddCert(mid)
	// Like Apple's own library when not checking revocation online, the chain
	// is judged at the time Apple signed the transaction.
	at := time.Now()
	if tx.SignedDate > 0 {
		at = time.UnixMilli(tx.SignedDate)
	}
	if _, err := leaf.Verify(x509.VerifyOptions{
		Roots: roots, Intermediates: inter, CurrentTime: at, KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageAny},
	}); err != nil {
		return Transaction{}, invalid("chain: %v", err)
	}
	pub, ok := leaf.PublicKey.(*ecdsa.PublicKey)
	if !ok || pub.Curve != elliptic.P256() {
		return Transaction{}, invalid("leaf key is not P-256")
	}
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil || len(sig) != 64 {
		return Transaction{}, invalid("signature encoding")
	}
	sum := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	r, s := new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:])
	if !ecdsa.Verify(pub, sum[:], r, s) {
		return Transaction{}, invalid("signature does not match")
	}

	switch {
	case tx.Environment != "Production" && tx.Environment != "Sandbox":
		return Transaction{}, invalid("environment %q", tx.Environment)
	case tx.BundleID != v.BundleID:
		return Transaction{}, invalid("bundle %q", tx.BundleID)
	case tx.ProductID != v.ProductID:
		return Transaction{}, invalid("product %q", tx.ProductID)
	case tx.RevocationDate != 0:
		return Transaction{}, invalid("the purchase was refunded or revoked")
	case tx.OriginalTransactionID == "":
		return Transaction{}, invalid("no originalTransactionId")
	}
	return tx, nil
}

func decodeJSON(seg string, v any) error {
	b, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(seg, "="))
	if err != nil {
		return err
	}
	return json.Unmarshal(b, v)
}

func hasExt(c *x509.Certificate, oid asn1.ObjectIdentifier) bool {
	for _, e := range c.Extensions {
		if e.Id.Equal(oid) {
			return true
		}
	}
	return false
}
