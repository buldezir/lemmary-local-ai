package main

import "syscall"

// killedWithUs has the kernel kill a child when this process dies: a
// llama-server or OCR worker outliving it would hold its model in memory
// beside the next one's. The Mac app reaps those through pid files.
func killedWithUs() *syscall.SysProcAttr {
	return &syscall.SysProcAttr{Pdeathsig: syscall.SIGKILL}
}
