package updater

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const compatibleStatusRequest = `{"current_version":"v1.0.0","current_schema_version":1,"current_schema_compat_version":1,"client_version":"1.2.3"}`

func TestControlStatusRequiresAuthAndRejectsUnknownOrInfrastructureFields(t *testing.T) {
	service, _, _ := newStatusTestService(t, DiscoveryFresh)
	unauthorized := postJSON(t, service.Handler(), controlStatusPath, compatibleStatusRequest, "", "")
	if unauthorized.Code != http.StatusUnauthorized {
		t.Fatalf("expected status auth rejection, got %d: %s", unauthorized.Code, unauthorized.Body.String())
	}
	for _, field := range []string{"image", "digest", "compose_path", "service", "instance_id", "shell", "unknown"} {
		body := strings.TrimSuffix(compatibleStatusRequest, "}") + fmt.Sprintf(`,"%s":"attacker"}`, field)
		response := postJSON(t, service.Handler(), controlStatusPath, body, testControlToken, "")
		if response.Code != http.StatusBadRequest || !strings.Contains(response.Body.String(), "unknown field") {
			t.Fatalf("expected %s rejection, got %d: %s", field, response.Code, response.Body.String())
		}
	}
}

func TestControlStatusUsesOnlyCachedDiscoveryAndCreatesRestartSafePlan(t *testing.T) {
	service, store, releaseCalls := newStatusTestService(t, DiscoveryFresh)
	response := postJSON(t, service.Handler(), controlStatusPath, compatibleStatusRequest, testControlToken, "")
	if response.Code != http.StatusOK {
		t.Fatalf("status: %d %s", response.Code, response.Body.String())
	}
	rawResponse := response.Body.String()
	var status StatusResponse
	decodeResponse(t, response, &status)
	if *releaseCalls != 0 {
		t.Fatalf("status must not contact release source, calls=%d", *releaseCalls)
	}
	if !status.Available || !status.ReleaseAvailable || !status.UpdateAvailable || status.DiscoveryStatus != DiscoveryFresh || status.Compatibility != CompatibilityCompatible {
		t.Fatalf("unexpected compatible status: %#v", status)
	}
	if status.CurrentVersion != "v1.0.0" || status.LatestVersion != "v1.1.0" || status.ClientVersion != "v1.2.3" || len(status.Operations) != 1 {
		t.Fatalf("status did not normalize/build operation: %#v", status)
	}
	operation := status.Operations[0]
	if operation.Kind != "upgrade" || operation.TargetVersion != "v1.1.0" || operation.PlanToken == "" || operation.Confirm != applyConfirmation || !operation.ExpiresAt.After(service.now()) {
		t.Fatalf("invalid operation: %#v", operation)
	}
	data, err := os.ReadFile(store.Path())
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(data, []byte(operation.PlanToken)) || bytes.Contains(data, []byte(`"plan_token"`)) {
		t.Fatalf("raw plan token leaked into state: %s", data)
	}
	state, err := store.Load(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := state.Plans[tokenHash(operation.PlanToken)]; !ok {
		t.Fatalf("hashed plan was not persisted: %#v", state.Plans)
	}

	restarted, err := NewService(store, testControlToken)
	if err != nil {
		t.Fatal(err)
	}
	restarted.now = service.now
	applyBody := fmt.Sprintf(`{"plan_token":%q,"idempotency_key":"status-apply-1","confirm":"apply_release_change"}`, operation.PlanToken)
	apply := postJSON(t, restarted.Handler(), controlJobsPath, applyBody, testControlToken, "")
	if apply.Code != http.StatusAccepted {
		t.Fatalf("status plan did not survive restart/apply: %d %s", apply.Code, apply.Body.String())
	}
	var ticket JobTicket
	decodeResponse(t, apply, &ticket)
	if ticket.JobID == "" || ticket.JobToken == "" {
		t.Fatalf("missing job ticket: %#v", ticket)
	}
	for _, forbidden := range []string{`"image"`, `"image_digest"`, `"manifest"`, "sha256:"} {
		if strings.Contains(rawResponse, forbidden) {
			t.Fatalf("status leaked internal release field %s: %s", forbidden, rawResponse)
		}
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal([]byte(rawResponse), &fields); err != nil {
		t.Fatal(err)
	}
	expectedFields := []string{"available", "release_available", "update_available", "discovery_status", "checked_at", "current_version", "latest_version", "client_version", "compatibility", "reasons", "release_notes_url", "operations"}
	if len(fields) != len(expectedFields) {
		t.Fatalf("unexpected status response fields: %v", fields)
	}
	for _, field := range expectedFields {
		if _, ok := fields[field]; !ok {
			t.Fatalf("missing status response field %q: %s", field, rawResponse)
		}
	}
}

func TestControlStatusCompatibilityAndDiscoveryStates(t *testing.T) {
	tests := []struct {
		name                 string
		discovery            DiscoveryStatus
		request              string
		wantReleaseAvailable bool
		wantUpdateAvailable  bool
		wantCompatibility    CompatibilityStatus
		wantReason           string
		wantLatest           string
	}{
		{"up to date", DiscoveryFresh, `{"current_version":"v1.1.0","current_schema_version":2,"current_schema_compat_version":1,"client_version":"1.2.3"}`, true, false, CompatibilityCompatible, "up_to_date", "v1.1.0"},
		{"client unknown", DiscoveryFresh, `{"current_version":"v1.0.0","current_schema_version":1,"current_schema_compat_version":1,"client_version":""}`, true, true, CompatibilityUnknown, "client_version_unknown", "v1.1.0"},
		{"client too old", DiscoveryFresh, `{"current_version":"v1.0.0","current_schema_version":1,"current_schema_compat_version":1,"client_version":"v0.9.0"}`, true, true, CompatibilityIncompatible, "client_too_old", "v1.1.0"},
		{"client too new", DiscoveryFresh, `{"current_version":"v1.0.0","current_schema_version":1,"current_schema_compat_version":1,"client_version":"v2.0.0"}`, true, true, CompatibilityIncompatible, "client_too_new", "v1.1.0"},
		{"schema window boundary", DiscoveryFresh, `{"current_version":"v1.0.0","current_schema_version":1,"current_schema_compat_version":1,"client_version":"v1.2.3"}`, true, true, CompatibilityCompatible, "", "v1.1.0"},
		{"current compat above target", DiscoveryFresh, `{"current_version":"v1.0.0","current_schema_version":3,"current_schema_compat_version":3,"client_version":"v1.2.3"}`, true, true, CompatibilityIncompatible, "schema_incompatible", "v1.1.0"},
		{"unsupported upgrade edge", DiscoveryFresh, `{"current_version":"v0.9.0","current_schema_version":1,"current_schema_compat_version":1,"client_version":"v1.2.3"}`, true, true, CompatibilityIncompatible, "upgrade_path_unsupported", "v1.1.0"},
		{"stale cache", DiscoveryStale, compatibleStatusRequest, true, true, CompatibilityUnknown, "discovery_stale", "v1.1.0"},
		{"unknown cache", DiscoveryUnknown, compatibleStatusRequest, false, false, CompatibilityUnknown, "discovery_unknown", ""},
		{"unavailable cache", DiscoveryUnavailable, compatibleStatusRequest, false, false, CompatibilityUnknown, "discovery_unavailable", ""},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			service, _, _ := newStatusTestService(t, test.discovery)
			response := postJSON(t, service.Handler(), controlStatusPath, test.request, testControlToken, "")
			if response.Code != http.StatusOK {
				t.Fatalf("status: %d %s", response.Code, response.Body.String())
			}
			var got StatusResponse
			decodeResponse(t, response, &got)
			if !got.Available || got.ReleaseAvailable != test.wantReleaseAvailable || got.UpdateAvailable != test.wantUpdateAvailable || got.Compatibility != test.wantCompatibility || got.LatestVersion != test.wantLatest {
				t.Fatalf("unexpected status: %#v", got)
			}
			if test.wantReason != "" && !containsReason(got.Reasons, test.wantReason) {
				t.Fatalf("missing reason %q: %#v", test.wantReason, got)
			}
			wantOperation := test.wantCompatibility == CompatibilityCompatible && test.wantUpdateAvailable && test.discovery == DiscoveryFresh
			if (len(got.Operations) == 1) != wantOperation {
				t.Fatalf("unexpected operations: %#v", got.Operations)
			}
		})
	}
}

