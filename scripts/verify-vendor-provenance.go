// Copyright 2026 Ratio1
// Licensed under the Apache License, Version 2.0. See LICENSE.

// Command verify-vendor-provenance checks every vendored file against the
// checksum-verified Go module archive declared by vendor/modules.txt.
package main

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
)

type module struct {
	Path       string
	Version    string
	SourcePath string
	SourceVer  string
	Dir        string
	Sum        string
}

type download struct {
	Path    string
	Version string
	Dir     string
	Sum     string
	Error   *struct{ Err string }
}

type overrideRecord struct {
	Path   string `json:"path"`
	SHA256 string `json:"sha256"`
}

type overrides struct {
	SecurityBackports []struct {
		Files []overrideRecord `json:"files"`
	} `json:"securityBackports"`
	CompatibilityBackports []struct {
		Files []overrideRecord `json:"files"`
	} `json:"dependencyCompatibilityBackports"`
	GeneratedVendorFiles []overrideRecord `json:"generatedVendorFiles"`
}

func fail(format string, values ...any) {
	fmt.Fprintf(os.Stderr, "vendor-provenance error: "+format+"\n", values...)
	os.Exit(1)
}

func hash(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	digest := sha256.New()
	if _, err := io.Copy(digest, file); err != nil {
		return "", err
	}
	return hex.EncodeToString(digest.Sum(nil)), nil
}

func parseModules(path string) ([]module, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	byPath := map[string]module{}
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := scanner.Text()
		if !strings.HasPrefix(line, "# ") {
			continue
		}
		fields := strings.Fields(strings.TrimPrefix(line, "# "))
		if len(fields) < 2 || !strings.HasPrefix(fields[1], "v") {
			continue
		}
		item := module{Path: fields[0], Version: fields[1], SourcePath: fields[0], SourceVer: fields[1]}
		if len(fields) == 5 && fields[2] == "=>" {
			item.SourcePath, item.SourceVer = fields[3], fields[4]
		} else if len(fields) != 2 {
			return nil, fmt.Errorf("unsupported module header: %s", line)
		}
		if previous, ok := byPath[item.Path]; ok && previous != item {
			return nil, fmt.Errorf("conflicting module records for %s", item.Path)
		}
		byPath[item.Path] = item
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	items := make([]module, 0, len(byPath))
	for _, item := range byPath {
		items = append(items, item)
	}
	sort.Slice(items, func(i, j int) bool {
		if len(items[i].Path) != len(items[j].Path) {
			return len(items[i].Path) > len(items[j].Path)
		}
		return items[i].Path < items[j].Path
	})
	return items, nil
}

func loadOverrides(path string) (map[string]string, error) {
	content, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var records overrides
	if err := json.Unmarshal(content, &records); err != nil {
		return nil, err
	}
	result := map[string]string{}
	add := func(record overrideRecord) error {
		if !strings.HasPrefix(record.Path, "engine/vendor/") || len(record.SHA256) != 64 {
			return fmt.Errorf("invalid vendor override: %s", record.Path)
		}
		relative := strings.TrimPrefix(record.Path, "engine/vendor/")
		if _, exists := result[relative]; exists {
			return fmt.Errorf("duplicate vendor override: %s", record.Path)
		}
		result[relative] = record.SHA256
		return nil
	}
	for _, backport := range records.SecurityBackports {
		for _, record := range backport.Files {
			if err := add(record); err != nil {
				return nil, err
			}
		}
	}
	for _, backport := range records.CompatibilityBackports {
		for _, record := range backport.Files {
			if err := add(record); err != nil {
				return nil, err
			}
		}
	}
	for _, record := range records.GeneratedVendorFiles {
		if err := add(record); err != nil {
			return nil, err
		}
	}
	return result, nil
}

