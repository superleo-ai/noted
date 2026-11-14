// Package secretbox seals small secrets (a user's own model API key) before
// they are written to the database, with AES-256-GCM under a server key.
package secretbox

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Box seals and opens values. The zero value is not usable; use New or Load.
type Box struct{ aead cipher.AEAD }

// New derives the AES-256 key from secret (any string; SHA-256 of it).
func New(secret string) (*Box, error) {
	secret = strings.TrimSpace(secret)
	if len(secret) < 16 {
		return nil, errors.New("secret key: need at least 16 characters")
	}
	k := sha256.Sum256([]byte(secret))
	block, err := aes.NewCipher(k[:])
	if err != nil {
		return nil, err
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	return &Box{aead: aead}, nil
}

// FileName is where Load keeps a generated key inside the data directory.
const FileName = "secret.key"

// Load returns a Box for secret when it is set; otherwise it reads the key
// file in dataDir, creating it (0600, 32 random bytes as hex) the first time.
// Losing that file makes stored secrets unreadable, so it belongs in backups
// with the database.
func Load(secret, dataDir string) (*Box, error) {
	if strings.TrimSpace(secret) != "" {
		return New(secret)
	}
	path := filepath.Join(dataDir, FileName)
	if _, err := os.Stat(path); errors.Is(err, os.ErrNotExist) {
		raw := make([]byte, 32)
		if _, err := rand.Read(raw); err != nil {
			return nil, err
		}
		if err := os.MkdirAll(dataDir, 0o755); err != nil {
			return nil, err
		}
		f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
		if err != nil {
			return nil, fmt.Errorf("create %s: %w", path, err)
		}
		if _, err := f.WriteString(hex.EncodeToString(raw) + "\n"); err != nil {
			_ = f.Close()
			return nil, err
		}
		if err := f.Close(); err != nil {
			return nil, err
		}
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", path, err)
	}
	return New(string(b))
}

// Seal encrypts plain, bound to context (e.g. the owner's user id), so a
// sealed value moved to another owner does not open.
func (b *Box) Seal(plain, context string) []byte {
	nonce := make([]byte, b.aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		panic(err) // crypto/rand does not fail on supported platforms
	}
	return b.aead.Seal(nonce, nonce, []byte(plain), []byte(context))
}

// Open reverses Seal.
func (b *Box) Open(sealed []byte, context string) (string, error) {
	n := b.aead.NonceSize()
	if len(sealed) < n {
		return "", errors.New("sealed value too short")
	}
	out, err := b.aead.Open(nil, sealed[:n], sealed[n:], []byte(context))
	if err != nil {
		return "", errors.New("sealed value does not open with this server key")
	}
	return string(out), nil
}
