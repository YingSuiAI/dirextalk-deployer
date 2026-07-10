//go:build !windows

package updater

import (
	"context"
	"io"
	"net"
	"net/http"
	"path/filepath"
	"testing"
	"time"
)

func TestListenUnixServesHTTPAndRemovesStaleSocket(t *testing.T) {
	socketPath := filepath.Join(t.TempDir(), "http.sock")
	listener, err := ListenUnix(socketPath)
	if err != nil {
		t.Fatalf("ListenUnix: %v", err)
	}
	defer listener.Close()

	server := &http.Server{Handler: http.HandlerFunc(func(response http.ResponseWriter, _ *http.Request) {
		_, _ = response.Write([]byte("ok"))
	})}
	defer server.Shutdown(context.Background())
	go server.Serve(listener)

	client := &http.Client{Transport: &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "unix", socketPath)
	}}}
	response, err := client.Get("http://unix/health")
	if err != nil {
		t.Fatalf("GET over Unix socket: %v", err)
	}
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatal(err)
	}
	if string(body) != "ok" {
		t.Fatalf("unexpected body %q", body)
	}
}

func TestListenUnixRefusesToReplaceActiveUpdater(t *testing.T) {
	socketPath := filepath.Join(t.TempDir(), "http.sock")
	active, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatal(err)
	}
	defer active.Close()

	replacement, err := ListenUnix(socketPath)
	if replacement != nil {
		_ = replacement.Close()
	}
	if err == nil {
		t.Fatal("expected active updater socket to be preserved")
	}
	connection, err := net.DialTimeout("unix", socketPath, 100*time.Millisecond)
	if err != nil {
		t.Fatalf("active updater socket was displaced: %v", err)
	}
	_ = connection.Close()
}
