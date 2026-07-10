package updater

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"
)

const statusPlanLifetime = 15 * time.Minute

type CompatibilityStatus string

const (
	CompatibilityCompatible   CompatibilityStatus = "compatible"
	CompatibilityIncompatible CompatibilityStatus = "incompatible"
	CompatibilityUnknown      CompatibilityStatus = "unknown"
)

type statusRequest struct {
	CurrentVersion             *string `json:"current_version"`
	CurrentSchemaVersion       *int    `json:"current_schema_version"`
	CurrentSchemaCompatVersion *int    `json:"current_schema_compat_version"`
	ClientVersion              *string `json:"client_version"`
}

type normalizedStatusRequest struct {
	CurrentVersion             string
	CurrentSchemaVersion       int
	CurrentSchemaCompatVersion int
	ClientVersion              string
}

type StatusOperation struct {
	Kind          string    `json:"kind"`
	TargetVersion string    `json:"target_version"`
	PlanToken     string    `json:"plan_token"`
	ExpiresAt     time.Time `json:"expires_at"`
	Confirm       string    `json:"confirm"`
}

type StatusResponse struct {
	Available        bool                `json:"available"`
	ReleaseAvailable bool                `json:"release_available"`
	UpdateAvailable  bool                `json:"update_available"`
	DiscoveryStatus  DiscoveryStatus     `json:"discovery_status"`
	CheckedAt        *time.Time          `json:"checked_at"`
	CurrentVersion   string              `json:"current_version"`
	LatestVersion    string              `json:"latest_version"`
	ClientVersion    string              `json:"client_version"`
	Compatibility    CompatibilityStatus `json:"compatibility"`
	Reasons          []string            `json:"reasons"`
	ReleaseNotesURL  string              `json:"release_notes_url"`
	Operations       []StatusOperation   `json:"operations"`
}

func (service *Service) getStatus(response http.ResponseWriter, request *http.Request) {
	if !constantTokenEqual(service.controlTokenHash, request.Header.Get(controlTokenHeader)) {
		writeAPIError(response, http.StatusUnauthorized, "control_token_required")
		return
	}
	var input statusRequest
	decoder := json.NewDecoder(http.MaxBytesReader(response, request.Body, maxRequestBytes))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&input); err != nil {
		writeAPIError(response, http.StatusBadRequest, "invalid_request: "+err.Error())
		return
	}
	if err := ensureJSONEOF(decoder, "status request"); err != nil {
		writeAPIError(response, http.StatusBadRequest, "invalid_request: "+err.Error())
		return
	}
	normalized, err := normalizeStatusRequest(input)
	if err != nil {
		writeAPIError(response, http.StatusBadRequest, "invalid_request")
		return
	}
	now := service.now().UTC()
	state, err := service.store.Load(request.Context())
	if err != nil {
		writeAPIError(response, http.StatusInternalServerError, "state_read_failed")
		return
	}
	if hasExpiredUnreferencedPlans(state, now) {
		if err := service.store.Update(request.Context(), func(state *RuntimeState) error {
			removeExpiredUnreferencedPlans(state, now)
			return nil
		}); err != nil {
			writeAPIError(response, http.StatusInternalServerError, "state_write_failed")
			return
		}
		state, err = service.store.Load(request.Context())
		if err != nil {
			writeAPIError(response, http.StatusInternalServerError, "state_read_failed")
			return
		}
	}
	status, plan := evaluateStatus(state, normalized, now)
	if plan != nil {
		rawToken, tokenErr := randomToken(32)
		if tokenErr != nil {
			writeAPIError(response, http.StatusInternalServerError, "token_generation_failed")
			return
		}
		if err := service.RegisterPlan(request.Context(), rawToken, *plan); err != nil {
			writeAPIError(response, http.StatusConflict, "status_changed")
			return
		}
		status.Operations = append(status.Operations, StatusOperation{
			Kind:          "upgrade",
			TargetVersion: plan.Manifest.Version,
			PlanToken:     rawToken,
			ExpiresAt:     plan.ExpiresAt,
			Confirm:       applyConfirmation,
		})
	}
	writeJSON(response, http.StatusOK, status)
}

func normalizeStatusRequest(input statusRequest) (normalizedStatusRequest, error) {
	if input.CurrentVersion == nil || input.CurrentSchemaVersion == nil || input.CurrentSchemaCompatVersion == nil || input.ClientVersion == nil {
		return normalizedStatusRequest{}, fmt.Errorf("all status fields are required")
	}
	if _, err := parseCanonicalVersion("current_version", *input.CurrentVersion); err != nil {
		return normalizedStatusRequest{}, err
	}
	if *input.CurrentSchemaVersion < 1 || *input.CurrentSchemaCompatVersion < 1 || *input.CurrentSchemaCompatVersion > *input.CurrentSchemaVersion {
		return normalizedStatusRequest{}, fmt.Errorf("current schema versions are invalid")
	}
	client, err := normalizeClientVersion(*input.ClientVersion)
	if err != nil {
		return normalizedStatusRequest{}, err
	}
	return normalizedStatusRequest{
		CurrentVersion:             *input.CurrentVersion,
		CurrentSchemaVersion:       *input.CurrentSchemaVersion,
		CurrentSchemaCompatVersion: *input.CurrentSchemaCompatVersion,
		ClientVersion:              client,
	}, nil
}

