package main

import (
	"regexp"
	"strconv"
	"strings"
)

// Hardware is what the wizard learns about the PC. Nothing here identifies the owner.
type Hardware struct {
	Demo        bool     `json:"demo"`
	CPU         string   `json:"cpu"`
	Cores       int      `json:"cores"`
	Maker       string   `json:"maker"`
	Board       string   `json:"board"`
	Laptop      bool     `json:"laptop"`
	UEFI        bool     `json:"uefi"`
	SecureBoot  bool     `json:"secureBoot"`
	BitLocker   string   `json:"bitLocker"`
	FastStartup bool     `json:"fastStartup"`
	Windows     string   `json:"windows"`
	FreeGB      int      `json:"freeGB"`
	GPUs        []Device `json:"gpus"`
	Network     []Device `json:"network"`
	Bluetooth   []Device `json:"bluetooth"`
	Storage     []string `json:"storage"`
	NVMe        bool     `json:"nvme"`
	VMD         bool     `json:"vmd"`
}

type Device struct {
	Name   string `json:"name"`
	Vendor string `json:"vendor"`
	Device string `json:"device"`
}

// MacOSVersion holds the recovery values published in OpenCorePkg's recovery_urls.txt.
type MacOSVersion struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Board string `json:"-"`
	Kind  string `json:"-"`
}

var (
	sequoia = MacOSVersion{ID: "sequoia", Name: "macOS 15 Sequoia", Board: "Mac-7BA5B2D9E42DDD94", Kind: "default"}
	tahoe   = MacOSVersion{ID: "tahoe", Name: "macOS 26 Tahoe", Board: "Mac-CFF7D910A743CAAF", Kind: "latest"}
)

// Plan is everything needed to build the EFI, plus what the person should know.
type Plan struct {
	Supported bool              `json:"supported"`
	Platform  string            `json:"platform"`
	Reason    string            `json:"reason"`
	SMBIOS    string            `json:"smbios"`
	Versions  []MacOSVersion    `json:"versions"`
	Parts     []PartResult      `json:"parts"`
	Kexts     []KextSource      `json:"kexts"`
	SSDTs     []string          `json:"ssdts"`
	BootArgs  []string          `json:"bootArgs"`
	Later     []string          `json:"later"`
	IGPU      map[string]string `json:"-"`
	CometLake bool              `json:"-"`
	Z390      bool              `json:"-"`
	HP        bool              `json:"-"`
}

type PartResult struct {
	Name   string `json:"name"`
	Status string `json:"status"` // good, warn, bad
	Note   string `json:"note"`
}

// KextSource is one kext and the official project release it comes from.
type KextSource struct {
	Bundle string `json:"bundle"`
	Repo   string `json:"repo"`
	Why    string `json:"why"`
}

var cpuPattern = regexp.MustCompile(`(?i)\bi[3579]-(\d{4,5})([A-Z]*)\b`)

// intelGeneration returns the generation and suffix of an Intel Core CPU name, or 0 if it isn't one.
func intelGeneration(cpu string) (int, string) {
	m := cpuPattern.FindStringSubmatch(cpu)
	if m == nil {
		return 0, ""
	}
	number := m[1]
	digits := 1
	if len(number) == 5 {
		digits = 2
	}
	gen, err := strconv.Atoi(number[:digits])
	if err != nil {
		return 0, ""
	}
	return gen, strings.ToUpper(m[2])
}

