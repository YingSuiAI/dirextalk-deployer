package updater

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const (
	testControlToken = "test-control-token"
	testPlanToken    = "test-plan-token"
)

func TestControlJobCreationRequiresControlTokenAndRejectsInfrastructureFields(t *testing.T) {
	service, _ := newTestService(t)

	response := postJSON(t, service.Handler(), controlJobsPath, `{"plan_token":"test-plan-token","idempotency_key":"request-1","confirm":"apply_release_change"}`, "", "")
	if response.Code != http.StatusUnauthorized {
		t.Fatalf("expected control auth rejection, got %d: %s", response.Code, response.Body.String())
	}

	for _, field := range []string{"shell", "compose_path", "service", "image", "digest"} {
		body := strings.TrimSuffix(`{"plan_token":"test-plan-token","idempotency_key":"request-1","confirm":"apply_release_change"}`, "}") + `,"` + field + `":"attacker"}`
		response = postJSON(t, service.Handler(), controlJobsPath, body, testControlToken, "")
		if response.Code != http.StatusBadRequest || !strings.Contains(response.Body.String(), "unknown field") {
			t.Fatalf("expected %s rejection, got %d: %s", field, response.Code, response.Body.String())
		}
	}
}

func TestJobBearerIsHashedAndAuthorizesPublicStatus(t *testing.T) {
	service, store := newTestService(t)
	response := postJSON(t, service.Handler(), controlJobsPath, `{"plan_token":"test-plan-token","idempotency_key":"request-1","confirm":"apply_release_change"}`, testControlToken, "")
	if response.Code != http.StatusAccepted {
		t.Fatalf("create job: %d %s", response.Code, response.Body.String())
	}
	var ticket JobTicket
	decodeResponse(t, response, &ticket)
	if ticket.JobID == "" || ticket.JobToken == "" {
		t.Fatalf("missing job ticket fields: %#v", ticket)
	}
	data, err := os.ReadFile(store.Path())
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(data, []byte(ticket.JobToken)) || bytes.Contains(data, []byte(testPlanToken)) {
		t.Fatalf("raw tokens leaked into persisted state: %s", data)
	}

	request := httptest.NewRequest(http.MethodGet, publicJobPath(ticket.JobID), nil)
	request.Header.Set("Authorization", "Bearer "+ticket.JobToken)
	status := httptest.NewRecorder()
	service.Handler().ServeHTTP(status, request)
	if status.Code != http.StatusOK {
		t.Fatalf("authorized job status: %d %s", status.Code, status.Body.String())
	}
	request = httptest.NewRequest(http.MethodGet, publicJobPath(ticket.JobID), nil)
	request.Header.Set("Authorization", "Bearer wrong")
	status = httptest.NewRecorder()
	service.Handler().ServeHTTP(status, request)
	if status.Code != http.StatusUnauthorized {
		t.Fatalf("wrong bearer must fail, got %d", status.Code)
	}
}

func TestIdempotentReplayReturnsSameJobAndSurvivesRestart(t *testing.T) {
	service, store := newTestService(t)
	firstResponse := postJSON(t, service.Handler(), controlJobsPath, `{"plan_token":"test-plan-token","idempotency_key":"request-1","confirm":"apply_release_change"}`, testControlToken, "")
	var first JobTicket
	decodeResponse(t, firstResponse, &first)
	secondResponse := postJSON(t, service.Handler(), controlJobsPath, `{"plan_token":"test-plan-token","idempotency_key":"request-1","confirm":"apply_release_change"}`, testControlToken, "")
	var second JobTicket
	decodeResponse(t, secondResponse, &second)
	if first.JobID != second.JobID || first.JobToken == second.JobToken {
		t.Fatalf("idempotent replay must reuse job and mint an additional bearer: first=%#v second=%#v", first, second)
	}

	restarted, err := NewService(store, testControlToken)
	if err != nil {
		t.Fatalf("restart service: %v", err)
	}
	for _, token := range []string{first.JobToken, second.JobToken} {
		request := httptest.NewRequest(http.MethodGet, publicJobPath(first.JobID), nil)
		request.Header.Set("Authorization", "Bearer "+token)
		response := httptest.NewRecorder()
		restarted.Handler().ServeHTTP(response, request)
		if response.Code != http.StatusOK {
			t.Fatalf("persisted bearer rejected after restart: %d %s", response.Code, response.Body.String())
		}
	}
	replay := postJSON(t, restarted.Handler(), controlJobsPath, `{"plan_token":"test-plan-token","idempotency_key":"request-1","confirm":"apply_release_change"}`, testControlToken, "")
	var replayTicket JobTicket
	decodeResponse(t, replay, &replayTicket)
	if replayTicket.JobID != first.JobID {
		t.Fatalf("restart lost idempotency mapping: %#v", replayTicket)
	}
}

func TestIdempotencyKeyCannotBeReusedForDifferentPlan(t *testing.T) {
	service, _ := newTestService(t)
	first := postJSON(t, service.Handler(), controlJobsPath, `{"plan_token":"test-plan-token","idempotency_key":"request-1","confirm":"apply_release_change"}`, testControlToken, "")
	if first.Code != http.StatusAccepted {
		t.Fatalf("create first job: %d %s", first.Code, first.Body.String())
	}
	manifest, err := ValidateManifest([]byte(validManifestJSON()))
	if err != nil {
		t.Fatal(err)
	}
	if err := service.RegisterPlan(context.Background(), "other-plan", Plan{Manifest: manifest, ExpiresAt: time.Now().Add(time.Hour)}); err != nil {
		t.Fatal(err)
	}
	conflict := postJSON(t, service.Handler(), controlJobsPath, `{"plan_token":"other-plan","idempotency_key":"request-1","confirm":"apply_release_change"}`, testControlToken, "")
	if conflict.Code != http.StatusConflict {
		t.Fatalf("expected idempotency conflict, got %d %s", conflict.Code, conflict.Body.String())
	}
}

func newTestService(t *testing.T) (*Service, *StateStore) {
	t.Helper()
	store := NewStateStore(filepath.Join(t.TempDir(), "state.json"))
	service, err := NewService(store, testControlToken)
	if err != nil {
		t.Fatalf("NewService: %v", err)
	}
	manifest, err := ValidateManifest([]byte(validManifestJSON()))
	if err != nil {
		t.Fatal(err)
	}
	if err := service.RegisterPlan(context.Background(), testPlanToken, Plan{Manifest: manifest, ExpiresAt: time.Now().Add(time.Hour)}); err != nil {
		t.Fatalf("RegisterPlan: %v", err)
	}
	return service, store
}

func postJSON(t *testing.T, handler http.Handler, path, body, controlToken, bearer string) *httptest.ResponseRecorder {
	t.Helper()
	request := httptest.NewRequest(http.MethodPost, path, strings.NewReader(body))
	request.Header.Set("Content-Type", "application/json")
	if controlToken != "" {
		request.Header.Set(controlTokenHeader, controlToken)
	}
	if bearer != "" {
		request.Header.Set("Authorization", "Bearer "+bearer)
	}
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	return response
}

func decodeResponse(t *testing.T, response *httptest.ResponseRecorder, target any) {
	t.Helper()
	if response.Code != http.StatusAccepted && response.Code != http.StatusOK {
		t.Fatalf("unexpected response: %d %s", response.Code, response.Body.String())
	}
	decoder := json.NewDecoder(response.Body)
	if err := decoder.Decode(target); err != nil && err != io.EOF {
		t.Fatalf("decode response: %v", err)
	}
}