func TestControlStatusRequiresCurrentSchemaInsideTargetCompatibilityWindow(t *testing.T) {
	service, store, _ := newStatusTestService(t, DiscoveryFresh)
	state, err := store.Load(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	manifestData := []byte(strings.Replace(validManifestJSON(), `"schema_compat_version": 1`, `"schema_compat_version": 2`, 1))
	manifest, err := ValidateManifest(manifestData)
	if err != nil {
		t.Fatal(err)
	}
	state.Discovery.Manifest = &manifest
	state.Discovery.ManifestDigest = manifestDigest(manifestData)
	if err := store.Save(context.Background(), state); err != nil {
		t.Fatal(err)
	}
	response := postJSON(t, service.Handler(), controlStatusPath, compatibleStatusRequest, testControlToken, "")
	if response.Code != http.StatusOK {
		t.Fatalf("status: %d %s", response.Code, response.Body.String())
	}
	var got StatusResponse
	decodeResponse(t, response, &got)
	if got.Compatibility != CompatibilityIncompatible || !containsReason(got.Reasons, "schema_incompatible") || len(got.Operations) != 0 {
		t.Fatalf("schema lower bound was not enforced: %#v", got)
	}
}

func TestControlStatusRejectsInvalidVersionsAndSchemaReport(t *testing.T) {
	service, _, _ := newStatusTestService(t, DiscoveryFresh)
	requests := []string{
		`{"current_version":"1.0.0","current_schema_version":1,"current_schema_compat_version":1,"client_version":"1.2.3"}`,
		`{"current_version":"v1.0.0","current_schema_version":0,"current_schema_compat_version":1,"client_version":"1.2.3"}`,
		`{"current_version":"v1.0.0","current_schema_version":1,"current_schema_compat_version":2,"client_version":"1.2.3"}`,
		`{"current_version":"v1.0.0","current_schema_version":1,"current_schema_compat_version":1,"client_version":"01.2.3"}`,
		`{"current_version":"v1.0.0","current_schema_version":1,"current_schema_compat_version":1,"client_version":"1.2.3-beta.1"}`,
		`{"current_version":"v1.0.0","current_schema_version":1,"current_schema_compat_version":1,"client_version":"1.2.3+4"}`,
		`{"current_version":"v1.0.0","current_schema_version":1,"current_schema_compat_version":1,"client_version":null}`,
		`{"current_version":"v1.0.0","current_schema_version":1,"current_schema_compat_version":1}`,
		`{"current_schema_version":1,"current_schema_compat_version":1,"client_version":""}`,
	}
	for _, body := range requests {
		response := postJSON(t, service.Handler(), controlStatusPath, body, testControlToken, "")
		if response.Code != http.StatusBadRequest {
			t.Fatalf("invalid report accepted: %s -> %d %s", body, response.Code, response.Body.String())
		}
	}
}

func TestControlStatusRemovesOnlyExpiredUnreferencedPlans(t *testing.T) {
	service, store, _ := newStatusTestService(t, DiscoveryFresh)
	initial := postJSON(t, service.Handler(), controlStatusPath, compatibleStatusRequest, testControlToken, "")
	var initialStatus StatusResponse
	decodeResponse(t, initial, &initialStatus)
	applyBody := fmt.Sprintf(`{"plan_token":%q,"idempotency_key":"referenced-expired","confirm":"apply_release_change"}`, initialStatus.Operations[0].PlanToken)
	apply := postJSON(t, service.Handler(), controlJobsPath, applyBody, testControlToken, "")
	if apply.Code != http.StatusAccepted {
		t.Fatalf("seed referenced plan: %d %s", apply.Code, apply.Body.String())
	}
	state, err := store.Load(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	var referencedHash string
	for _, job := range state.Jobs {
		referencedHash = job.PlanTokenHash
		plan := state.Plans[referencedHash]
		plan.ExpiresAt = service.now().Add(-time.Minute)
		state.Plans[referencedHash] = plan
	}
	state.Plans[tokenHash("expired-plan")] = Plan{Manifest: *state.Discovery.Manifest, ManifestDigest: state.Discovery.ManifestDigest, CurrentVersion: "v1.0.0", ExpiresAt: service.now().Add(-time.Minute)}
	if err := store.Save(context.Background(), state); err != nil {
		t.Fatal(err)
	}
	response := postJSON(t, service.Handler(), controlStatusPath, compatibleStatusRequest, testControlToken, "")
	if response.Code != http.StatusOK {
		t.Fatalf("status: %d %s", response.Code, response.Body.String())
	}
	state, err = store.Load(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if _, exists := state.Plans[tokenHash("expired-plan")]; exists {
		t.Fatalf("expired unreferenced plan was not removed: %#v", state.Plans)
	}
	if _, exists := state.Plans[referencedHash]; !exists {
		t.Fatalf("expired referenced plan was removed: %#v", state.Plans)
	}
}

func newStatusTestService(t *testing.T, discoveryStatus DiscoveryStatus) (*Service, *StateStore, *int) {
	t.Helper()
	store := NewStateStore(filepath.Join(t.TempDir(), "state.json"))
	state := NewRuntimeState()
	if discoveryStatus == DiscoveryFresh || discoveryStatus == DiscoveryStale {
		data := []byte(validManifestJSON())
		manifest, err := ValidateManifest(data)
		if err != nil {
			t.Fatal(err)
		}
		state.Discovery = DiscoveryCache{Status: discoveryStatus, CheckedAt: time.Date(2026, 7, 10, 3, 0, 0, 0, time.UTC), Manifest: &manifest, ManifestDigest: manifestDigest(data)}
	} else {
		state.Discovery = DiscoveryCache{Status: discoveryStatus, CheckedAt: time.Date(2026, 7, 10, 3, 0, 0, 0, time.UTC)}
	}
	if err := store.Save(context.Background(), state); err != nil {
		t.Fatal(err)
	}
	calls := 0
	service, err := NewService(store, testControlToken, WithReleaseSource(releaseSourceFunc(func(context.Context) ([]byte, error) {
		calls++
		return nil, fmt.Errorf("status must not fetch")
	})))
	if err != nil {
		t.Fatal(err)
	}
	service.now = func() time.Time { return time.Date(2026, 7, 10, 4, 0, 0, 0, time.UTC) }
	return service, store, &calls
}

func containsReason(reasons []string, wanted string) bool {
	for _, reason := range reasons {
		if reason == wanted {
			return true
		}
	}
	return false
}