func normalizeClientVersion(value string) (string, error) {
	if value == "" {
		return "", nil
	}
	if strings.HasPrefix(value, "v") {
		if _, err := parseCanonicalVersion("client_version", value); err != nil {
			return "", err
		}
		return value, nil
	}
	normalized := "v" + value
	if _, err := parseCanonicalVersion("client_version", normalized); err != nil {
		return "", err
	}
	return normalized, nil
}

func evaluateStatus(state RuntimeState, input normalizedStatusRequest, now time.Time) (StatusResponse, *Plan) {
	status := StatusResponse{
		Available:       true,
		DiscoveryStatus: state.Discovery.Status,
		CurrentVersion:  input.CurrentVersion,
		ClientVersion:   input.ClientVersion,
		Compatibility:   CompatibilityUnknown,
		Reasons:         []string{},
		Operations:      []StatusOperation{},
	}
	if !state.Discovery.CheckedAt.IsZero() {
		checkedAt := state.Discovery.CheckedAt.UTC()
		status.CheckedAt = &checkedAt
	}
	manifest := state.Discovery.Manifest
	if manifest == nil || (state.Discovery.Status != DiscoveryFresh && state.Discovery.Status != DiscoveryStale) {
		status.Reasons = append(status.Reasons, discoveryReason(state.Discovery.Status))
		return status, nil
	}
	status.ReleaseAvailable = true
	status.LatestVersion = manifest.Version
	status.ReleaseNotesURL = manifest.ReleaseNotesURL
	current, _ := parseCanonicalVersion("current_version", input.CurrentVersion)
	latest, _ := parseCanonicalVersion("latest_version", manifest.Version)
	status.UpdateAvailable = current.LessThan(latest)
	if state.Discovery.Status == DiscoveryStale {
		status.Reasons = append(status.Reasons, "discovery_stale")
		return status, nil
	}
	if input.ClientVersion == "" {
		status.Reasons = append(status.Reasons, "client_version_unknown")
		if !status.UpdateAvailable && current.Equal(latest) {
			status.Reasons = append(status.Reasons, "up_to_date")
		}
		return status, nil
	}
	if !status.UpdateAvailable {
		if current.Equal(latest) {
			status.Compatibility = CompatibilityCompatible
			status.Reasons = append(status.Reasons, "up_to_date")
		} else {
			status.Compatibility = CompatibilityIncompatible
			status.Reasons = append(status.Reasons, "current_version_newer")
		}
		return status, nil
	}
	compatible := true
	if err := manifest.ValidateUpgradeFrom(input.CurrentVersion); err != nil {
		compatible = false
		status.Reasons = append(status.Reasons, "upgrade_path_unsupported")
	}
	if input.CurrentSchemaVersion < manifest.SchemaCompatVersion || input.CurrentSchemaCompatVersion > manifest.SchemaVersion {
		compatible = false
		status.Reasons = append(status.Reasons, "schema_incompatible")
	}
	client, _ := parseCanonicalVersion("client_version", input.ClientVersion)
	minimum, _ := parseCanonicalVersion("minimum_client_version", manifest.MinimumClientVersion)
	maximum, _ := parseCanonicalVersion("maximum_client_version_exclusive", manifest.MaximumClientVersionExclusive)
	if client.LessThan(minimum) {
		compatible = false
		status.Reasons = append(status.Reasons, "client_too_old")
	}
	if !client.LessThan(maximum) {
		compatible = false
		status.Reasons = append(status.Reasons, "client_too_new")
	}
	if !compatible {
		status.Compatibility = CompatibilityIncompatible
		return status, nil
	}
	status.Compatibility = CompatibilityCompatible
	return status, &Plan{
		Manifest:       *manifest,
		ManifestDigest: state.Discovery.ManifestDigest,
		CurrentVersion: input.CurrentVersion,
		ExpiresAt:      now.Add(statusPlanLifetime),
	}
}

func discoveryReason(status DiscoveryStatus) string {
	switch status {
	case DiscoveryUnavailable:
		return "discovery_unavailable"
	case DiscoveryStale:
		return "discovery_stale"
	default:
		return "discovery_unknown"
	}
}

func removeExpiredUnreferencedPlans(state *RuntimeState, now time.Time) {
	referenced := make(map[string]struct{}, len(state.Jobs))
	for _, job := range state.Jobs {
		referenced[job.PlanTokenHash] = struct{}{}
	}
	for planHash, plan := range state.Plans {
		if _, isReferenced := referenced[planHash]; !isReferenced && !plan.ExpiresAt.After(now) {
			delete(state.Plans, planHash)
		}
	}
}

func hasExpiredUnreferencedPlans(state RuntimeState, now time.Time) bool {
	referenced := make(map[string]struct{}, len(state.Jobs))
	for _, job := range state.Jobs {
		referenced[job.PlanTokenHash] = struct{}{}
	}
	for planHash, plan := range state.Plans {
		if _, isReferenced := referenced[planHash]; !isReferenced && !plan.ExpiresAt.After(now) {
			return true
		}
	}
	return false
}
