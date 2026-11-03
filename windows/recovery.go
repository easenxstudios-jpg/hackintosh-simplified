package main

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"strings"
)

// The recovery protocol follows OpenCorePkg's macrecovery.py (BSD-3-Clause). Apple's server
// answers over plain HTTP, so every download is checked against Apple's signed chunklist.
const recoveryHost = "http://osrecovery.apple.com"

func randomHex(n int) string {
	raw := make([]byte, n/2+1)
	rand.Read(raw)
	return strings.ToUpper(hex.EncodeToString(raw))[:n]
}

// RecoveryInfo is the server's description of an image.
type RecoveryInfo struct {
	Product    string
	ImageURL   string
	ImageToken string
	ListURL    string
	ListToken  string
}

func recoverySession() (string, error) {
	req, _ := http.NewRequest("GET", recoveryHost+"/", nil)
	req.Header.Set("User-Agent", "InternetRecovery/1.0")
	req.Close = true
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	for _, cookie := range resp.Header.Values("Set-Cookie") {
		for _, part := range strings.Split(cookie, "; ") {
			if strings.HasPrefix(part, "session=") {
				return part, nil
			}
		}
	}
	return "", fmt.Errorf("Apple's recovery server didn't start a session")
}

func parseRecoveryInfo(text string) (RecoveryInfo, error) {
	values := map[string]string{}
	for _, line := range strings.Split(text, "\n") {
		if key, value, ok := strings.Cut(strings.TrimRight(line, "\r"), ": "); ok {
			values[key] = value
		}
	}
	for _, key := range []string{"AP", "AU", "AT", "CU", "CT"} {
		if values[key] == "" {
			return RecoveryInfo{}, fmt.Errorf("Apple's recovery server sent an incomplete answer")
		}
	}
	return RecoveryInfo{values["AP"], values["AU"], values["AT"], values["CU"], values["CT"]}, nil
}

func recoveryInfo(session string, version MacOSVersion) (RecoveryInfo, error) {
	body := fmt.Sprintf("cid=%s\nsn=00000000000000000\nbid=%s\nk=%s\nfg=%s\nos=%s\n",
		randomHex(16), version.Board, randomHex(64), randomHex(64), version.Kind)
	req, _ := http.NewRequest("POST", recoveryHost+"/InstallationPayload/RecoveryImage", strings.NewReader(body))
	req.Header.Set("User-Agent", "InternetRecovery/1.0")
	req.Header.Set("Cookie", session)
	req.Header.Set("Content-Type", "text/plain")
	req.Close = true
	resp, err := client.Do(req)
	if err != nil {
		return RecoveryInfo{}, err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(resp.Body)
	if err != nil {
		return RecoveryInfo{}, err
	}
	if resp.StatusCode != 200 {
		return RecoveryInfo{}, fmt.Errorf("Apple's recovery server answered with status %d", resp.StatusCode)
	}
	return parseRecoveryInfo(string(data))
}

// Progress reports bytes done out of total. Total is 0 when unknown.
type Progress func(done, total int64)

func fetchAsset(link, token, dest string, progress Progress) error {
	req, _ := http.NewRequest("GET", link, nil)
	req.Header.Set("User-Agent", "InternetRecovery/1.0")
	req.Header.Set("Cookie", "AssetToken="+token)
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fmt.Errorf("download failed with status %d", resp.StatusCode)
	}
	file, err := os.Create(dest)
	if err != nil {
		return err
	}
	defer file.Close()
	var done int64
	buffer := make([]byte, 1<<20)
	for {
		n, readErr := resp.Body.Read(buffer)
		if n > 0 {
			if _, err := file.Write(buffer[:n]); err != nil {
				return err
			}
			done += int64(n)
			if progress != nil {
				progress(done, resp.ContentLength)
			}
		}
		if readErr == io.EOF {
			return nil
		}
		if readErr != nil {
			return readErr
		}
	}
}

