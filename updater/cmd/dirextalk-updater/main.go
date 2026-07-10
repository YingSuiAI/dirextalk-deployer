package main

import (
	"context"
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
	if err := run(*configPath); err != nil {
		fmt.Fprintln(os.Stderr, "dirextalk-updater:", err)
		os.Exit(1)
	}
}

func run(configPath string) error {
	configFile, err := os.Open(configPath)
	if err != nil {
		return fmt.Errorf("open config: %w", err)
	}
	config, err := updater.LoadConfig(configFile)
	_ = configFile.Close()
	if err != nil {
		return err
	}
	controlToken, err := updater.LoadControlToken(config.ControlTokenFile)
	if err != nil {
		return err
	}
	service, err := updater.NewService(updater.NewStateStore(filepath.Join(config.StateDir, "runtime.json")), controlToken)
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
