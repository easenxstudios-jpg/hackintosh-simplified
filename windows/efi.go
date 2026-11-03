package main

import (
	"archive/zip"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"time"

	"howett.net/plist"
)

const userAgent = "HackintoshSimplifiedSetup"

var client = &http.Client{Timeout: 30 * time.Minute}

type release struct {
	Tag    string `json:"tag_name"`
	Assets []struct {
		Name string `json:"name"`
		URL  string `json:"browser_download_url"`
	} `json:"assets"`
}

func latestRelease(repo string) (release, error) {
	var r release
	req, _ := http.NewRequest("GET", "https://api.github.com/repos/"+repo+"/releases/latest", nil)
	req.Header.Set("User-Agent", userAgent)
	req.Header.Set("Accept", "application/vnd.github+json")
	if token := os.Getenv("GITHUB_TOKEN"); token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := client.Do(req)
	if err != nil {
		return r, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return r, fmt.Errorf("couldn't read %s's releases from GitHub (status %d)", repo, resp.StatusCode)
	}
	return r, json.NewDecoder(resp.Body).Decode(&r)
}

// chooseAsset prefers a RELEASE zip, and skips debug builds and extras.
func chooseAsset(r release) (name, link string) {
	var fallbackName, fallbackLink string
	for _, a := range r.Assets {
		lower := strings.ToLower(a.Name)
		if !strings.HasSuffix(lower, ".zip") || strings.Contains(lower, "debug") || strings.Contains(lower, "dsym") || strings.Contains(lower, "source") {
			continue
		}
		parsed, err := url.Parse(a.URL)
		if err != nil || parsed.Host != "github.com" {
			continue
		}
		if strings.Contains(strings.ToUpper(a.Name), "RELEASE") {
			return a.Name, a.URL
		}
		if fallbackName == "" {
			fallbackName, fallbackLink = a.Name, a.URL
		}
	}
	return fallbackName, fallbackLink
}

func download(link, path string) (string, error) {
	req, err := http.NewRequest("GET", link, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("User-Agent", userAgent)
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return "", fmt.Errorf("download failed with status %d", resp.StatusCode)
	}
	file, err := os.Create(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	hash := sha256.New()
	if _, err := io.Copy(io.MultiWriter(file, hash), resp.Body); err != nil {
		return "", err
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

// unzip refuses any entry that would land outside the destination folder.
func unzip(archive, dest string) error {
	r, err := zip.OpenReader(archive)
	if err != nil {
		return err
	}
	defer r.Close()
	root, _ := filepath.Abs(dest)
	for _, f := range r.File {
		target := filepath.Join(root, filepath.FromSlash(f.Name))
		if target != root && !strings.HasPrefix(target, root+string(os.PathSeparator)) {
			return fmt.Errorf("unsafe path in archive: %s", f.Name)
		}
		if f.Mode()&os.ModeSymlink != 0 {
			continue
		}
		if f.FileInfo().IsDir() {
			if err := os.MkdirAll(target, 0o755); err != nil {
				return err
			}
			continue
		}
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return err
		}
		in, err := f.Open()
		if err != nil {
			return err
		}
		out, err := os.OpenFile(target, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o755)
		if err != nil {
			in.Close()
			return err
		}
		_, err = io.Copy(out, in)
		in.Close()
		out.Close()
		if err != nil {
			return err
		}
	}
	return nil
}

// findBundle finds a kext at any depth, without looking inside other kexts.
func findBundle(root, bundle string) (string, error) {
	found := ""
	err := filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() && strings.HasSuffix(d.Name(), ".kext") && !strings.Contains(path, "__MACOSX") {
			if d.Name() == bundle {
				found = path
				return filepath.SkipAll
			}
			return filepath.SkipDir
		}
		return nil
	})
	if err != nil {
		return "", err
	}
	if found == "" {
		return "", fmt.Errorf("%s wasn't in its download", bundle)
	}
	return found, nil
}

