package updater

import (
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
)

func TriggerDiscovery(ctx context.Context, socketPath, controlToken string) error {
	transport := &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, "unix", socketPath)
		},
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, "http://updater"+controlDiscoveryPath, strings.NewReader("{}"))
	if err != nil {
		return err
	}
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set(controlTokenHeader, controlToken)
	response, err := client.Do(request)
	if err != nil {
		return fmt.Errorf("call resident updater discovery: %w", err)
	}
	defer response.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, maxRequestBytes))
	if response.StatusCode != http.StatusOK {
		return fmt.Errorf("resident updater discovery returned HTTP %d", response.StatusCode)
	}
	return nil
}
