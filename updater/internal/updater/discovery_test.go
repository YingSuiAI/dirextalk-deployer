package updater

import (
	"context"
	"errors"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

type releaseSourceFunc func(context.Context) ([]byte, error)

func (source releaseSourceFunc) Latest(ctx context.Context) ([]byte, error) {
	return source(ctx)
}

func TestRefreshDiscoveryPersistsValidatedRelease(t *testing.T) {
	store := NewStateStore(filepath.Join(t.TempDir(), "state.json"))
	checkedAt := time.Date(2026, time.July, 10, 1, 2, 3, 0, time.FixedZone("test", 8*60*60))

	cache, err := RefreshDiscovery(context.Background(), store, releaseSourceFunc(func(context.Context) ([]byte, error) {
		return []byte(validManifestJSON()), nil
	}), checkedAt)
	if err != nil {
		t.Fatalf("RefreshDiscovery: %v", err)
	}
	if cache.Status != DiscoveryFresh || cache.Manifest == nil || cache.Manifest.Version != "v1.1.0" {
		t.Fatalf("unexpected discovery cache: %#v", cache)
	}
	if cache.ManifestDigest == "" || !cache.CheckedAt.Equal(checkedAt.UTC()) {
		t.Fatalf("missing discovery metadata: %#v", cache)
	}

	persisted, err := store.Load(context.Background())
	if err != nil {
		t.Fatalf("load persisted discovery: %v", err)
	}
	if persisted.Discovery.Manifest == nil || persisted.Discovery.ManifestDigest != cache.ManifestDigest {
		t.Fatalf("discovery was not persisted: %#v", persisted.Discovery)
	}
}

func TestRefreshDiscoveryRetainsLastGoodReleaseWhenSourceFails(t *testing.T) {
	store := NewStateStore(filepath.Join(t.TempDir(), "state.json"))
	firstCheck := time.Date(2026, time.July, 10, 1, 0, 0, 0, time.UTC)
	if _, err := RefreshDiscovery(context.Background(), store, releaseSourceFunc(func(context.Context) ([]byte, error) {
		return []byte(validManifestJSON()), nil
	}), firstCheck); err != nil {
		t.Fatalf("seed discovery: %v", err)
	}

	secondCheck := firstCheck.Add(24 * time.Hour)
	cache, err := RefreshDiscovery(context.Background(), store, releaseSourceFunc(func(context.Context) ([]byte, error) {
		return nil, errors.New("temporary upstream failure")
	}), secondCheck)
	if err == nil {
		t.Fatal("expected source failure")
	}
	if cache.Status != DiscoveryStale || cache.Manifest == nil || cache.Manifest.Version != "v1.1.0" {
		t.Fatalf("last good release was not retained: %#v", cache)
	}
	if cache.ErrorCode != "release_source_unavailable" || !cache.CheckedAt.Equal(secondCheck) {
		t.Fatalf("unexpected stale discovery metadata: %#v", cache)
	}
}

func TestRefreshDiscoveryAndPlanRegistrationDoNotLoseEachOthersUpdates(t *testing.T) {
	store := NewStateStore(filepath.Join(t.TempDir(), "state.json"))
	manifestData := []byte(validManifestJSON())
	if _, err := RefreshDiscovery(context.Background(), store, releaseSourceFunc(func(context.Context) ([]byte, error) {
		return manifestData, nil
	}), time.Now()); err != nil {
		t.Fatal(err)
	}
	service, err := NewService(store, testControlToken)
	if err != nil {
		t.Fatal(err)
	}

	started := make(chan struct{})
	release := make(chan struct{})
	var once sync.Once
	refreshDone := make(chan error, 1)
	go func() {
		_, refreshErr := RefreshDiscovery(context.Background(), store, releaseSourceFunc(func(context.Context) ([]byte, error) {
			once.Do(func() { close(started) })
			<-release
			return manifestData, nil
		}), time.Now().Add(time.Hour))
		refreshDone <- refreshErr
	}()
	<-started
	manifest, err := ValidateManifest(manifestData)
	if err != nil {
		t.Fatal(err)
	}
	if err := service.RegisterPlan(context.Background(), "parallel-plan", Plan{
		Manifest:       manifest,
		ManifestDigest: manifestDigest(manifestData),
		CurrentVersion: "v1.0.0",
		ExpiresAt:      time.Now().Add(time.Hour),
	}); err != nil {
		t.Fatal(err)
	}
	close(release)
	if err := <-refreshDone; err != nil {
		t.Fatal(err)
	}
	persisted, err := store.Load(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := persisted.Plans[tokenHash("parallel-plan")]; !ok {
		t.Fatal("discovery refresh overwrote the concurrently registered plan")
	}
	if persisted.Discovery.Status != DiscoveryFresh || persisted.Discovery.ManifestDigest != manifestDigest(manifestData) {
		t.Fatalf("plan registration overwrote discovery: %#v", persisted.Discovery)
	}
}