func copyTree(src, dst string) error {
	return filepath.WalkDir(src, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(src, path)
		target := filepath.Join(dst, rel)
		if d.IsDir() {
			return os.MkdirAll(target, 0o755)
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		return os.WriteFile(target, data, 0o644)
	})
}

// kextExecutable reads a kext's Info.plist to get the path config.plist needs.
func kextExecutable(kextPath string) (string, error) {
	data, err := os.ReadFile(filepath.Join(kextPath, "Contents", "Info.plist"))
	if err != nil {
		return "", err
	}
	var info map[string]any
	if _, err := plist.Unmarshal(data, &info); err != nil {
		return "", err
	}
	if name, ok := info["CFBundleExecutable"].(string); ok && name != "" {
		return "Contents/MacOS/" + name, nil
	}
	return "", nil
}

type Reporter func(step string)

// BuildEFI downloads OpenCore and the planned kexts from their official releases, then writes
// EFI/ into dest and checks config.plist with OpenCore's own validator.
func BuildEFI(plan Plan, version MacOSVersion, dest string, report Reporter) ([]string, error) {
	if !plan.Supported {
		return nil, fmt.Errorf("this PC isn't supported by this version: %s", plan.Reason)
	}
	work, err := os.MkdirTemp("", "hs-efi-")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(work)
	var sources []string

	report("Downloading OpenCore")
	oc, err := latestRelease("acidanthera/OpenCorePkg")
	if err != nil {
		return nil, err
	}
	name, link := chooseAsset(oc)
	if name == "" {
		return nil, fmt.Errorf("OpenCore's newest release has no download")
	}
	archive := filepath.Join(work, "oc.zip")
	hash, err := download(link, archive)
	if err != nil {
		return nil, err
	}
	sources = append(sources, fmt.Sprintf("OpenCorePkg %s, SHA-256 %s", oc.Tag, hash))
	ocDir := filepath.Join(work, "oc")
	if err := unzip(archive, ocDir); err != nil {
		return nil, err
	}
	efiDest := filepath.Join(dest, "EFI")
	if err := copyTree(filepath.Join(ocDir, "X64", "EFI"), efiDest); err != nil {
		return nil, err
	}
	ocRoot := filepath.Join(efiDest, "OC")

	// Keep only the startup drivers this setup uses.
	keep := map[string]bool{"OpenRuntime.efi": true, "OpenHfsPlus.efi": true, "ResetNvramEntry.efi": true}
	drivers, _ := os.ReadDir(filepath.Join(ocRoot, "Drivers"))
	var driverNames []string
	for _, d := range drivers {
		if keep[d.Name()] {
			driverNames = append(driverNames, d.Name())
		} else {
			os.Remove(filepath.Join(ocRoot, "Drivers", d.Name()))
		}
	}
	tools, _ := os.ReadDir(filepath.Join(ocRoot, "Tools"))
	for _, t := range tools {
		if t.Name() != "OpenShell.efi" {
			os.Remove(filepath.Join(ocRoot, "Tools", t.Name()))
		}
	}

	report("Downloading drivers")
	cache := map[string]string{}
	var entries []KextEntry
	for _, kext := range plan.Kexts {
		root, ok := cache[kext.Repo]
		if !ok {
			rel, err := latestRelease(kext.Repo)
			if err != nil {
				return nil, err
			}
			assetName, assetLink := chooseAsset(rel)
			if assetName == "" {
				return nil, fmt.Errorf("%s's newest release has no download", kext.Repo)
			}
			zipPath := filepath.Join(work, fmt.Sprintf("k%d.zip", len(cache)))
			hash, err := download(assetLink, zipPath)
			if err != nil {
				return nil, err
			}
			sources = append(sources, fmt.Sprintf("%s %s, SHA-256 %s", kext.Repo, rel.Tag, hash))
			root = filepath.Join(work, fmt.Sprintf("k%d", len(cache)))
			if err := unzip(zipPath, root); err != nil {
				return nil, err
			}
			cache[kext.Repo] = root
		}
		found, err := findBundle(root, kext.Bundle)
		if err != nil {
			return nil, err
		}
		if err := copyTree(found, filepath.Join(ocRoot, "Kexts", kext.Bundle)); err != nil {
			return nil, err
		}
		executable, err := kextExecutable(found)
		if err != nil {
			return nil, err
		}
		entries = append(entries, KextEntry{kext.Bundle, executable})
	}

	report("Downloading hardware patches")
	for _, ssdt := range plan.SSDTs {
		link := "https://github.com/dortania/Getting-Started-With-ACPI/raw/master/extra-files/compiled/" + ssdt + ".aml"
		if _, err := download(link, filepath.Join(ocRoot, "ACPI", ssdt+".aml")); err != nil {
			return nil, fmt.Errorf("%s: %w", ssdt, err)
		}
	}

	report("Writing OpenCore settings")
	sample, err := os.ReadFile(filepath.Join(ocDir, "Docs", "Sample.plist"))
	if err != nil {
		return nil, err
	}
	config, err := MakeConfig(sample, plan, entries, driverNames)
	if err != nil {
		return nil, err
	}
	configPath := filepath.Join(ocRoot, "config.plist")
	if err := os.WriteFile(configPath, config, 0o644); err != nil {
		return nil, err
	}

	report("Checking settings with OpenCore's validator")
	if err := runValidator(ocDir, configPath); err != nil {
		return nil, err
	}
	return sources, nil
}

