package secretbox

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

func TestSealOpen(t *testing.T) {
	b, err := New("0123456789abcdef-test")
	if err != nil {
		t.Fatal(err)
	}
	s := b.Seal("fake-plain", "alice")
	if bytes.Contains(s, []byte("fake-plain")) {
		t.Fatal("plaintext visible in sealed value")
	}
	if got, err := b.Open(s, "alice"); err != nil || got != "fake-plain" {
		t.Fatalf("open: %q %v", got, err)
	}
	if _, err := b.Open(s, "bob"); err == nil {
		t.Fatal("opened under another owner")
	}
	other, _ := New("another-server-key-0000")
	if _, err := other.Open(s, "alice"); err == nil {
		t.Fatal("opened with another key")
	}
	if _, err := New("short"); err == nil {
		t.Fatal("short secret accepted")
	}
}

func TestLoadCreatesKeyFileOnce(t *testing.T) {
	dir := t.TempDir()
	a, err := Load("", dir)
	if err != nil {
		t.Fatal(err)
	}
	fi, err := os.Stat(filepath.Join(dir, FileName))
	if err != nil {
		t.Fatal(err)
	}
	if fi.Mode().Perm() != 0o600 {
		t.Fatalf("key file mode %v", fi.Mode().Perm())
	}
	b, err := Load("", dir)
	if err != nil {
		t.Fatal(err)
	}
	if got, err := b.Open(a.Seal("x", "u"), "u"); err != nil || got != "x" {
		t.Fatalf("second load uses another key: %v", err)
	}
}
