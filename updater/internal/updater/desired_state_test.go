package updater

import (
	"context"
	"net/http"
	"path/filepath"
	"strings"
	"testing"
)

func TestControlDesiredStateRequiresAuthAndStrictKnownEnum(t *testing.T) {
	store := NewStateStore(filepath.Join(t.TempDir(), "state.json"))
	service, err := NewService(store, testControlToken)
	if err != nil {
		t.Fatal(err)
	}
	unauthorized := postJSON(t, service.Handler(), controlDesiredStatePath, `{"desired_state":"deprovisioned"}`, "", "")
	if unauthorized.Code != http.StatusUnauthorized {
		t.Fatalf("expected auth rejection, got %d", unauthorized.Code)
	}
	for _, body := range []string{
		`{"desired_state":"invalid"}`,
		`{"desired_state":"deprovisioned","service":"attacker"}`,
		`{"desired_state":"running","compose_path":"/tmp/evil"}`,
	} {
		response := postJSON(t, service.Handler(), controlDesiredStatePath, body, testControlToken, "")
		if response.Code != http.StatusBadRequest {
			t.Fatalf("invalid desired-state accepted: %s -> %d %s", body, response.Code, response.Body.String())
		}
	}
}

func TestControlDesiredStatePersistsEveryKnownValueAcrossRestart(t *testing.T) {
	store := NewStateStore(filepath.Join(t.TempDir(), "state.json"))
	service, err := NewService(store, testControlToken)
	if err != nil {
		t.Fatal(err)
	}
	for _, desired := range []DesiredState{DesiredRunning, DesiredUpgrading, DesiredMaintenance, DesiredDeprovisioned} {
		response := postJSON(t, service.Handler(), controlDesiredStatePath, `{"desired_state":"`+string(desired)+`"}`, testControlToken, "")
		if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), `"desired_state":"`+string(desired)+`"`) {
			t.Fatalf("persist %s: %d %s", desired, response.Code, response.Body.String())
		}
		restarted, restartErr := NewService(store, testControlToken)
		if restartErr != nil {
			t.Fatal(restartErr)
		}
		state, loadErr := store.Load(context.Background())
		if loadErr != nil {
			t.Fatal(loadErr)
		}
		if state.DesiredState != desired {
			t.Fatalf("restart lost desired state: got %s want %s", state.DesiredState, desired)
		}
		service = restarted
	}
}
