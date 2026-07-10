package updater

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"reflect"
	"strings"
	"time"
)

const (
	apiPrefix          = "/_dirextalk/updater/v1/"
	controlJobsPath    = apiPrefix + "control/jobs"
	publicJobsPrefix   = apiPrefix + "jobs/"
	controlTokenHeader = "X-Dirextalk-Control-Token"
	applyConfirmation  = "apply_release_change"
	maxRequestBytes    = 64 * 1024
)

type Service struct {
	store            *StateStore
	controlTokenHash string
	now              func() time.Time
}

func NewService(store *StateStore, controlToken string) (*Service, error) {
	if store == nil {
		return nil, fmt.Errorf("state store is required")
	}
	if strings.TrimSpace(controlToken) == "" {
		return nil, fmt.Errorf("control token is required")
	}
	if _, err := store.Load(context.Background()); err != nil {
		return nil, err
	}
	return &Service{
		store:            store,
		controlTokenHash: tokenHash(controlToken),
		now:              time.Now,
	}, nil
}

func (service *Service) Handler() http.Handler {
	return http.HandlerFunc(service.serveHTTP)
}

func (service *Service) RegisterPlan(ctx context.Context, rawToken string, plan Plan) error {
	if strings.TrimSpace(rawToken) == "" {
		return fmt.Errorf("plan token is required")
	}
	if err := plan.Manifest.Validate(); err != nil {
		return err
	}
	if !digestPattern.MatchString(plan.ManifestDigest) {
		return fmt.Errorf("plan manifest_digest is invalid")
	}
	if err := plan.Manifest.ValidateUpgradeFrom(plan.CurrentVersion); err != nil {
		return err
	}
	if !plan.ExpiresAt.After(service.now()) {
		return fmt.Errorf("plan expiry must be in the future")
	}
	return service.store.Update(ctx, func(state *RuntimeState) error {
		if state.Discovery.Status != DiscoveryFresh || state.Discovery.Manifest == nil {
			return fmt.Errorf("a fresh discovered release is required")
		}
		if state.Discovery.ManifestDigest != plan.ManifestDigest || !reflect.DeepEqual(*state.Discovery.Manifest, plan.Manifest) {
			return fmt.Errorf("plan manifest does not match the discovered release")
		}
		planHash := tokenHash(rawToken)
		if existing, ok := state.Plans[planHash]; ok {
			if reflect.DeepEqual(existing, plan) {
				return nil
			}
			return fmt.Errorf("plan token is already bound to a different plan")
		}
		state.Plans[planHash] = plan
		return nil
	})
}

func (service *Service) serveHTTP(response http.ResponseWriter, request *http.Request) {
	switch {
	case request.URL.Path == controlJobsPath:
		if request.Method != http.MethodPost {
			writeAPIError(response, http.StatusMethodNotAllowed, "method_not_allowed")
			return
		}
		service.createJob(response, request)
	case strings.HasPrefix(request.URL.Path, publicJobsPrefix):
		if request.Method != http.MethodGet {
			writeAPIError(response, http.StatusMethodNotAllowed, "method_not_allowed")
			return
		}
		jobID := strings.TrimPrefix(request.URL.Path, publicJobsPrefix)
		if jobID == "" || strings.Contains(jobID, "/") {
			writeAPIError(response, http.StatusNotFound, "job_not_found")
			return
		}
		service.getJob(response, request, jobID)
	default:
		writeAPIError(response, http.StatusNotFound, "not_found")
	}
}

type createJobRequest struct {
	PlanToken      string `json:"plan_token"`
	IdempotencyKey string `json:"idempotency_key"`
	Confirm        string `json:"confirm"`
}

type JobTicket struct {
	JobID     string    `json:"job_id"`
	JobToken  string    `json:"job_token"`
	StatusURL string    `json:"status_url"`
	Status    JobStatus `json:"status"`
}

type publicJob struct {
	JobID          string    `json:"job_id"`
	Status         JobStatus `json:"status"`
	CurrentVersion string    `json:"current_version,omitempty"`
	TargetVersion  string    `json:"target_version"`
	CreatedAt      time.Time `json:"created_at"`
	UpdatedAt      time.Time `json:"updated_at"`
}

