package main

import (
	"archive/zip"
	"crypto/sha256"
	"encoding/binary"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"howett.net/plist"
)

func desktop(cpu, board string, gpus ...Device) Hardware {
	return Hardware{CPU: cpu, Cores: 8, Board: board, Maker: "ASUSTeK", UEFI: true, GPUs: gpus}
}

var (
	intelGPU  = Device{"Intel UHD", "8086", "9BC5"}
	nvidiaGPU = Device{"RTX 3060", "10DE", "2504"}
	amdGPU    = Device{"RX 580", "1002", "67DF"}
)

func TestGeneration(t *testing.T) {
	cases := map[string]int{"Intel(R) Core(TM) i7-10700K CPU": 10, "Intel(R) Core(TM) i5-9400F": 9, "Intel Core i7-14650HX": 14, "AMD Ryzen 7 5800X": 0}
	for cpu, want := range cases {
		if got, _ := intelGeneration(cpu); got != want {
			t.Errorf("%s: got %d, want %d", cpu, got, want)
		}
	}
}

func TestPlanRefusesWhatItCannotDo(t *testing.T) {
	for name, hw := range map[string]Hardware{
		"AMD":           desktop("AMD Ryzen 7 5800X", "X570", amdGPU),
		"laptop name":   desktop("Intel Core i7-10750H", "X", intelGPU),
		"new gen":       desktop("Intel Core i9-14900K", "Z790", intelGPU),
		"NVIDIA only":   desktop("Intel Core i5-10400F", "B460", nvidiaGPU),
		"marked laptop": {CPU: "Intel Core i7-10700", Laptop: true, GPUs: []Device{intelGPU}},
	} {
		plan := BuildPlan(hw, "")
		if plan.Supported || plan.Reason == "" {
			t.Errorf("%s should be refused with a reason, got %+v", name, plan.Supported)
		}
	}
}

func TestCoffeeAndCometValues(t *testing.T) {
	coffee := BuildPlan(desktop("Intel Core i7-9700K", "Z390 AORUS", intelGPU), "")
	if !coffee.Supported || coffee.SMBIOS != "iMac19,1" || !coffee.Z390 || len(coffee.Versions) != 1 {
		t.Fatalf("coffee: %+v", coffee)
	}
	if !contains(coffee.SSDTs, "SSDT-PMC") {
		t.Error("Z390 needs SSDT-PMC")
	}
	comet := BuildPlan(desktop("Intel Core i7-10700K", "Z490", intelGPU), "")
	if comet.SMBIOS != "iMac20,1" || comet.IGPU["AAPL,ig-platform-id"] != "07009B3E" {
		t.Fatalf("comet: %+v", comet)
	}
	big := desktop("Intel Core i9-10900K", "Z490", amdGPU, intelGPU)
	big.Cores = 10
	bigPlan := BuildPlan(big, "")
	if bigPlan.SMBIOS != "iMac20,2" || bigPlan.IGPU["AAPL,ig-platform-id"] != "0300C89B" {
		t.Fatalf("headless comet: %+v", bigPlan)
	}
}

func TestNvidiaIsTurnedOffOnlyForInstall(t *testing.T) {
	plan := BuildPlan(desktop("Intel Core i7-10700K", "Z490", intelGPU, nvidiaGPU), "")
	if !plan.Supported || !contains(plan.BootArgs, "-wegnoegpu") {
		t.Fatalf("%+v", plan)
	}
	if !strings.Contains(strings.Join(plan.Later, " "), "1401") {
		t.Error("should explain the driver comes after install")
	}
	for _, k := range plan.Kexts {
		if strings.HasPrefix(k.Bundle, "NV") {
			t.Errorf("must never inject NVIDIA kexts: %s", k.Bundle)
		}
	}
}

func TestDriversMatchHardware(t *testing.T) {
	hw := desktop("Intel Core i7-10700K", "Z490", intelGPU)
	hw.NVMe = true
	hw.Network = []Device{{"Realtek PCIe GbE", "10EC", "8168"}, {"Realtek 8125", "10EC", "8125"}, {"Intel I225-V", "8086", "15F3"}, {"Intel Wi-Fi 6", "8086", "2723"}}
	hw.Bluetooth = []Device{{"Intel Wireless Bluetooth", "8087", "0029"}}
	plan := BuildPlan(hw, tahoe.ID)
	bundles := []string{}
	for _, k := range plan.Kexts {
		bundles = append(bundles, k.Bundle)
	}
	for _, want := range []string{"Lilu.kext", "NVMeFix.kext", "RealtekRTL8111.kext", "LucyRTL8125Ethernet.kext", "BlueToolFixup.kext", "IntelBluetoothFirmware.kext", "SimpleHDA.kext"} {
		if !contains(bundles, want) {
			t.Errorf("missing %s in %v", want, bundles)
		}
	}
	if bundles[0] != "Lilu.kext" {
		t.Error("Lilu must load first")
	}
	if !contains(plan.BootArgs, "e1000=0") {
		t.Error("I225 needs e1000=0")
	}
	if contains(bundles, "IntelMausi.kext") {
		t.Error("Intel Wi-Fi and I225 must not get IntelMausi")
	}
}

