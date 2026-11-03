//go:build windows

package main

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
	"syscall"
)

const createNoWindow = 0x08000000

func hideWindow(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: createNoWindow}
}

// ensureAdmin restarts the wizard through Windows' permission prompt. Erasing a USB needs it.
func ensureAdmin() {
	check, err := powershell(`([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)`)
	if err != nil || strings.Contains(check, "True") {
		return
	}
	self, err := os.Executable()
	if err != nil {
		return
	}
	escaped := strings.ReplaceAll(self, "'", "''")
	_, err = powershell(fmt.Sprintf("Start-Process -FilePath '%s' -Verb RunAs", escaped))
	if err != nil {
		fmt.Println("This wizard needs administrator permission to prepare a USB drive. Allow the prompt to continue.")
		fmt.Println("Press Enter to close.")
		fmt.Scanln()
		os.Exit(1)
	}
	os.Exit(0)
}

// testDiskAllowed lets the automated test erase a temporary virtual disk, never a real one.
func testDiskAllowed(d USBDisk) bool {
	return os.Getenv("HS_ALLOW_VIRTUAL_TEST_DISK") == "1" && strings.EqualFold(d.Bus, "File Backed Virtual")
}
