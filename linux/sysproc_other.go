//go:build !linux

package main

import "syscall"

// killedWithUs has no equivalent elsewhere; it is here so the tests run on a
// Mac too.
func killedWithUs() *syscall.SysProcAttr {
	return &syscall.SysProcAttr{}
}
