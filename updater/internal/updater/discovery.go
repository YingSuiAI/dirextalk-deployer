package updater

import (
	"context"
	"fmt"
	"time"
)

type ReleaseSource interface {
	Latest(context.Context) ([]byte, error)
}

func RefreshDiscovery(ctx context.Context, store *StateStore, source ReleaseSource, checkedAt time.Time) (DiscoveryCache, error) {
	data, sourceErr := source.Latest(ctx)
	if sourceErr != nil {
		var cache DiscoveryCache
		if saveErr := store.Update(ctx, func(state *RuntimeState) error {
			cache = state.Discovery
			cache.CheckedAt = checkedAt.UTC()
			cache.ErrorCode = "release_source_unavailable"
			if cache.Manifest == nil {
				cache.Status = DiscoveryUnavailable
			} else {
				cache.Status = DiscoveryStale
			}
			state.Discovery = cache
			return nil
		}); saveErr != nil {
			return DiscoveryCache{}, saveErr
		}
		return cache, fmt.Errorf("discover latest release: %w", sourceErr)
	}
	manifest, validationErr := ValidateManifest(data)
	if validationErr != nil {
		var cache DiscoveryCache
		if saveErr := store.Update(ctx, func(state *RuntimeState) error {
			cache = state.Discovery
			cache.CheckedAt = checkedAt.UTC()
			cache.ErrorCode = "release_manifest_invalid"
			if cache.Manifest == nil {
				cache.Status = DiscoveryUnavailable
			} else {
				cache.Status = DiscoveryStale
			}
			state.Discovery = cache
			return nil
		}); saveErr != nil {
			return DiscoveryCache{}, saveErr
		}
		return cache, validationErr
	}
	cache := DiscoveryCache{
		Status:         DiscoveryFresh,
		CheckedAt:      checkedAt.UTC(),
		Manifest:       &manifest,
		ManifestDigest: manifestDigest(data),
	}
	if err := store.Update(ctx, func(state *RuntimeState) error {
		state.Discovery = cache
		return nil
	}); err != nil {
		return DiscoveryCache{}, err
	}
	return cache, nil
}
