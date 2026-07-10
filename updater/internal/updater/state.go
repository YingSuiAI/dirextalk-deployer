package updater

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const RuntimeStateSchemaVersion = 1

type DesiredState string

const (
	DesiredRunning       DesiredState = "running"
	DesiredUpgrading     DesiredState = "upgrading"
	DesiredMaintenance   DesiredState = "maintenance"
	DesiredDeprovisioned DesiredState = "deprovisioned"
)

func (state DesiredState) valid() bool {
	switch state {
	case DesiredRunning, DesiredUpgrading, DesiredMaintenance, DesiredDeprovisioned:
		return true
	default:
		return false
	}
}

type DiscoveryStatus string

const (
	DiscoveryUnknown     DiscoveryStatus = "unknown"
	DiscoveryFresh       DiscoveryStatus = "fresh"
	DiscoveryStale       DiscoveryStatus = "stale"
	DiscoveryUnavailable DiscoveryStatus = "unavailable"
)

type DiscoveryCache struct {
	Status         DiscoveryStatus `json:"status"`
	CheckedAt      time.Time       `json:"checked_at,omitempty"`
	Manifest       *Manifest       `json:"manifest,omitempty"`
	ManifestDigest string          `json:"manifest_digest,omitempty"`
	ErrorCode      string          `json:"error_code,omitempty"`
}

type Plan struct {
	Manifest       Manifest  `json:"manifest"`
	ManifestDigest string    `json:"manifest_digest"`
	CurrentVersion string    `json:"current_version"`
	ExpiresAt      time.Time `json:"expires_at"`
}

type JobStatus string

const (
	JobQueued JobStatus = "queued"
)

type Job struct {
	ID                string    `json:"id"`
	Status            JobStatus `json:"status"`
	PlanTokenHash     string    `json:"plan_token_hash"`
	ManifestDigest    string    `json:"manifest_digest"`
	BearerTokenHashes []string  `json:"bearer_token_hashes"`
	IdempotencyKey    string    `json:"idempotency_key"`
	CurrentVersion    string    `json:"current_version,omitempty"`
	TargetVersion     string    `json:"target_version"`
	CreatedAt         time.Time `json:"created_at"`
	UpdatedAt         time.Time `json:"updated_at"`
}

type RuntimeState struct {
	SchemaVersion int               `json:"schema_version"`
	DesiredState  DesiredState      `json:"desired_state"`
	Discovery     DiscoveryCache    `json:"discovery"`
	Plans         map[string]Plan   `json:"plans,omitempty"`
	Jobs          map[string]Job    `json:"jobs,omitempty"`
	Idempotency   map[string]string `json:"idempotency,omitempty"`
}

func NewRuntimeState() RuntimeState {
	return RuntimeState{
		SchemaVersion: RuntimeStateSchemaVersion,
		DesiredState:  DesiredRunning,
		Discovery:     DiscoveryCache{Status: DiscoveryUnknown},
		Plans:         map[string]Plan{},
		Jobs:          map[string]Job{},
		Idempotency:   map[string]string{},
	}
}

func (state *RuntimeState) normalizeAndValidate() error {
	if state.SchemaVersion != RuntimeStateSchemaVersion {
		return fmt.Errorf("state schema_version %d is not supported", state.SchemaVersion)
	}
	if !state.DesiredState.valid() {
		return fmt.Errorf("desired_state %q is invalid", state.DesiredState)
	}
	if state.Plans == nil {
		state.Plans = map[string]Plan{}
	}
	if state.Jobs == nil {
		state.Jobs = map[string]Job{}
	}
	if state.Idempotency == nil {
		state.Idempotency = map[string]string{}
	}
	switch state.Discovery.Status {
	case DiscoveryUnknown, DiscoveryFresh, DiscoveryStale, DiscoveryUnavailable:
	default:
		return fmt.Errorf("discovery status %q is invalid", state.Discovery.Status)
	}
	if state.Discovery.Manifest != nil {
		if err := state.Discovery.Manifest.Validate(); err != nil {
			return fmt.Errorf("discovery manifest is invalid: %w", err)
		}
		if !digestPattern.MatchString(state.Discovery.ManifestDigest) {
			return fmt.Errorf("discovery manifest_digest is invalid")
		}
	} else if state.Discovery.Status == DiscoveryFresh {
		return fmt.Errorf("fresh discovery requires a manifest")
	}
	for planHash, plan := range state.Plans {
		if !storedTokenHashValid(planHash) {
			return fmt.Errorf("plan token hash is invalid")
		}
		if err := plan.Manifest.Validate(); err != nil {
			return fmt.Errorf("plan manifest is invalid: %w", err)
		}
		if !digestPattern.MatchString(plan.ManifestDigest) {
			return fmt.Errorf("plan manifest_digest is invalid")
		}
		if err := plan.Manifest.ValidateUpgradeFrom(plan.CurrentVersion); err != nil {
			return fmt.Errorf("plan upgrade edge is invalid: %w", err)
		}
		if plan.ExpiresAt.IsZero() {
			return fmt.Errorf("plan expiry is required")
		}
	}
	for jobID, job := range state.Jobs {
		if job.ID == "" || job.ID != jobID {
			return fmt.Errorf("job id is invalid")
		}
		if job.Status != JobQueued {
			return fmt.Errorf("job %s status %q is invalid", jobID, job.Status)
		}
		if _, ok := state.Plans[job.PlanTokenHash]; !ok {
			return fmt.Errorf("job %s references an unknown plan", jobID)
		}
		plan := state.Plans[job.PlanTokenHash]
		if job.ManifestDigest != plan.ManifestDigest || job.TargetVersion != plan.Manifest.Version {
			return fmt.Errorf("job %s target does not match its plan", jobID)
		}
		if job.IdempotencyKey == "" || state.Idempotency[job.IdempotencyKey] != jobID {
			return fmt.Errorf("job %s idempotency mapping is invalid", jobID)
		}
		if len(job.BearerTokenHashes) == 0 {
			return fmt.Errorf("job %s has no bearer token hash", jobID)
		}
		for _, bearerHash := range job.BearerTokenHashes {
			if !storedTokenHashValid(bearerHash) {
				return fmt.Errorf("job %s bearer token hash is invalid", jobID)
			}
		}
	}
	for idempotencyKey, jobID := range state.Idempotency {
		job, ok := state.Jobs[jobID]
		if idempotencyKey == "" || !ok || job.IdempotencyKey != idempotencyKey {
			return fmt.Errorf("idempotency mapping is invalid")
		}
	}
	return nil
}