func (service *Service) createJob(response http.ResponseWriter, request *http.Request) {
	if !constantTokenEqual(service.controlTokenHash, request.Header.Get(controlTokenHeader)) {
		writeAPIError(response, http.StatusUnauthorized, "control_token_required")
		return
	}
	var input createJobRequest
	decoder := json.NewDecoder(http.MaxBytesReader(response, request.Body, maxRequestBytes))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&input); err != nil {
		writeAPIError(response, http.StatusBadRequest, "invalid_request: "+err.Error())
		return
	}
	if err := ensureJSONEOF(decoder, "job request"); err != nil {
		writeAPIError(response, http.StatusBadRequest, "invalid_request: "+err.Error())
		return
	}
	input.PlanToken = strings.TrimSpace(input.PlanToken)
	input.IdempotencyKey = strings.TrimSpace(input.IdempotencyKey)
	if input.PlanToken == "" || input.IdempotencyKey == "" || len(input.IdempotencyKey) > 128 || input.Confirm != applyConfirmation {
		writeAPIError(response, http.StatusBadRequest, "invalid_request")
		return
	}

	planHash := tokenHash(input.PlanToken)
	var ticket JobTicket
	var rejection *mutationRejection
	err := service.store.Update(request.Context(), func(state *RuntimeState) error {
		plan, ok := state.Plans[planHash]
		if !ok || !plan.ExpiresAt.After(service.now()) {
			return rejectMutation(http.StatusConflict, "plan_invalid_or_expired")
		}
		if existingID, exists := state.Idempotency[input.IdempotencyKey]; exists {
			job, jobExists := state.Jobs[existingID]
			if !jobExists {
				return rejectMutation(http.StatusInternalServerError, "state_inconsistent")
			}
			if job.PlanTokenHash != planHash {
				return rejectMutation(http.StatusConflict, "idempotency_conflict")
			}
			rawBearer, tokenErr := randomToken(32)
			if tokenErr != nil {
				return rejectMutation(http.StatusInternalServerError, "token_generation_failed")
			}
			job.BearerTokenHashes = append(job.BearerTokenHashes, tokenHash(rawBearer))
			job.UpdatedAt = service.now().UTC()
			state.Jobs[job.ID] = job
			ticket = JobTicket{JobID: job.ID, JobToken: rawBearer, StatusURL: publicJobPath(job.ID), Status: job.Status}
			return nil
		}

		jobIDToken, tokenErr := randomToken(18)
		if tokenErr != nil {
			return rejectMutation(http.StatusInternalServerError, "token_generation_failed")
		}
		rawBearer, tokenErr := randomToken(32)
		if tokenErr != nil {
			return rejectMutation(http.StatusInternalServerError, "token_generation_failed")
		}
		now := service.now().UTC()
		job := Job{
			ID:                "job_" + jobIDToken,
			Status:            JobQueued,
			PlanTokenHash:     planHash,
			ManifestDigest:    plan.ManifestDigest,
			BearerTokenHashes: []string{tokenHash(rawBearer)},
			IdempotencyKey:    input.IdempotencyKey,
			CurrentVersion:    plan.CurrentVersion,
			TargetVersion:     plan.Manifest.Version,
			CreatedAt:         now,
			UpdatedAt:         now,
		}
		state.Jobs[job.ID] = job
		state.Idempotency[input.IdempotencyKey] = job.ID
		ticket = JobTicket{JobID: job.ID, JobToken: rawBearer, StatusURL: publicJobPath(job.ID), Status: job.Status}
		return nil
	})
	if err != nil {
		if errors.As(err, &rejection) {
			writeAPIError(response, rejection.status, rejection.code)
		} else {
			writeAPIError(response, http.StatusInternalServerError, "state_write_failed")
		}
		return
	}
	writeJSON(response, http.StatusAccepted, ticket)
}

func (service *Service) getJob(response http.ResponseWriter, request *http.Request, jobID string) {
	state, err := service.store.Load(request.Context())
	if err != nil {
		writeAPIError(response, http.StatusInternalServerError, "state_read_failed")
		return
	}
	job, ok := state.Jobs[jobID]
	if !ok {
		writeAPIError(response, http.StatusNotFound, "job_not_found")
		return
	}
	bearer := bearerToken(request.Header.Get("Authorization"))
	if !jobTokenAllowed(job, bearer) {
		writeAPIError(response, http.StatusUnauthorized, "job_token_required")
		return
	}
	writeJSON(response, http.StatusOK, publicJob{
		JobID:          job.ID,
		Status:         job.Status,
		CurrentVersion: job.CurrentVersion,
		TargetVersion:  job.TargetVersion,
		CreatedAt:      job.CreatedAt,
		UpdatedAt:      job.UpdatedAt,
	})
}

type mutationRejection struct {
	status int
	code   string
}

func (rejection *mutationRejection) Error() string { return rejection.code }

func rejectMutation(status int, code string) error {
	return &mutationRejection{status: status, code: code}
}

func publicJobPath(jobID string) string {
	return publicJobsPrefix + jobID
}

func tokenHash(token string) string {
	digest := sha256.Sum256([]byte(token))
	return hex.EncodeToString(digest[:])
}

func constantTokenEqual(expectedHash, candidate string) bool {
	candidateHash := tokenHash(candidate)
	return subtle.ConstantTimeCompare([]byte(expectedHash), []byte(candidateHash)) == 1
}

func jobTokenAllowed(job Job, rawToken string) bool {
	if rawToken == "" {
		return false
	}
	candidateHash := tokenHash(rawToken)
	for _, expectedHash := range job.BearerTokenHashes {
		if subtle.ConstantTimeCompare([]byte(expectedHash), []byte(candidateHash)) == 1 {
			return true
		}
	}
	return false
}

func randomToken(size int) (string, error) {
	data := make([]byte, size)
	if _, err := io.ReadFull(rand.Reader, data); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(data), nil
}

func bearerToken(header string) string {
	parts := strings.SplitN(strings.TrimSpace(header), " ", 2)
	if len(parts) != 2 || !strings.EqualFold(parts[0], "Bearer") {
		return ""
	}
	return strings.TrimSpace(parts[1])
}

func writeAPIError(response http.ResponseWriter, status int, message string) {
	writeJSON(response, status, map[string]string{"error": message})
}

func writeJSON(response http.ResponseWriter, status int, value any) {
	response.Header().Set("Content-Type", "application/json")
	response.WriteHeader(status)
	_ = json.NewEncoder(response).Encode(value)
}