// BuildPlan decides what this PC can get. It only builds an EFI for platforms whose values
// come straight from the Dortania guide, and it says so plainly for everything else.
func BuildPlan(hw Hardware, chosen string) Plan {
	plan := Plan{IGPU: map[string]string{}}
	gen, suffix := intelGeneration(hw.CPU)
	mobile := hw.Laptop || strings.ContainsAny(suffix, "HUGY")

	switch {
	case strings.Contains(strings.ToUpper(hw.CPU), "AMD") || strings.Contains(strings.ToUpper(hw.CPU), "RYZEN"):
		plan.Reason = "AMD processors need kernel patches matched to the exact core count, so this version won't generate that setup."
	case gen == 0:
		plan.Reason = "This processor isn't one this version can identify."
	case mobile:
		plan.Reason = "Laptops need setup specific to the model, such as trackpad, battery and display patches, so this version won't generate one."
	case gen == 8 || gen == 9:
		plan.Supported, plan.Platform, plan.SMBIOS = true, "Coffee Lake desktop", "iMac19,1"
		plan.Versions = []MacOSVersion{sequoia}
		plan.Z390 = strings.Contains(strings.ToUpper(hw.Board), "Z390")
		plan.SSDTs = []string{"SSDT-PLUG-DRTNIA", "SSDT-EC-USBX-DESKTOP", "SSDT-AWAC"}
		if true300Series(hw.Board) {
			plan.SSDTs = append(plan.SSDTs, "SSDT-PMC")
		}
	case gen == 10:
		plan.Supported, plan.Platform, plan.SMBIOS, plan.CometLake = true, "Comet Lake desktop", "iMac20,1", true
		if hw.Cores >= 10 {
			plan.SMBIOS = "iMac20,2"
		}
		plan.Versions = []MacOSVersion{sequoia, tahoe}
		plan.SSDTs = []string{"SSDT-PLUG-DRTNIA", "SSDT-EC-USBX-DESKTOP", "SSDT-AWAC"}
		if strings.Contains(strings.ToUpper(hw.Board), "Z490") && strings.Contains(strings.ToUpper(hw.Maker), "ASUS") {
			plan.SSDTs = append(plan.SSDTs, "SSDT-RHUB")
		}
	default:
		plan.Reason = "This generation of Intel processor isn't one this version can generate a setup for yet."
	}
	plan.HP = strings.Contains(strings.ToUpper(hw.Maker), "HP") || strings.Contains(strings.ToUpper(hw.Maker), "HEWLETT")

	plan.Parts = append(plan.Parts, cpuPart(hw, plan))
	gpuParts, hasAMD, hasNvidia, hasIntelGPU := gpuResults(hw)
	plan.Parts = append(plan.Parts, gpuParts...)
	if hw.VMD {
		plan.Parts = append(plan.Parts, PartResult{"Intel VMD", "bad", "Turn off VMD in your BIOS, or macOS can't see your NVMe drive."})
	}
	if !hw.UEFI {
		plan.Parts = append(plan.Parts, PartResult{"Startup mode", "bad", "Windows is using Legacy mode. This wizard only prepares UEFI USB drives."})
	}

	plan.Kexts = []KextSource{
		{"Lilu.kext", "acidanthera/Lilu", "Needed by most other drivers"},
		{"VirtualSMC.kext", "acidanthera/VirtualSMC", "Lets macOS start on non-Apple hardware"},
		{"SMCProcessor.kext", "acidanthera/VirtualSMC", "Reads processor temperatures"},
		{"SMCSuperIO.kext", "acidanthera/VirtualSMC", "Reads fan speeds"},
		{"WhateverGreen.kext", "acidanthera/WhateverGreen", "Fixes graphics"},
		{"AppleALC.kext", "acidanthera/AppleALC", "Audio"},
		{"USBToolBox.kext", "USBToolBox/kext", "USB port support"},
		{"UTBDefault.kext", "USBToolBox/kext", "Temporary USB map for installing"},
	}
	if hw.NVMe {
		plan.Kexts = append(plan.Kexts, KextSource{"NVMeFix.kext", "acidanthera/NVMeFix", "NVMe drive power and reliability"})
	}
	plan.BootArgs = []string{"-v", "debug=0x100", "keepsyms=1", "alcid=1"}

	plan.addNetwork(hw)
	plan.addBluetooth(hw)

	if plan.Supported {
		switch {
		case hasAMD:
			plan.IGPU = headless(plan.CometLake)
		case hasIntelGPU:
			plan.IGPU = display()
		}
		if hasNvidia {
			plan.BootArgs = append(plan.BootArgs, "-wegnoegpu")
			plan.Later = append(plan.Later, "NVIDIA graphics can't load during install. The USB turns the card off so macOS starts on Intel graphics. After installing, you can try the NullMoth driver with its 1401 app, and -wegnoegpu must be removed first.")
			if !hasIntelGPU {
				plan.Supported = false
				plan.Reason = "macOS can't start on this NVIDIA card without a driver, and no Intel graphics were found to use during install."
			}
		}
	}

	if chosen == tahoe.ID && plan.Supported && plan.CometLake {
		plan.Kexts = append(plan.Kexts, KextSource{"SimpleHDA.kext", "laobamac/SimpleHDA", "Tahoe removed the built-in audio driver"})
	}
	plan.Later = append(plan.Later,
		"Your USB map is temporary. Build a real one with USBToolBox, or some ports may stay slow.",
		"This USB uses placeholder serial numbers, so iCloud and iMessage may not work until you set up your own.",
		"Wi-Fi drivers depend on your exact macOS version, so install them after macOS, using Hackintosh Simplified for Mac.")
	return plan
}

func cpuPart(hw Hardware, plan Plan) PartResult {
	if plan.Supported {
		return PartResult{"Processor", "good", hw.CPU + ": " + plan.Platform}
	}
	return PartResult{"Processor", "bad", plan.Reason}
}

func gpuResults(hw Hardware) (parts []PartResult, amd, nvidia, intel bool) {
	for _, gpu := range hw.GPUs {
		switch strings.ToUpper(gpu.Vendor) {
		case "8086":
			intel = true
			parts = append(parts, PartResult{gpu.Name, "good", "Works in macOS with Intel graphics support"})
		case "1002":
			amd = true
			parts = append(parts, PartResult{gpu.Name, "warn", "Many AMD cards work natively, but check your exact model in the Dortania GPU guide."})
		case "10DE":
			nvidia = true
			parts = append(parts, PartResult{gpu.Name, "warn", "macOS has no driver for modern NVIDIA cards. A community driver may work after installing."})
		default:
			parts = append(parts, PartResult{gpu.Name, "warn", "Unknown graphics card"})
		}
	}
	return
}

