package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

const (
	sshImportPath      = "golang.org/x/crypto/ssh"
	expectedPackage    = "github.com/cloudflare/cloudflared/sshgen"
	expectedSourceFile = "sshgen.go"
)

var allowedSSHSelectors = map[string]struct{}{
	"MarshalAuthorizedKey": {},
	"NewPublicKey":         {},
}

type listedPackage struct {
	ImportPath string
	Dir        string
	GoFiles    []string
	CgoFiles   []string
	Imports    []string
}

func listCompiledPackages(sourceRoot string) ([]listedPackage, error) {
	command := exec.Command("go", "list", "-mod=vendor", "-deps", "-json", "./cmd/cloudflared")
	command.Dir = sourceRoot
	command.Env = append(os.Environ(),
		"CGO_ENABLED=0",
		"GOARCH=amd64",
		"GOOS=linux",
		"GOFLAGS=-buildvcs=false",
		"GOPROXY=off",
		"GOSUMDB=off",
	)
	output, err := command.Output()
	if err != nil {
		var exitError *exec.ExitError
		if errors.As(err, &exitError) {
			return nil, fmt.Errorf("go list failed: %s", strings.TrimSpace(string(exitError.Stderr)))
		}
		return nil, fmt.Errorf("go list failed: %w", err)
	}

	decoder := json.NewDecoder(bytes.NewReader(output))
	var packages []listedPackage
	for {
		var pkg listedPackage
		if err := decoder.Decode(&pkg); errors.Is(err, io.EOF) {
			break
		} else if err != nil {
			return nil, fmt.Errorf("decode go list output: %w", err)
		}
		packages = append(packages, pkg)
	}
	return packages, nil
}

func validateSSHUsage(packages []listedPackage) error {
	selectors := make(map[string]struct{})
	importingFiles := make(map[string]struct{})
	sawSSHDependency := false

	for _, pkg := range packages {
		if pkg.ImportPath == sshImportPath {
			sawSSHDependency = true
		}
		if !contains(pkg.Imports, sshImportPath) {
			continue
		}
		files := append(append([]string{}, pkg.GoFiles...), pkg.CgoFiles...)
		for _, name := range files {
			path := filepath.Join(pkg.Dir, name)
			parsed, err := parser.ParseFile(token.NewFileSet(), path, nil, parser.SkipObjectResolution)
			if err != nil {
				return fmt.Errorf("parse compiled source %s: %w", path, err)
			}
			for _, imported := range parsed.Imports {
				importPath, err := strconv.Unquote(imported.Path.Value)
				if err != nil {
					return fmt.Errorf("decode import in %s: %w", path, err)
				}
				if importPath != sshImportPath {
					continue
				}
				alias := "ssh"
				if imported.Name != nil {
					alias = imported.Name.Name
				}
				if alias == "." || alias == "_" {
					return fmt.Errorf("%s uses forbidden %q import for %s", path, alias, sshImportPath)
				}
				if pkg.ImportPath != expectedPackage || name != expectedSourceFile {
					return fmt.Errorf("unexpected first-party SSH import: %s/%s", pkg.ImportPath, name)
				}
				importingFiles[pkg.ImportPath+"/"+name] = struct{}{}
				ast.Inspect(parsed, func(node ast.Node) bool {
					selector, ok := node.(*ast.SelectorExpr)
					if !ok {
						return true
					}
					identifier, ok := selector.X.(*ast.Ident)
					if ok && identifier.Name == alias {
						selectors[selector.Sel.Name] = struct{}{}
					}
					return true
				})
			}
		}
	}

	if !sawSSHDependency {
		return fmt.Errorf("compiled dependency closure does not contain %s", sshImportPath)
	}
	expectedFile := expectedPackage + "/" + expectedSourceFile
	if len(importingFiles) != 1 {
		return fmt.Errorf("expected exactly one first-party SSH import, found %v", sortedKeys(importingFiles))
	}
	if _, ok := importingFiles[expectedFile]; !ok {
		return fmt.Errorf("expected SSH import %s, found %v", expectedFile, sortedKeys(importingFiles))
	}
	if !equalSets(selectors, allowedSSHSelectors) {
		return fmt.Errorf("SSH selectors changed: got %v, want %v", sortedKeys(selectors), sortedKeys(allowedSSHSelectors))
	}
	return nil
}

func contains(values []string, expected string) bool {
	for _, value := range values {
		if value == expected {
			return true
		}
	}
	return false
}

func equalSets(left, right map[string]struct{}) bool {
	if len(left) != len(right) {
		return false
	}
	for key := range left {
		if _, ok := right[key]; !ok {
			return false
		}
	}
	return true
}

func sortedKeys(values map[string]struct{}) []string {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

func main() {
	sourceRoot := flag.String("source-root", "", "path to the exact Cloudflared source tree")
	flag.Parse()
	if *sourceRoot == "" {
		fmt.Fprintln(os.Stderr, "cloudflared SSH usage error: --source-root is required")
		os.Exit(2)
	}
	packages, err := listCompiledPackages(*sourceRoot)
	if err == nil {
		err = validateSSHUsage(packages)
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "cloudflared SSH usage error: %v\n", err)
		os.Exit(1)
	}
	fmt.Println("verified Cloudflared SSH usage excludes server authentication")
}
