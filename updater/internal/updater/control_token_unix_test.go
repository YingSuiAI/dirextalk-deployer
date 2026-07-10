//go:build !windows

package updater

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLoadControlTokenRequiresPrivatePermissions(t *testing.T) {
	path := filepath.Join(t.TempDir(), "control-token")
	if err := os.WriteFile(path, []byte(strings.Repeat("a", 32)), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadControlToken(path); err == nil {
		t.Fatal("expected public control token file rejection")
	}
}
