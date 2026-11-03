// Hackintosh Simplified Setup: a local wizard for preparing Windows, the BIOS and a macOS USB.
// It serves its pages only to this PC, on a random port, and only with a one-time token.
package main

import (
	"crypto/rand"
	"crypto/subtle"
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"sync"
)

//go:embed ui.html
var uiPage string

//go:embed icon.png
var iconPNG []byte

const version = "0.3.0"

type job struct {
	mu      sync.Mutex
	Running bool     `json:"running"`
	Done    bool     `json:"done"`
	Step    string   `json:"step"`
	Percent int      `json:"percent"`
	Error   string   `json:"error"`
	Root    string   `json:"root"`
	Sources []string `json:"sources"`
}

func (j *job) set(update func(*job)) {
	j.mu.Lock()
	defer j.mu.Unlock()
	update(j)
}

func (j *job) snapshot() map[string]any {
	j.mu.Lock()
	defer j.mu.Unlock()
	return map[string]any{"running": j.Running, "done": j.Done, "step": j.Step, "percent": j.Percent, "error": j.Error, "root": j.Root, "sources": j.Sources}
}

func versionByID(id string, plan Plan) (MacOSVersion, bool) {
	for _, v := range plan.Versions {
		if v.ID == id {
			return v, true
		}
	}
	return MacOSVersion{}, false
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(value)
}

// newServer returns the wizard's handler. Every API call must carry the token, and a page from
// any other site can't reach it: the Host must be this machine, and the token is never sent cross-site.
func newServer(token string) http.Handler {
	current := &job{}
	mux := http.NewServeMux()
	guard := func(handler func(http.ResponseWriter, *http.Request)) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			given := []byte(r.Header.Get("X-Setup-Token"))
			if subtle.ConstantTimeCompare(given, []byte(token)) != 1 {
				writeJSON(w, 403, map[string]string{"error": "This page's session has expired. Reopen the app."})
				return
			}
			handler(w, r)
		}
	}
	mux.HandleFunc("/icon.png", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "image/png")
		w.Write(iconPNG)
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" || subtle.ConstantTimeCompare([]byte(r.URL.Query().Get("t")), []byte(token)) != 1 {
			http.Error(w, "Open this page from the Hackintosh Simplified Setup app.", 403)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("Content-Security-Policy", "default-src 'self'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src 'self'")
		fmt.Fprint(w, strings.ReplaceAll(uiPage, "__TOKEN__", token))
	})
	mux.HandleFunc("/api/scan", guard(func(w http.ResponseWriter, r *http.Request) {
		hw, err := ScanHardware()
		if err != nil {
			writeJSON(w, 500, map[string]string{"error": "Couldn't read this PC's hardware: " + err.Error()})
			return
		}
		writeJSON(w, 200, map[string]any{"hardware": hw, "plan": BuildPlan(hw, r.URL.Query().Get("macos"))})
	}))
	mux.HandleFunc("/api/usb", guard(func(w http.ResponseWriter, r *http.Request) {
		disks, err := ListUSB()
		if err != nil {
			writeJSON(w, 500, map[string]string{"error": "Couldn't list USB drives: " + err.Error()})
			return
		}
		writeJSON(w, 200, disks)
	}))
	mux.HandleFunc("/api/job", guard(func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, current.snapshot())
	}))
	mux.HandleFunc("/api/build", guard(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSON(w, 405, map[string]string{"error": "Use POST."})
			return
		}
		var request struct {
			Disk    int    `json:"disk"`
			MacOS   string `json:"macos"`
			Confirm string `json:"confirm"`
		}
		if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
			writeJSON(w, 400, map[string]string{"error": "Bad request."})
			return
		}
		if request.Confirm != "ERASE" {
			writeJSON(w, 400, map[string]string{"error": "Type ERASE to confirm."})
			return
		}
		hw, err := ScanHardware()
		if err != nil {
			writeJSON(w, 500, map[string]string{"error": err.Error()})
			return
		}
		plan := BuildPlan(hw, request.MacOS)
		macOS, ok := versionByID(request.MacOS, plan)
		if !plan.Supported || !ok {
			writeJSON(w, 400, map[string]string{"error": "This PC can't use that macOS version with this wizard."})
			return
		}
		current.mu.Lock()
		if current.Running {
			current.mu.Unlock()
			writeJSON(w, 409, map[string]string{"error": "The USB is already being prepared."})
			return
		}
		current.Running, current.Done, current.Error, current.Percent, current.Step = true, false, "", 0, "Erasing the USB drive"
		current.mu.Unlock()
		go runBuild(current, plan, macOS, request.Disk)
		writeJSON(w, 200, map[string]bool{"started": true})
	}))
	return mux
}

