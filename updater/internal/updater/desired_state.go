package updater

import (
	"encoding/json"
	"net/http"
)

type desiredStateRequest struct {
	DesiredState DesiredState `json:"desired_state"`
}

type desiredStateResponse struct {
	DesiredState DesiredState `json:"desired_state"`
}

func (service *Service) setDesiredState(response http.ResponseWriter, request *http.Request) {
	if !constantTokenEqual(service.controlTokenHash, request.Header.Get(controlTokenHeader)) {
		writeAPIError(response, http.StatusUnauthorized, "control_token_required")
		return
	}
	var input desiredStateRequest
	decoder := json.NewDecoder(http.MaxBytesReader(response, request.Body, maxRequestBytes))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&input); err != nil {
		writeAPIError(response, http.StatusBadRequest, "invalid_request: "+err.Error())
		return
	}
	if err := ensureJSONEOF(decoder, "desired-state request"); err != nil {
		writeAPIError(response, http.StatusBadRequest, "invalid_request: "+err.Error())
		return
	}
	if !input.DesiredState.valid() {
		writeAPIError(response, http.StatusBadRequest, "invalid_request")
		return
	}
	if err := service.store.Update(request.Context(), func(state *RuntimeState) error {
		state.DesiredState = input.DesiredState
		return nil
	}); err != nil {
		writeAPIError(response, http.StatusInternalServerError, "state_write_failed")
		return
	}
	writeJSON(response, http.StatusOK, desiredStateResponse{DesiredState: input.DesiredState})
}