func TestEraseRules(t *testing.T) {
	good := USBDisk{Number: 2, Bus: "USB", SizeGB: 32}
	if err := EraseAllowed(good); err != nil {
		t.Errorf("good USB refused: %v", err)
	}
	for name, d := range map[string]USBDisk{
		"Windows disk": {Bus: "USB", SizeGB: 32, System: true},
		"boot disk":    {Bus: "USB", SizeGB: 32, Boot: true},
		"internal":     {Bus: "NVMe", SizeGB: 512},
		"SATA":         {Bus: "SATA", SizeGB: 512},
		"too small":    {Bus: "USB", SizeGB: 4},
		"huge":         {Bus: "USB", SizeGB: 4000},
		"virtual":      {Bus: "File Backed Virtual", SizeGB: 32},
	} {
		if EraseAllowed(d) == nil {
			t.Errorf("%s must not be erasable", name)
		}
	}
}

func TestParseHardware(t *testing.T) {
	text := `{"cpu":"Intel i7-10700K","cores":8,"gpus":[{"name":"Intel UHD","id":"PCI\\VEN_8086&DEV_9BC5&SUBSYS"}],"network":[{"name":"NIC","id":"PCI\\VEN_10EC&DEV_8168&X"},{"name":"NIC","id":"PCI\\VEN_10EC&DEV_8168&Y"}],"bluetooth":[{"name":"BT","id":"USB\\VID_8087&PID_0029\\5"}],"storage":null}`
	hw, err := parseHardware(text)
	if err != nil {
		t.Fatal(err)
	}
	if hw.GPUs[0].Vendor != "8086" || hw.GPUs[0].Device != "9BC5" || len(hw.Network) != 1 || hw.Bluetooth[0].Vendor != "8087" || hw.Storage == nil {
		t.Fatalf("%+v", hw)
	}
	disks, err := parseDisks(`{"number":1,"name":"x","sizeGB":32,"bus":"USB","system":false,"boot":false}`)
	if err != nil || len(disks) != 1 {
		t.Fatalf("single disk JSON: %v %v", disks, err)
	}
}

func TestMakeConfig(t *testing.T) {
	sample, err := plist.Marshal(map[string]any{
		"Booter":       map[string]any{"Quirks": map[string]any{}},
		"NVRAM":        map[string]any{"Delete": map[string]any{"7C436110-AB2A-4BBB-A880-FE41995C9F82": []any{"csr-active-config"}}},
		"PlatformInfo": map[string]any{"Generic": map[string]any{"SystemSerialNumber": "PLACEHOLDER"}},
	}, plist.XMLFormat)
	if err != nil {
		t.Fatal(err)
	}
	plan := BuildPlan(desktop("Intel Core i7-10700K", "Z490", intelGPU), "")
	data, err := MakeConfig(sample, plan, []KextEntry{{"Lilu.kext", "Contents/MacOS/Lilu"}, {"UTBDefault.kext", ""}}, []string{"OpenRuntime.efi"})
	if err != nil {
		t.Fatal(err)
	}
	var out map[string]any
	if _, err := plist.Unmarshal(data, &out); err != nil {
		t.Fatal(err)
	}
	generic := out["PlatformInfo"].(map[string]any)["Generic"].(map[string]any)
	if generic["SystemProductName"] != "iMac20,1" || generic["SystemSerialNumber"] != "PLACEHOLDER" {
		t.Errorf("platform: %v", generic)
	}
	kernel := out["Kernel"].(map[string]any)
	if kernel["Quirks"].(map[string]any)["XhciPortLimit"] != false {
		t.Error("XhciPortLimit must stay off")
	}
	add := kernel["Add"].([]any)
	if add[0].(map[string]any)["BundlePath"] != "Lilu.kext" || add[1].(map[string]any)["ExecutablePath"] != "" {
		t.Errorf("kexts: %v", add)
	}
	names := out["NVRAM"].(map[string]any)["Delete"].(map[string]any)["7C436110-AB2A-4BBB-A880-FE41995C9F82"].([]any)
	if !strings.Contains(strings.Join(toStrings(names), " "), "boot-args") {
		t.Error("boot-args must be in Delete, or they may never apply")
	}
	gpu := out["DeviceProperties"].(map[string]any)["Add"].(map[string]any)["PciRoot(0x0)/Pci(0x2,0x0)"].(map[string]any)
	if string(gpu["AAPL,ig-platform-id"].([]byte)) != string([]byte{7, 0, 0x9B, 0x3E}) {
		t.Errorf("ig-platform-id: %v", gpu)
	}
}