// DownloadRecovery puts a verified macOS recovery image in com.apple.recovery.boot on the USB.
func DownloadRecovery(version MacOSVersion, usbRoot string, report Reporter, progress Progress) error {
	report("Asking Apple for " + version.Name)
	session, err := recoverySession()
	if err != nil {
		return err
	}
	info, err := recoveryInfo(session, version)
	if err != nil {
		return err
	}
	folder := filepath.Join(usbRoot, "com.apple.recovery.boot")
	if err := os.MkdirAll(folder, 0o755); err != nil {
		return err
	}
	list := filepath.Join(folder, path.Base(strings.SplitN(info.ListURL, "?", 2)[0]))
	if err := fetchAsset(info.ListURL, info.ListToken, list, nil); err != nil {
		return err
	}
	image := filepath.Join(folder, path.Base(strings.SplitN(info.ImageURL, "?", 2)[0]))
	report("Downloading " + version.Name + " recovery")
	if err := fetchAsset(info.ImageURL, info.ImageToken, image, progress); err != nil {
		return err
	}
	report("Checking the download against Apple's signature")
	return verifyImage(image, list)
}

type chunk struct {
	Size uint32
	Hash [32]byte
}

// Apple's EFI ROM public key, as published in OpenCorePkg's macrecovery.py.
var appleKey, _ = new(big.Int).SetString(appleKeyHex, 16)

// parseChunklist reads the header and chunk table, and checks Apple's signature over them.
func parseChunklist(data []byte, requireSignature bool) ([]chunk, error) {
	const headerSize = 0x24
	if len(data) < headerSize || string(data[:4]) != "CNKL" {
		return nil, fmt.Errorf("the checksum file isn't valid")
	}
	if binary.LittleEndian.Uint32(data[4:8]) != headerSize || data[8] != 1 || data[9] != 1 {
		return nil, fmt.Errorf("the checksum file has an unknown format")
	}
	method := data[10]
	count := binary.LittleEndian.Uint64(data[12:20])
	offset := binary.LittleEndian.Uint64(data[20:28])
	signature := binary.LittleEndian.Uint64(data[28:36])
	if count == 0 || count > 1<<24 || offset != headerSize || signature != headerSize+36*count {
		return nil, fmt.Errorf("the checksum file has bad offsets")
	}
	if uint64(len(data)) < signature {
		return nil, fmt.Errorf("the checksum file is cut short")
	}
	chunks := make([]chunk, count)
	for i := range chunks {
		at := offset + uint64(i)*36
		chunks[i].Size = binary.LittleEndian.Uint32(data[at : at+4])
		copy(chunks[i].Hash[:], data[at+4:at+36])
	}
	digest := sha256.Sum256(data[:signature])
	rest := data[signature:]
	switch {
	case method == 1 && len(rest) == 256:
		// The signature is stored little-endian.
		reversed := make([]byte, 256)
		for i, b := range rest {
			reversed[255-i] = b
		}
		value := new(big.Int).Exp(new(big.Int).SetBytes(reversed), big.NewInt(0x10001), appleKey)
		expected, _ := new(big.Int).SetString("1"+strings.Repeat("f", 404)+"003031300d060960864801650304020105000420"+hex.EncodeToString(digest[:]), 16)
		if value.Cmp(expected) != 0 {
			return nil, fmt.Errorf("Apple's signature on the checksum file doesn't match")
		}
	case !requireSignature && method == 2 && len(rest) == 32 && bytes.Equal(rest, digest[:]):
	default:
		return nil, fmt.Errorf("the checksum file has no valid Apple signature")
	}
	return chunks, nil
}

func verifyImage(imagePath, listPath string) error {
	data, err := os.ReadFile(listPath)
	if err != nil {
		return err
	}
	chunks, err := parseChunklist(data, true)
	if err != nil {
		return err
	}
	return verifyChunks(imagePath, chunks)
}

func verifyChunks(imagePath string, chunks []chunk) error {
	file, err := os.Open(imagePath)
	if err != nil {
		return err
	}
	defer file.Close()
	for i, c := range chunks {
		buffer := make([]byte, c.Size)
		if _, err := io.ReadFull(file, buffer); err != nil {
			return fmt.Errorf("the macOS download is incomplete at part %d", i+1)
		}
		if sha256.Sum256(buffer) != c.Hash {
			return fmt.Errorf("the macOS download is damaged at part %d", i+1)
		}
	}
	if n, _ := file.Read(make([]byte, 1)); n != 0 {
		return fmt.Errorf("the macOS download is larger than it should be")
	}
	return nil
}
