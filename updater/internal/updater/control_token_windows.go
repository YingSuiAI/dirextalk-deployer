//go:build windows

package updater

import "os"

func validateControlTokenFile(os.FileInfo) error {
	return nil
}
