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
	state, err := store.Load(ctx)
	if err != nil {
		return DiscoveryCache{}, err
	}
	data, sourceErr := source.Latest(ctx)
	if sourceErr != nil {
		cache := state.Discovery
		cache.CheckedAt = checkedAt.UTC()
		cache.ErrorCode = "release_source_unavailable"
		if cache.Manifest == nil {
			cache.Status = DiscoveryUnavailable
		} else {
			cache.Status = DiscoveryStale
		}
		state.Discovery = cache
		if saveErr := store.Save(ctx, state); saveErr != nil {
			return cache, saveErr
		}
		return cache, fmt.Errorf("discover latest release: %w", sourceErr)
	}
	manifest, validationErr := ValidateManifest(data)
	if validationErr != nil {
		cache := state.Discovery
		cache.CheckedAt = checkedAt.UTC()
		cache.ErrorCode = "release_manifest_invalid"
		if cache.Manifest == nil {
			cache.Status = DiscoveryUnavailable
		} else {
			cache.Status = DiscoveryStale
		}
		state.Discovery = cache
		if saveErr := store.Save(ctx, state); saveErr != nil {
			return cache, saveErr
		}
		return cache, validationErr
	}
	cache := DiscoveryCache{
		Status:         DiscoveryFresh,
		CheckedAt:      checkedAt.UTC(),
		Manifest:       &manifest,
		ManifestDigest: manifestDigest(data),
	}
	state.Discovery = cache
	if err := store.Save(ctx, state); err != nil {
		return DiscoveryCache{}, err
	}
	return cache, nil
}