// runValidator runs ocvalidate from the same OpenCore release, when one exists for this system.
func runValidator(ocDir, configPath string) error {
	file := "ocvalidate"
	switch runtime.GOOS {
	case "windows":
		file = "ocvalidate.exe"
	case "linux":
		file = "ocvalidate.linux"
	}
	tool := filepath.Join(ocDir, "Utilities", "ocvalidate", file)
	if _, err := os.Stat(tool); err != nil {
		return fmt.Errorf("OpenCore's validator wasn't in its download")
	}
	os.Chmod(tool, 0o755)
	output, err := exec.Command(tool, configPath).CombinedOutput()
	if err != nil {
		return fmt.Errorf("OpenCore's validator rejected the settings:\n%s", lastLines(string(output), 20))
	}
	return nil
}

func lastLines(text string, n int) string {
	lines := strings.Split(strings.TrimSpace(text), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, "\n")
}

type KextEntry struct {
	Bundle     string
	Executable string
}

func dict(root map[string]any, path ...string) map[string]any {
	current := root
	for _, key := range path {
		next, ok := current[key].(map[string]any)
		if !ok {
			next = map[string]any{}
			current[key] = next
		}
		current = next
	}
	return current
}

var hexPattern = regexp.MustCompile(`^[0-9A-Fa-f]+$`)

func hexBytes(value string) []byte {
	if !hexPattern.MatchString(value) {
		return nil
	}
	data, _ := hex.DecodeString(value)
	return data
}

