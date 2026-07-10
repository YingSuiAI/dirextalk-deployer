package updater

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"
)

func TestStateStoreAtomicallyReplacesPrivateState(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state", "runtime.json")
	store := NewStateStore(path)
	first := NewRuntimeState()
	first.DesiredState = DesiredMaintenance
	if err := store.Save(context.Background(), first); err != nil {
		t.Fatalf("save first state: %v", err)
	}
	second := NewRuntimeState()
	second.DesiredState = DesiredRunning
	if err := store.Save(context.Background(), second); err != nil {
		t.Fatalf("save second state: %v", err)
	}
	loaded, err := store.Load(context.Background())
	if err != nil {
		t.Fatalf("load state: %v", err)
	}
	if loaded.DesiredState != DesiredRunning {
		t.Fatalf("expected replacement state, got %#v", loaded)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if runtime.GOOS != "windows" && info.Mode().Perm()&0o077 != 0 {
		t.Fatalf("state must be private, mode=%#o", info.Mode().Perm())
	}
	matches, err := filepath.Glob(filepath.Join(filepath.Dir(path), ".runtime.json.tmp-*"))
	if err != nil || len(matches) != 0 {
		t.Fatalf("temporary state files remain: %v err=%v", matches, err)
	}
}

func TestRuntimeStateRejectsUnknownFieldsAndInvalidDesiredState(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.json")
	if err := os.WriteFile(path, []byte(`{"schema_version":1,"desired_state":"running","unknown":true}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := NewStateStore(path).Load(context.Background()); err == nil {
		t.Fatal("expected unknown state field rejection")
	}
	state := NewRuntimeState()
	state.DesiredState = DesiredState("restart-everything")
	if err := NewStateStore(path).Save(context.Background(), state); err == nil {
		t.Fatal("expected invalid desired state rejection")
	}
}

func TestRuntimeStateRejectsInvalidPersistedPlanAndJobState(t *testing.T) {
	manifest, err := ValidateManifest([]byte(validManifestJSON()))
	if err != nil {
		t.Fatal(err)
	}
	t.Run("manifest", func(t *testing.T) {
		state := NewRuntimeState()
		invalidManifest := manifest
		invalidManifest.ImageDigest = "sha256:attacker"
		state.Plans[tokenHash("plan")] = Plan{Manifest: invalidManifest, ExpiresAt: time.Now().Add(time.Hour)}
		if err := NewStateStore(filepath.Join(t.TempDir(), "state.json")).Save(context.Background(), state); err == nil {
			t.Fatal("expected invalid persisted manifest to be rejected")
		}
	})
	t.Run("job status", func(t *testing.T) {
		state := NewRuntimeState()
		planHash := tokenHash("plan")
		state.Plans[planHash] = Plan{Manifest: manifest, ExpiresAt: time.Now().Add(time.Hour)}
		state.Jobs["job_1"] = Job{ID: "job_1", Status: JobStatus("run_shell"), PlanTokenHash: planHash, BearerTokenHashes: []string{tokenHash("bearer")}, IdempotencyKey: "request-1"}
		state.Idempotency["request-1"] = "job_1"
		if err := NewStateStore(filepath.Join(t.TempDir(), "state.json")).Save(context.Background(), state); err == nil {
			t.Fatal("expected invalid persisted job state to be rejected")
		}
	})
}

func TestDiscoveryRefreshCachesValidReleaseAndRetainsItOnFailure(t *testing.T) {
	now := time.Date(2026, 7, 10, 3, 0, 0, 0, time.UTC)
	store := NewStateStore(filepath.Join(t.TempDir(), "state.json"))
	source := &fakeReleaseSource{data: []byte(validManifestJSON())}
	cache, err := RefreshDiscovery(context.Background(), store, source, now)
	if err != nil {
		t.Fatalf("refresh discovery: %v", err)
	}
	if cache.Status != DiscoveryFresh || cache.Manifest == nil || cache.ManifestDigest == "" {
		t.Fatalf("unexpected discovery cache: %#v", cache)
	}
	source.err = context.DeadlineExceeded
	stale, err := RefreshDiscovery(context.Background(), store, source, now.Add(time.Hour))
	if err == nil {
		t.Fatal("expected source failure")
	}
	if stale.Status != DiscoveryStale || stale.Manifest == nil || stale.Manifest.Version != "v1.1.0" {
		t.Fatalf("last good release must be retained as stale: %#v", stale)
	}
}

type fakeReleaseSource struct {
	data []byte
	err  error
}

func (source *fakeReleaseSource) Latest(context.Context) ([]byte, error) {
	return append([]byte(nil), source.data...), source.err
}