func runBuild(j *job, plan Plan, macOS MacOSVersion, disk int) {
	fail := func(err error) { j.set(func(x *job) { x.Running, x.Error = false, err.Error() }) }
	root, err := FormatUSB(disk)
	if err != nil {
		fail(err)
		return
	}
	report := func(step string) { j.set(func(x *job) { x.Step = step; x.Percent = 0 }) }
	sources, err := BuildEFI(plan, macOS, root, report)
	if err != nil {
		fail(err)
		return
	}
	err = DownloadRecovery(macOS, root, report, func(done, total int64) {
		if total > 0 {
			j.set(func(x *job) { x.Percent = int(done * 100 / total) })
		}
	})
	if err != nil {
		fail(err)
		return
	}
	j.set(func(x *job) { x.Running, x.Done, x.Root, x.Sources, x.Step = false, true, root, sources, "Done" })
}

func openBrowser(link string) {
	switch runtime.GOOS {
	case "windows":
		cmd := exec.Command("rundll32", "url.dll,FileProtocolHandler", link)
		hideWindow(cmd)
		cmd.Start()
	case "darwin":
		exec.Command("open", link).Start()
	}
}

func main() {
	selfTest := flag.String("selftest", "", "build an EFI in this folder from sample hardware, then validate it")
	selfTestDisk := flag.Int("selftest-format", -1, "format this test disk, using the real erase code")
	selfTestScan := flag.Bool("selftest-scan", false, "scan this PC and print the plan")
	selfTestRecovery := flag.Bool("selftest-recovery", false, "ask Apple for recovery info without downloading the image")
	noBrowser := flag.Bool("no-browser", false, "don't open the browser")
	port := flag.Int("port", 0, "port for the wizard")
	tokenFlag := flag.String("token", "", "fixed token, for testing")
	flag.Parse()

	switch {
	case *selfTest != "":
		exitOn(runSelfTest(*selfTest))
		return
	case *selfTestDisk >= 0:
		root, err := FormatUSB(*selfTestDisk)
		exitOn(err)
		fmt.Println("formatted:", root)
		return
	case *selfTestScan:
		hw, err := ScanHardware()
		exitOn(err)
		data, _ := json.MarshalIndent(map[string]any{"hardware": hw, "plan": BuildPlan(hw, "")}, "", "  ")
		fmt.Println(string(data))
		disks, err := ListUSB()
		exitOn(err)
		fmt.Println("erasable disks:", len(disks))
		return
	case *selfTestRecovery:
		exitOn(selfTestApple())
		return
	}

	ensureAdmin()
	raw := make([]byte, 24)
	rand.Read(raw)
	token := hex.EncodeToString(raw)
	if *tokenFlag != "" {
		token = *tokenFlag
	}
	listener, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", *port))
	exitOn(err)
	link := fmt.Sprintf("http://%s/?t=%s", listener.Addr(), token)
	fmt.Println("Hackintosh Simplified Setup", version)
	fmt.Println("Keep this window open while you use the wizard. Close it when you're done.")
	fmt.Println(link)
	if !*noBrowser {
		openBrowser(link)
	}
	exitOn(http.Serve(listener, newServer(token)))
}

func exitOn(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, "Error:", err)
		os.Exit(1)
	}
}

func runSelfTest(dest string) error {
	hw := demoHardware()
	plan := BuildPlan(hw, tahoe.ID)
	sources, err := BuildEFI(plan, tahoe, dest, func(step string) { fmt.Println(step) })
	if err != nil {
		return err
	}
	fmt.Println("Validated. Sources:")
	for _, source := range sources {
		fmt.Println(" ", source)
	}
	return nil
}

func selfTestApple() error {
	session, err := recoverySession()
	if err != nil {
		return err
	}
	for _, v := range []MacOSVersion{sequoia, tahoe} {
		info, err := recoveryInfo(session, v)
		if err != nil {
			return fmt.Errorf("%s: %w", v.Name, err)
		}
		fmt.Println(v.Name, "product", info.Product)
		dir, err := os.MkdirTemp("", "hs-recovery-")
		if err != nil {
			return err
		}
		defer os.RemoveAll(dir)
		list := dir + string(os.PathSeparator) + "list"
		if err := fetchAsset(info.ListURL, info.ListToken, list, nil); err != nil {
			return fmt.Errorf("%s chunklist: %w", v.Name, err)
		}
		data, err := os.ReadFile(list)
		if err != nil {
			return err
		}
		chunks, err := parseChunklist(data, true)
		if err != nil {
			return fmt.Errorf("%s chunklist: %w", v.Name, err)
		}
		fmt.Println(v.Name, "Apple signature OK,", len(chunks), "chunks")
	}
	return nil
}
