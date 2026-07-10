package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/YingSuiAI/dirextalk-deployer/updater/internal/updater"
)

func main() {
	configPath := flag.String("config", "/etc/dirextalk-updater/config.json", "root-owned updater configuration")
	flag.Parse()
	command := "serve"
	if flag.NArg() > 0 {
		command = flag.Arg(0)
	}
	var err error
	switch command {
	case "serve":
		err = runServer(*configPath)
	case "resolve-release":
		err = resolveRelease()
	case "trigger-discovery":
		err = triggerDiscovery(*configPath)
	default:
		err = fmt.Errorf("unknown command %q", command)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "dirextalk-updater:", err)
		os.Exit(1)
	}
}

func runServer(configPath string) error {
	config, controlToken, err := loadRuntimeConfig(configPath)
	if err != nil {
		return err
	}
	service, err := updater.NewService(
		updater.NewStateStore(filepath.Join(config.StateDir, "runtime.json")),
		controlToken,
		updater.WithReleaseSource(updater.NewGitHubReleaseSource(&http.Client{Timeout: 30 * time.Second})),
	)
	if err != nil {
		return err
	}
	listener, err := updater.ListenUnix(config.SocketPath)
	if err != nil {
		return err
	}
	defer listener.Close()
	server := &http.Server{Handler: service.Handler(), ReadHeaderTimeout: 5 * time.Second}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = server.Shutdown(shutdownCtx)
	}()
	if err := server.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return fmt.Errorf("serve updater API: %w", err)
	}
	return nil
}

func loadRuntimeConfig(configPath string) (updater.Config, string, error) {
	configFile, err := os.Open(configPath)
	if err != nil {
		return updater.Config{}, "", fmt.Errorf("open config: %w", err)
	}
	config, err := updater.LoadConfig(configFile)
	_ = configFile.Close()
	if err != nil {
		return updater.Config{}, "", err
	}
	controlToken, err := updater.LoadControlToken(config.ControlTokenFile)
	if err != nil {
		return updater.Config{}, "", err
	}
	return config, controlToken, nil
}

func resolveRelease() error {
	resolved, err := updater.NewGitHubReleaseSource(&http.Client{Timeout: 30 * time.Second}).Resolve(context.Background())
	if err != nil {
		return err
	}
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	return encoder.Encode(resolved)
}

func triggerDiscovery(configPath string) error {
	config, controlToken, err := loadRuntimeConfig(configPath)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	return updater.TriggerDiscovery(ctx, config.SocketPath, controlToken)
}
