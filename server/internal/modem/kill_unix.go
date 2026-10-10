//go:build !windows

package modem

import "syscall"

func killProcess(pid int) error {
	return syscall.Kill(pid, syscall.SIGTERM)
}