func toStrings(values []any) []string {
	out := []string{}
	for _, v := range values {
		out = append(out, v.(string))
	}
	return out
}

func contains(list []string, want string) bool {
	for _, item := range list {
		if item == want {
			return true
		}
	}
	return false
}

func makeChunklist(chunks [][]byte) []byte {
	header := make([]byte, 0x24)
	copy(header, "CNKL")
	binary.LittleEndian.PutUint32(header[4:], 0x24)
	header[8], header[9], header[10] = 1, 1, 2
	binary.LittleEndian.PutUint64(header[12:], uint64(len(chunks)))
	binary.LittleEndian.PutUint64(header[20:], 0x24)
	binary.LittleEndian.PutUint64(header[28:], uint64(0x24+36*len(chunks)))
	for _, c := range chunks {
		sum := sha256.Sum256(c)
		size := make([]byte, 4)
		binary.LittleEndian.PutUint32(size, uint32(len(c)))
		header = append(header, size...)
		header = append(header, sum[:]...)
	}
	digest := sha256.Sum256(header)
	return append(header, digest[:]...)
}

func TestChunklistChecks(t *testing.T) {
	dir := t.TempDir()
	parts := [][]byte{[]byte("hello"), []byte("world!")}
	list := makeChunklist(parts)
	if _, err := parseChunklist(list, true); err == nil {
		t.Error("an unsigned chunklist must be refused for real downloads")
	}
	chunks, err := parseChunklist(list, false)
	if err != nil {
		t.Fatal(err)
	}
	image := filepath.Join(dir, "image")
	os.WriteFile(image, []byte("helloworld!"), 0o644)
	if err := verifyChunks(image, chunks); err != nil {
		t.Errorf("good image refused: %v", err)
	}
	for name, content := range map[string]string{"damaged": "hellOworld!", "short": "hello", "long": "helloworld!!"} {
		os.WriteFile(image, []byte(content), 0o644)
		if verifyChunks(image, chunks) == nil {
			t.Errorf("%s image accepted", name)
		}
	}
	tampered := append([]byte{}, list...)
	tampered[0x24+5] ^= 1
	if _, err := parseChunklist(tampered, false); err == nil {
		t.Error("a changed chunklist must be refused")
	}
}

func TestUnzipRefusesEscapes(t *testing.T) {
	// Covered through findBundle and the path check; a real traversal zip is built here.
	dir := t.TempDir()
	path := filepath.Join(dir, "evil.zip")
	writeEvilZip(t, path)
	if err := unzip(path, filepath.Join(dir, "out")); err == nil {
		t.Error("zip path traversal must be refused")
	}
}

func TestServerNeedsToken(t *testing.T) {
	server := httptest.NewServer(newServer("secret"))
	defer server.Close()
	for _, path := range []string{"/", "/?t=wrong", "/api/scan", "/api/usb", "/api/job", "/api/build"} {
		resp, err := http.Get(server.URL + path)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != 403 {
			t.Errorf("%s without token: %d", path, resp.StatusCode)
		}
	}
	resp, _ := http.Get(server.URL + "/?t=secret")
	resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Errorf("page with token: %d", resp.StatusCode)
	}
	req, _ := http.NewRequest("POST", server.URL+"/api/build", strings.NewReader(`{"disk":1,"macos":"tahoe","confirm":"nope"}`))
	req.Header.Set("X-Setup-Token", "secret")
	resp, _ = http.DefaultClient.Do(req)
	resp.Body.Close()
	if resp.StatusCode != 400 {
		t.Errorf("build without ERASE: %d", resp.StatusCode)
	}
}

func writeEvilZip(t *testing.T, path string) {
	t.Helper()
	file, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	archive := zip.NewWriter(file)
	entry, err := archive.Create("../../escaped.txt")
	if err != nil {
		t.Fatal(err)
	}
	entry.Write([]byte("x"))
	archive.Close()
}