func storedTokenHashValid(value string) bool {
	if len(value) != sha256.Size*2 {
		return false
	}
	decoded, err := hex.DecodeString(value)
	return err == nil && len(decoded) == sha256.Size && value == strings.ToLower(value)
}

type StateStore struct {
	path          string
	syncDirectory func(string) error
	mu            sync.Mutex
}

func NewStateStore(path string) *StateStore {
	return &StateStore{path: path, syncDirectory: syncDirectory}
}

func (store *StateStore) Path() string {
	return store.path
}

func (store *StateStore) Load(ctx context.Context) (RuntimeState, error) {
	store.mu.Lock()
	defer store.mu.Unlock()
	return store.loadLocked(ctx)
}

func (store *StateStore) loadLocked(ctx context.Context) (RuntimeState, error) {
	if err := ctx.Err(); err != nil {
		return RuntimeState{}, err
	}
	data, err := os.ReadFile(store.path)
	if errors.Is(err, os.ErrNotExist) {
		return NewRuntimeState(), nil
	}
	if err != nil {
		return RuntimeState{}, fmt.Errorf("read updater state: %w", err)
	}
	var state RuntimeState
	if err := decodeStrict(data, &state, "updater state"); err != nil {
		return RuntimeState{}, err
	}
	if err := state.normalizeAndValidate(); err != nil {
		return RuntimeState{}, err
	}
	return state, nil
}

func (store *StateStore) Save(ctx context.Context, state RuntimeState) error {
	store.mu.Lock()
	defer store.mu.Unlock()
	return store.saveLocked(ctx, state)
}

// Update serializes a complete read-modify-write transaction. Callers must not
// perform external I/O in mutate because the state lock remains held until the
// updated snapshot has been durably committed or the write has failed.
func (store *StateStore) Update(ctx context.Context, mutate func(*RuntimeState) error) error {
	if mutate == nil {
		return fmt.Errorf("state mutation is required")
	}
	store.mu.Lock()
	defer store.mu.Unlock()
	state, err := store.loadLocked(ctx)
	if err != nil {
		return err
	}
	if err := mutate(&state); err != nil {
		return err
	}
	return store.saveLocked(ctx, state)
}

func (store *StateStore) saveLocked(ctx context.Context, state RuntimeState) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if err := state.normalizeAndValidate(); err != nil {
		return err
	}
	var buffer bytes.Buffer
	encoder := json.NewEncoder(&buffer)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(state); err != nil {
		return fmt.Errorf("encode updater state: %w", err)
	}
	directory := filepath.Dir(store.path)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return fmt.Errorf("create updater state directory: %w", err)
	}
	if err := os.Chmod(directory, 0o700); err != nil {
		return fmt.Errorf("protect updater state directory: %w", err)
	}
	temporary, err := os.CreateTemp(directory, "."+filepath.Base(store.path)+".tmp-*")
	if err != nil {
		return fmt.Errorf("create updater state temp file: %w", err)
	}
	temporaryPath := temporary.Name()
	keepTemporary := false
	defer func() {
		if !keepTemporary {
			_ = os.Remove(temporaryPath)
		}
	}()
	if err := temporary.Chmod(0o600); err != nil {
		_ = temporary.Close()
		return fmt.Errorf("protect updater state temp file: %w", err)
	}
	if _, err := temporary.Write(buffer.Bytes()); err != nil {
		_ = temporary.Close()
		return fmt.Errorf("write updater state temp file: %w", err)
	}
	if err := temporary.Sync(); err != nil {
		_ = temporary.Close()
		return fmt.Errorf("fsync updater state temp file: %w", err)
	}
	if err := temporary.Close(); err != nil {
		return fmt.Errorf("close updater state temp file: %w", err)
	}
	if err := os.Rename(temporaryPath, store.path); err != nil {
		return fmt.Errorf("replace updater state: %w", err)
	}
	keepTemporary = true
	if err := store.syncDirectory(directory); err != nil {
		return fmt.Errorf("fsync updater state directory: %w", err)
	}
	return nil
}
