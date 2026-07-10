package updater

import (
	"fmt"
	"os"
	"strings"
)

const maxControlTokenBytes = 4096

func LoadControlToken(path string) (string, error) {
	info, err := os.Stat(path)
	if err != nil {
		return "", fmt.Errorf("read control token metadata: %w", err)
	}
	if !info.Mode().IsRegular() {
		return "", fmt.Errorf("control token must be a regular file")
	}
	if info.Size() > maxControlTokenBytes {
		return "", fmt.Errorf("control token file is too large")
	}
	if err := validateControlTokenFile(info); err != nil {
		return "", err
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("read control token: %w", err)
	}
	token := strings.TrimSpace(string(data))
	for index := range data {
		data[index] = 0
	}
	if len(token) < 32 {
		return "", fmt.Errorf("control token is missing or too short")
	}
	return token, nil
}
