//go:build !windows

package updater

import (
	"fmt"
	"os"
	"syscall"
)

func validateControlTokenFile(info os.FileInfo) error {
	if info.Mode().Perm()&0o077 != 0 {
		return fmt.Errorf("control token file must not be accessible by group or other users")
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != uint32(os.Geteuid()) {
		return fmt.Errorf("control token file must be owned by the updater service user")
	}
	return nil
}
