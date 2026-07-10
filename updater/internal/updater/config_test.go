package updater

import (
	"strings"
	"testing"
)

func TestLoadConfigAcceptsOnlyUpdaterOwnedPaths(t *testing.T) {
	config, err := LoadConfig(strings.NewReader(`{
		"schema_version": 1,
		"state_dir": "/var/lib/dirextalk-updater",
		"socket_path": "/run/dirextalk-updater/http.sock",
		"control_token_file": "/etc/dirextalk-updater/control-token"
	}`))
	if err != nil {
		t.Fatalf("LoadConfig: %v", err)
	}
	if config.StateDir != "/var/lib/dirextalk-updater" || config.SocketPath != "/run/dirextalk-updater/http.sock" {
		t.Fatalf("unexpected config: %#v", config)
	}
}

func TestLoadConfigRejectsInfrastructureAndUnknownFields(t *testing.T) {
	for _, field := range []string{"shell", "compose_path", "service", "image", "digest"} {
		t.Run(field, func(t *testing.T) {
			_, err := LoadConfig(strings.NewReader(`{
				"schema_version": 1,
				"state_dir": "/var/lib/dirextalk-updater",
				"socket_path": "/run/dirextalk-updater/http.sock",
				"control_token_file": "/etc/dirextalk-updater/control-token",
				"` + field + `": "attacker-controlled"
			}`))
			if err == nil || !strings.Contains(err.Error(), "unknown field") {
				t.Fatalf("expected unknown %s field rejection, got %v", field, err)
			}
		})
	}
}

func TestConfigRejectsPathsOutsideUpdaterRoots(t *testing.T) {
	_, err := LoadConfig(strings.NewReader(`{
		"schema_version": 1,
		"state_dir": "/tmp/updater",
		"socket_path": "/tmp/http.sock",
		"control_token_file": "/tmp/token"
	}`))
	if err == nil {
		t.Fatal("expected unsafe updater paths to be rejected")
	}
}

func TestRunnerCommandAllowlistIsFixed(t *testing.T) {
	for _, kind := range []CommandKind{CommandInspectRuntime, CommandCheckHealth} {
		if err := (Command{Kind: kind}).Validate(); err != nil {
			t.Fatalf("expected %q to be allowed: %v", kind, err)
		}
	}
	if err := (Command{Kind: CommandKind("sh -c attacker")}).Validate(); err == nil {
		t.Fatal("expected unknown command to be rejected")
	}
	if AllowedComposeProject != "dirextalk-p2p" || AllowedComposeFile != "/var/dirextalk-message-server/docker-compose.yml" {
		t.Fatalf("unexpected fixed compose identity: %s %s", AllowedComposeProject, AllowedComposeFile)
	}
	services := FixedServices()
	if len(services) != 4 || AllowedImageRepository != "dirextalk/message-server" {
		t.Fatalf("unexpected fixed allowlist: services=%v image=%s", services, AllowedImageRepository)
	}
	services[0] = "attacker"
	if FixedServices()[0] == "attacker" {
		t.Fatal("callers must not be able to mutate the fixed service allowlist")
	}
}
