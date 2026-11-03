//go:build !windows

package main

import "os/exec"

func hideWindow(*exec.Cmd) {}

func ensureAdmin() {}

func testDiskAllowed(USBDisk) bool { return false }