func display() map[string]string {
	return map[string]string{"AAPL,ig-platform-id": "07009B3E", "framebuffer-patch-enable": "01000000", "framebuffer-stolenmem": "00003001"}
}

func headless(comet bool) map[string]string {
	if comet {
		return map[string]string{"AAPL,ig-platform-id": "0300C89B"}
	}
	return map[string]string{"AAPL,ig-platform-id": "0300913E"}
}

func (plan *Plan) addNetwork(hw Hardware) {
	for _, nic := range hw.Network {
		vendor, device := strings.ToUpper(nic.Vendor), strings.ToUpper(nic.Device)
		switch {
		case vendor == "8086" && (device == "15F2" || device == "15F3" || device == "125B" || device == "125C"):
			plan.BootArgs = append(plan.BootArgs, "e1000=0")
			plan.Parts = append(plan.Parts, PartResult{nic.Name, "warn", "Intel 2.5 Gb Ethernet can need extra setup, depending on macOS and the chip revision."})
		case vendor == "8086" && isWiFi(nic.Name):
			plan.Parts = append(plan.Parts, PartResult{nic.Name, "warn", "Needs a community driver after installing. AirDrop usually won't work."})
		case vendor == "8086":
			plan.addKext("IntelMausi.kext", "acidanthera/IntelMausi", "Ethernet")
			plan.Parts = append(plan.Parts, PartResult{nic.Name, "good", "Ethernet driver will be included"})
		case vendor == "10EC" && device == "8125":
			plan.addKext("LucyRTL8125Ethernet.kext", "Mieze/LucyRTL8125Ethernet", "2.5 Gb Ethernet")
			plan.Parts = append(plan.Parts, PartResult{nic.Name, "good", "Ethernet driver will be included"})
		case vendor == "10EC" && isWiFi(nic.Name):
			plan.Parts = append(plan.Parts, PartResult{nic.Name, "warn", "Realtek Wi-Fi drivers are experimental and can be very slow. AirDrop won't work."})
		case vendor == "10EC":
			plan.addKext("RealtekRTL8111.kext", "Mieze/RTL8111_driver_for_OS_X", "Ethernet")
			plan.Parts = append(plan.Parts, PartResult{nic.Name, "good", "Ethernet driver will be included"})
		case vendor == "14E4" && isWiFi(nic.Name):
			plan.Parts = append(plan.Parts, PartResult{nic.Name, "warn", "On recent macOS, Broadcom Wi-Fi needs extra patches after installing."})
		default:
			plan.Parts = append(plan.Parts, PartResult{nic.Name, "warn", "No driver is known for this network part. A wired USB adapter may be needed."})
		}
	}
}

func (plan *Plan) addBluetooth(hw Hardware) {
	for _, bt := range hw.Bluetooth {
		vendor := strings.ToUpper(bt.Vendor)
		switch {
		case vendor == "8087":
			plan.addKext("BlueToolFixup.kext", "acidanthera/BrcmPatchRAM", "Bluetooth support")
			plan.addKext("IntelBluetoothFirmware.kext", "OpenIntelWireless/IntelBluetoothFirmware", "Intel Bluetooth")
		case vendor == "0BDA" || strings.Contains(strings.ToUpper(bt.Name), "REALTEK"):
			plan.addKext("BlueToolFixup.kext", "acidanthera/BrcmPatchRAM", "Bluetooth support")
			plan.addKext("RealtekBluetoothFirmware.kext", "thegwchr/RealtekBluetoothFirmware", "Realtek Bluetooth")
			plan.Parts = append(plan.Parts, PartResult{bt.Name, "warn", "Realtek Bluetooth can be limited on recent macOS, even with its driver."})
		case vendor == "0A5C":
			plan.addKext("BlueToolFixup.kext", "acidanthera/BrcmPatchRAM", "Bluetooth support")
			plan.addKext("BrcmFirmwareData.kext", "acidanthera/BrcmPatchRAM", "Broadcom Bluetooth firmware")
			plan.addKext("BrcmPatchRAM3.kext", "acidanthera/BrcmPatchRAM", "Broadcom Bluetooth")
		}
	}
}

func (plan *Plan) addKext(bundle, repo, why string) {
	for _, k := range plan.Kexts {
		if k.Bundle == bundle {
			return
		}
	}
	plan.Kexts = append(plan.Kexts, KextSource{bundle, repo, why})
}

func isWiFi(name string) bool {
	n := strings.ToUpper(name)
	for _, word := range []string{"WI-FI", "WIFI", "WIRELESS", "802.11", "WLAN"} {
		if strings.Contains(n, word) {
			return true
		}
	}
	return false
}

// true300Series is the chipset list Dortania's Coffee Lake page gives for SSDT-PMC.
func true300Series(board string) bool {
	b := strings.ToUpper(board)
	for _, chipset := range []string{"Z390", "B360", "B365", "H310", "H370", "Q370"} {
		if strings.Contains(b, chipset) {
			return true
		}
	}
	return false
}
