package main

import (
	"encoding/json"
	"fmt"
	"os/exec"
	"regexp"
	"runtime"
	"strings"
)

// USBDisk is a disk the wizard may offer for erasing.
type USBDisk struct {
	Number int    `json:"number"`
	Name   string `json:"name"`
	SizeGB int    `json:"sizeGB"`
	Bus    string `json:"bus"`
	System bool   `json:"system"`
	Boot   bool   `json:"boot"`
}

func powershell(script string) (string, error) {
	cmd := exec.Command("powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command",
		"$ErrorActionPreference='Stop'; [Console]::OutputEncoding=[Text.Encoding]::UTF8; "+script)
	hideWindow(cmd)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("%s", lastLines(string(output), 8))
	}
	return string(output), nil
}

const hardwareScript = `
$c = Get-CimInstance Win32_Processor | Select-Object -First 1
$cs = Get-CimInstance Win32_ComputerSystem
$b = Get-CimInstance Win32_BaseBoard | Select-Object -First 1
$uefi = $false; $sb = $false
try { $sb = [bool](Confirm-SecureBootUEFI); $uefi = $true } catch { if ($_.Exception.Message -notmatch 'not supported') { $uefi = $true } }
$fs = 0; try { $fs = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power').HiberbootEnabled } catch {}
$bl = 'Unknown'; try { $bl = [string](Get-BitLockerVolume -MountPoint $env:SystemDrive).ProtectionStatus } catch {}
$disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'"
$pci = @(Get-CimInstance Win32_PnPEntity | Where-Object { $_.PNPDeviceID -match '^(PCI|USB)\\VEN_|^USB\\VID_|^PCI\\VEN_' })
$map = { param($d) [pscustomobject]@{ name=$d.Name; id=$d.PNPDeviceID } }
[pscustomobject]@{
  cpu=$c.Name.Trim(); cores=$c.NumberOfCores; maker=$cs.Manufacturer; board=$b.Product
  laptop=[bool]($cs.PCSystemType -eq 2); uefi=$uefi; secureBoot=$sb; fastStartup=[bool]($fs -eq 1); bitLocker=$bl
  windows=(Get-CimInstance Win32_OperatingSystem).Caption; freeGB=[int]($disk.FreeSpace/1GB)
  gpus=@(Get-CimInstance Win32_VideoController | ForEach-Object { [pscustomobject]@{ name=$_.Name; id=$_.PNPDeviceID } })
  network=@(Get-CimInstance Win32_NetworkAdapter -Filter 'PhysicalAdapter=True' | Where-Object { $_.PNPDeviceID -match '^PCI' } | ForEach-Object { [pscustomobject]@{ name=$_.Name; id=$_.PNPDeviceID } })
  bluetooth=@(Get-CimInstance Win32_PnPEntity -Filter "PNPClass='Bluetooth'" | Where-Object { $_.PNPDeviceID -match '^USB\\VID_' } | ForEach-Object { [pscustomobject]@{ name=$_.Name; id=$_.PNPDeviceID } })
  storage=@(Get-PhysicalDisk | ForEach-Object { '{0} ({1})' -f $_.FriendlyName, $_.BusType })
  nvme=[bool](Get-PhysicalDisk | Where-Object { $_.BusType -eq 'NVMe' })
  vmd=[bool]($pci | Where-Object { $_.Name -match 'Volume Management Device|VMD' })
} | ConvertTo-Json -Depth 4 -Compress
`

type rawDevice struct {
	Name string `json:"name"`
	ID   string `json:"id"`
}

