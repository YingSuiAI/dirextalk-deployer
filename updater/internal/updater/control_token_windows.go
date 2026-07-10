//go:build windows

package updater

import (
	"fmt"
	"os"
)

func validateControlTokenFile(os.FileInfo) error {
	return fmt.Errorf("control-token ACL validation is not implemented on Windows; updater execution is Linux-only")
}