func downloadModules(items []module, goBinary string) error {
	targets := make([]string, 0, len(items))
	for _, item := range items {
		targets = append(targets, item.SourcePath+"@"+item.SourceVer)
	}
	command := exec.Command(goBinary, append([]string{"mod", "download", "-json"}, targets...)...)
	command.Env = append(os.Environ(), "GOFLAGS=-mod=mod", "GOTOOLCHAIN=local")
	stdout, err := command.StdoutPipe()
	if err != nil {
		return err
	}
	command.Stderr = os.Stderr
	if err := command.Start(); err != nil {
		return err
	}
	bySource := map[string]*module{}
	for index := range items {
		bySource[items[index].SourcePath+"@"+items[index].SourceVer] = &items[index]
	}
	decoder := json.NewDecoder(stdout)
	seen := map[string]bool{}
	for {
		var record download
		if err := decoder.Decode(&record); errors.Is(err, io.EOF) {
			break
		} else if err != nil {
			return err
		}
		key := record.Path + "@" + record.Version
		item := bySource[key]
		if item == nil {
			return fmt.Errorf("unexpected module download: %s", key)
		}
		if record.Error != nil {
			return fmt.Errorf("module download failed for %s: %s", key, record.Error.Err)
		}
		if record.Dir == "" || record.Sum == "" {
			return fmt.Errorf("module archive lacks a verified directory or checksum: %s", key)
		}
		item.Dir, item.Sum = record.Dir, record.Sum
		seen[key] = true
	}
	if err := command.Wait(); err != nil {
		return err
	}
	if len(seen) != len(bySource) {
		return fmt.Errorf("downloaded %d of %d unique module archives", len(seen), len(bySource))
	}
	return nil
}

func owner(path string, items []module) *module {
	for index := range items {
		prefix := items[index].Path
		if path == prefix || strings.HasPrefix(path, prefix+"/") {
			return &items[index]
		}
	}
	return nil
}

func main() {
	root, err := filepath.Abs(".")
	if err != nil {
		fail("cannot resolve repository root: %v", err)
	}
	if filepath.Base(root) == "engine" {
		root = filepath.Dir(root)
	}
	engine := filepath.Join(root, "engine")
	items, err := parseModules(filepath.Join(engine, "vendor", "modules.txt"))
	if err != nil {
		fail("cannot parse vendor/modules.txt: %v", err)
	}
	if len(items) < 100 {
		fail("module inventory is unexpectedly small: %d", len(items))
	}
	allowed, err := loadOverrides(filepath.Join(root, "source", "ratio1-engine-overrides.json"))
	if err != nil {
		fail("cannot load Ratio1 overrides: %v", err)
	}
	goBinary, err := exec.LookPath("go")
	if err != nil {
		fail("pinned Go command is required")
	}
	command := exec.Command(goBinary, "version")
	versionOutput, err := command.Output()
	if err != nil || !strings.Contains(string(versionOutput), "go1.26.6 ") {
		fail("vendor verification requires Go 1.26.6, got %q", strings.TrimSpace(string(versionOutput)))
	}
	if err := downloadModules(items, goBinary); err != nil {
		fail("cannot download checksum-verified modules: %v", err)
	}

	verified := 0
	usedOverrides := map[string]bool{}
	err = filepath.WalkDir(filepath.Join(engine, "vendor"), func(path string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if entry.IsDir() || entry.Type()&os.ModeSymlink != 0 {
			return nil
		}
		relative, err := filepath.Rel(filepath.Join(engine, "vendor"), path)
		if err != nil {
			return err
		}
		relative = filepath.ToSlash(relative)
		if relative == "modules.txt" {
			return nil
		}
		actual, err := hash(path)
		if err != nil {
			return err
		}
		if expected, ok := allowed[relative]; ok {
			if actual != expected {
				return fmt.Errorf("Ratio1 override hash differs: %s", relative)
			}
			usedOverrides[relative] = true
			verified++
			return nil
		}
		item := owner(relative, items)
		if item == nil {
			return fmt.Errorf("vendored file has no module owner: %s", relative)
		}
		moduleRelative := strings.TrimPrefix(relative, item.Path)
		moduleRelative = strings.TrimPrefix(moduleRelative, "/")
		sourcePath := filepath.Join(item.Dir, filepath.FromSlash(moduleRelative))
		expected, err := hash(sourcePath)
		if err != nil {
			return fmt.Errorf("module source missing for %s (%s@%s): %w", relative, item.SourcePath, item.SourceVer, err)
		}
		if actual != expected {
			return fmt.Errorf("vendored file differs from %s@%s: %s", item.SourcePath, item.SourceVer, relative)
		}
		verified++
		return nil
	})
	if err != nil {
		fail("%v", err)
	}
	for path := range allowed {
		if !usedOverrides[path] {
			fail("declared vendor override was not encountered: %s", path)
		}
	}
	fmt.Printf("verified %d vendored files against %d checksum-backed modules (%d declared Ratio1 overrides)\n", verified, len(items), len(allowed))
}
