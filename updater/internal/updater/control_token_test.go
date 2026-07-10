package updater

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLoadControlTokenRejectsEmptyAndOversizedFiles(t *testing.T) {
	path := filepath.Join(t.TempDir(), "control-token")
	if err := os.WriteFile(path, []byte("\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadControlToken(path); err == nil {
		t.Fatal("expected empty control token rejection")
	}
	if err := os.WriteFile(path, []byte(strings.Repeat("x", 4097)), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadControlToken(path); err == nil {
		t.Fatal("expected oversized control token rejection")
	}
}

func TestLoadControlTokenReturnsTrimmedToken(t *testing.T) {
	path := filepath.Join(t.TempDir(), "control-token")
	want := strings.Repeat("a", 32)
	if err := os.WriteFile(path, []byte(want+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	got, err := LoadControlToken(path)
	if err != nil {
		t.Fatalf("LoadControlToken: %v", err)
	}
	if got != want {
		t.Fatal("control token was not trimmed")
	}
}
