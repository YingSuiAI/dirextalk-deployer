package updater

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"path"
	"strings"
)

const (
	SupportedConfigVersion = 1

	AllowedComposeProject  = "dirextalk-p2p"
	AllowedComposeFile     = "/var/dirextalk-message-server/docker-compose.yml"
	AllowedImageRepository = "dirextalk/message-server"
)

var fixedServices = [...]string{"postgres", "message-init", "message-server", "caddy"}

func FixedServices() []string {
	return append([]string(nil), fixedServices[:]...)
}

type Config struct {
	SchemaVersion    int    `json:"schema_version"`
	StateDir         string `json:"state_dir"`
	SocketPath       string `json:"socket_path"`
	ControlTokenFile string `json:"control_token_file"`
}

func LoadConfig(reader io.Reader) (Config, error) {
	var config Config
	decoder := json.NewDecoder(reader)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&config); err != nil {
		return Config{}, fmt.Errorf("decode updater config: %w", err)
	}
	if err := ensureJSONEOF(decoder, "updater config"); err != nil {
		return Config{}, err
	}
	if config.SchemaVersion != SupportedConfigVersion {
		return Config{}, fmt.Errorf("schema_version %d is not supported", config.SchemaVersion)
	}
	if !pathWithin(config.StateDir, "/var/lib/dirextalk-updater") {
		return Config{}, fmt.Errorf("state_dir must be under /var/lib/dirextalk-updater")
	}
	if !pathWithin(config.SocketPath, "/run/dirextalk-updater") || path.Ext(config.SocketPath) != ".sock" {
		return Config{}, fmt.Errorf("socket_path must be a socket under /run/dirextalk-updater")
	}
	if !pathWithin(config.ControlTokenFile, "/etc/dirextalk-updater") {
		return Config{}, fmt.Errorf("control_token_file must be under /etc/dirextalk-updater")
	}
	return config, nil
}

func pathWithin(value, root string) bool {
	if strings.TrimSpace(value) != value || value == "" || !strings.HasPrefix(value, "/") {
		return false
	}
	clean := path.Clean(value)
	return clean == root || strings.HasPrefix(clean, root+"/")
}

func ensureJSONEOF(decoder *json.Decoder, subject string) error {
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		if err == nil {
			return fmt.Errorf("decode %s: multiple JSON values", subject)
		}
		return fmt.Errorf("decode %s: %w", subject, err)
	}
	return nil
}

type CommandKind string

const (
	CommandInspectRuntime CommandKind = "inspect_runtime"
	CommandCheckHealth    CommandKind = "check_health"
)

type Command struct {
	Kind CommandKind
}

func (command Command) Validate() error {
	switch command.Kind {
	case CommandInspectRuntime, CommandCheckHealth:
		return nil
	default:
		return fmt.Errorf("command %q is not allowed", command.Kind)
	}
}

type Result struct {
	Output []byte
}

type Runner interface {
	Run(context.Context, Command) (Result, error)
}

func decodeStrict(data []byte, target any, subject string) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return fmt.Errorf("decode %s: %w", subject, err)
	}
	return ensureJSONEOF(decoder, subject)
}