type rawHardware struct {
	CPU         string      `json:"cpu"`
	Cores       int         `json:"cores"`
	Maker       string      `json:"maker"`
	Board       string      `json:"board"`
	Laptop      bool        `json:"laptop"`
	UEFI        bool        `json:"uefi"`
	SecureBoot  bool        `json:"secureBoot"`
	FastStartup bool        `json:"fastStartup"`
	BitLocker   string      `json:"bitLocker"`
	Windows     string      `json:"windows"`
	FreeGB      int         `json:"freeGB"`
	GPUs        []rawDevice `json:"gpus"`
	Network     []rawDevice `json:"network"`
	Bluetooth   []rawDevice `json:"bluetooth"`
	Storage     []string    `json:"storage"`
	NVMe        bool        `json:"nvme"`
	VMD         bool        `json:"vmd"`
}

var (
	pciID = regexp.MustCompile(`(?i)VEN_([0-9A-F]{4})&DEV_([0-9A-F]{4})`)
	usbID = regexp.MustCompile(`(?i)VID_([0-9A-F]{4})&PID_([0-9A-F]{4})`)
)

func parseDevice(raw rawDevice) Device {
	d := Device{Name: raw.Name}
	if m := pciID.FindStringSubmatch(raw.ID); m != nil {
		d.Vendor, d.Device = strings.ToUpper(m[1]), strings.ToUpper(m[2])
	} else if m := usbID.FindStringSubmatch(raw.ID); m != nil {
		d.Vendor, d.Device = strings.ToUpper(m[1]), strings.ToUpper(m[2])
	}
	return d
}

func parseDevices(raw []rawDevice) []Device {
	out := []Device{}
	seen := map[string]bool{}
	for _, item := range raw {
		d := parseDevice(item)
		key := d.Vendor + d.Device + d.Name
		if !seen[key] {
			seen[key] = true
			out = append(out, d)
		}
	}
	return out
}

func parseHardware(text string) (Hardware, error) {
	var raw rawHardware
	if err := json.Unmarshal([]byte(text), &raw); err != nil {
		return Hardware{}, fmt.Errorf("couldn't read the hardware report: %w", err)
	}
	storage := raw.Storage
	if storage == nil {
		storage = []string{}
	}
	return Hardware{
		CPU: raw.CPU, Cores: raw.Cores, Maker: raw.Maker, Board: raw.Board, Laptop: raw.Laptop, UEFI: raw.UEFI, SecureBoot: raw.SecureBoot,
		BitLocker: raw.BitLocker, FastStartup: raw.FastStartup, Windows: raw.Windows, FreeGB: raw.FreeGB,
		GPUs: parseDevices(raw.GPUs), Network: parseDevices(raw.Network), Bluetooth: parseDevices(raw.Bluetooth),
		Storage: storage, NVMe: raw.NVMe, VMD: raw.VMD,
	}, nil
}

// ScanHardware reads this PC. Outside Windows it returns a clearly marked demo, for testing the wizard.
func ScanHardware() (Hardware, error) {
	if runtime.GOOS != "windows" {
		return demoHardware(), nil
	}
	output, err := powershell(hardwareScript)
	if err != nil {
		return Hardware{}, err
	}
	return parseHardware(output)
}

func demoHardware() Hardware {
	return Hardware{
		Demo: true, CPU: "Intel(R) Core(TM) i7-10700K CPU @ 3.80GHz", Cores: 8, Maker: "Demo Maker", Board: "Z490 DEMO", UEFI: true, BitLocker: "Off",
		FastStartup: true, Windows: "Demo mode, not a real PC", FreeGB: 180,
		GPUs:    []Device{{"Intel(R) UHD Graphics 630", "8086", "9BC5"}, {"NVIDIA GeForce RTX 3060", "10DE", "2504"}},
		Network: []Device{{"Intel(R) Ethernet Connection I219-V", "8086", "0D4C"}, {"Intel(R) Wi-Fi 6 AX200 160MHz", "8086", "2723"}},
		Storage: []string{"Demo NVMe SSD (NVMe)"}, NVMe: true,
	}
}

const usbScript = `
@(Get-Disk | ForEach-Object { [pscustomobject]@{ number=$_.Number; name=$_.FriendlyName; sizeGB=[int]($_.Size/1GB); bus=[string]$_.BusType; system=[bool]$_.IsSystem; boot=[bool]$_.IsBoot } }) | ConvertTo-Json -Compress
`