// MakeConfig turns OpenCore's Sample.plist into this PC's config, using the values Dortania
// publishes for each platform. It leaves the sample's placeholder serial numbers in place.
func MakeConfig(sample []byte, plan Plan, kexts []KextEntry, drivers []string) ([]byte, error) {
	var root map[string]any
	if _, err := plist.Unmarshal(sample, &root); err != nil {
		return nil, err
	}

	var acpi []any
	for _, ssdt := range plan.SSDTs {
		acpi = append(acpi, map[string]any{"Comment": ssdt, "Enabled": true, "Path": ssdt + ".aml"})
	}
	dict(root, "ACPI")["Add"] = acpi
	dict(root, "ACPI")["Patch"] = []any{}

	booter := dict(root, "Booter", "Quirks")
	booter["DevirtualiseMmio"] = true
	booter["EnableWriteUnprotector"] = false
	booter["RebuildAppleMemoryMap"] = true
	booter["SyncRuntimePermissions"] = true
	booter["ResizeAppleGpuBars"] = int64(-1)
	if plan.CometLake {
		booter["ProtectUefiServices"] = true
		booter["SetupVirtualMap"] = false
	} else {
		booter["ProtectUefiServices"] = plan.Z390
	}
	dict(root, "Booter")["MmioWhitelist"] = []any{}
	dict(root, "Booter")["Patch"] = []any{}

	devices := map[string]any{}
	if len(plan.IGPU) > 0 {
		gpu := map[string]any{}
		for key, value := range plan.IGPU {
			gpu[key] = hexBytes(value)
		}
		devices["PciRoot(0x0)/Pci(0x2,0x0)"] = gpu
	}
	dict(root, "DeviceProperties")["Add"] = devices

	var add []any
	for _, kext := range kexts {
		add = append(add, map[string]any{
			"Arch": "Any", "BundlePath": kext.Bundle, "Comment": "", "Enabled": true,
			"ExecutablePath": kext.Executable, "MaxKernel": "", "MinKernel": "", "PlistPath": "Contents/Info.plist",
		})
	}
	dict(root, "Kernel")["Add"] = add
	dict(root, "Kernel")["Block"] = []any{}
	dict(root, "Kernel")["Force"] = []any{}
	dict(root, "Kernel")["Patch"] = []any{}
	quirks := dict(root, "Kernel", "Quirks")
	quirks["AppleXcpmCfgLock"] = true
	quirks["DisableIoMapper"] = true
	quirks["LapicKernelPanic"] = plan.HP
	quirks["PanicNoKextDump"] = true
	quirks["PowerTimeoutKernelPanic"] = true
	quirks["XhciPortLimit"] = false

	dict(root, "Misc", "Boot")["HideAuxiliary"] = false
	debug := dict(root, "Misc", "Debug")
	debug["AppleDebug"] = true
	debug["ApplePanic"] = true
	debug["DisableWatchDog"] = true
	debug["Target"] = int64(67)
	security := dict(root, "Misc", "Security")
	security["AllowSetDefault"] = true
	security["BlacklistAppleUpdate"] = true
	security["ScanPolicy"] = int64(0)
	security["SecureBootModel"] = "Default"
	security["Vault"] = "Optional"
	dict(root, "Misc")["Tools"] = []any{}
	dict(root, "Misc")["Entries"] = []any{}

	nvram := dict(root, "NVRAM", "Add", "7C436110-AB2A-4BBB-A880-FE41995C9F82")
	nvram["boot-args"] = strings.Join(plan.BootArgs, " ")
	nvram["prev-lang:kbd"] = "en-US:0"
	nvram["csr-active-config"] = []byte{0, 0, 0, 0}
	deleteLists := dict(root, "NVRAM", "Delete")
	key := "7C436110-AB2A-4BBB-A880-FE41995C9F82"
	names, _ := deleteLists[key].([]any)
	hasArgs := false
	for _, name := range names {
		if name == "boot-args" {
			hasArgs = true
		}
	}
	if !hasArgs {
		deleteLists[key] = append(names, "boot-args")
	}

	dict(root, "PlatformInfo", "Generic")["SystemProductName"] = plan.SMBIOS

	var driverList []any
	for _, driver := range drivers {
		driverList = append(driverList, map[string]any{"Arguments": "", "Comment": "", "Enabled": true, "HideVerbose": false, "LoadEarly": false, "Path": driver})
	}
	dict(root, "UEFI")["Drivers"] = driverList
	dict(root, "UEFI")["ConnectDrivers"] = true

	var out bytes.Buffer
	encoder := plist.NewEncoder(&out)
	encoder.Indent("\t")
	if err := encoder.Encode(root); err != nil {
		return nil, err
	}
	// Apple's parser rejects an empty data tag written as <data/>, so write it in full.
	return emptyData.ReplaceAll(out.Bytes(), []byte("<data></data>")), nil
}

var emptyData = regexp.MustCompile(`<data\s*/>|<data>\s*</data>`)