// EraseAllowed is the one rule for which disks can ever be erased.
func EraseAllowed(d USBDisk) error {
	switch {
	case d.System || d.Boot:
		return fmt.Errorf("that disk runs Windows, so it can't be erased")
	case !strings.EqualFold(d.Bus, "USB") && !testDiskAllowed(d):
		return fmt.Errorf("that isn't a USB drive, so it can't be erased")
	case d.SizeGB < 8:
		return fmt.Errorf("that drive is too small. Use one with at least 16 GB")
	case d.SizeGB > 2048:
		return fmt.Errorf("that drive is larger than 2 TB, which is unusual for a USB stick, so it won't be erased")
	}
	return nil
}

func parseDisks(text string) ([]USBDisk, error) {
	text = strings.TrimSpace(text)
	if text == "" {
		return []USBDisk{}, nil
	}
	if !strings.HasPrefix(text, "[") {
		text = "[" + text + "]"
	}
	var disks []USBDisk
	return disks, json.Unmarshal([]byte(text), &disks)
}

// ListUSB returns only disks that pass EraseAllowed. Outside Windows there are none.
func ListUSB() ([]USBDisk, error) {
	if runtime.GOOS != "windows" {
		return []USBDisk{}, nil
	}
	output, err := powershell(usbScript)
	if err != nil {
		return nil, err
	}
	disks, err := parseDisks(output)
	if err != nil {
		return nil, err
	}
	allowed := []USBDisk{}
	for _, d := range disks {
		if EraseAllowed(d) == nil {
			allowed = append(allowed, d)
		}
	}
	return allowed, nil
}

// FormatUSB erases the disk and returns the new FAT32 volume's root, such as "E:\".
// It reads the disk again first, so a stale or forged number can't erase the wrong drive.
func FormatUSB(number int) (string, error) {
	if runtime.GOOS != "windows" {
		return "", fmt.Errorf("this only works on Windows")
	}
	output, err := powershell(usbScript)
	if err != nil {
		return "", err
	}
	disks, err := parseDisks(output)
	if err != nil {
		return "", err
	}
	var target *USBDisk
	for i := range disks {
		if disks[i].Number == number {
			target = &disks[i]
		}
	}
	if target == nil {
		return "", fmt.Errorf("that drive isn't connected anymore")
	}
	if err := EraseAllowed(*target); err != nil {
		return "", err
	}
	// FAT32 can't be formatted above 32 GB here, and 16 GB is plenty, so the partition stops there.
	script := fmt.Sprintf(`
$n=%d
$d=Get-Disk -Number $n
if ($d.IsSystem -or $d.IsBoot) { throw 'Refusing to erase the Windows disk' }
if ($d.IsOffline) { Set-Disk -Number $n -IsOffline $false }
if ($d.IsReadOnly) { Set-Disk -Number $n -IsReadOnly $false }
if ($d.PartitionStyle -ne 'RAW') { Clear-Disk -Number $n -RemoveData -RemoveOEM -Confirm:$false }
Initialize-Disk -Number $n -PartitionStyle GPT -ErrorAction SilentlyContinue
$size=[Math]::Min(16GB, (Get-Disk -Number $n).LargestFreeExtent)
$p=New-Partition -DiskNumber $n -Size $size -AssignDriveLetter
$v=Format-Volume -Partition $p -FileSystem FAT32 -NewFileSystemLabel 'OPENCORE' -Force -Confirm:$false
$v.DriveLetter`, number)
	output, err = powershell(script)
	if err != nil {
		return "", err
	}
	lines := strings.Fields(strings.TrimSpace(output))
	if len(lines) == 0 || len(lines[len(lines)-1]) != 1 {
		return "", fmt.Errorf("the USB was formatted, but Windows didn't report its drive letter")
	}
	return lines[len(lines)-1] + `:\`, nil
}
