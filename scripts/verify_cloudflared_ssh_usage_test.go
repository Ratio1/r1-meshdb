package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const allowedSource = `package sshgen
import gossh "golang.org/x/crypto/ssh"
func key(data []byte) {
	publicKey, _ := gossh.NewPublicKey(data)
	_ = gossh.MarshalAuthorizedKey(publicKey)
}
`

func fixturePackages(t *testing.T, source string) []listedPackage {
	t.Helper()
	directory := t.TempDir()
	if err := os.WriteFile(filepath.Join(directory, expectedSourceFile), []byte(source), 0o600); err != nil {
		t.Fatal(err)
	}
	return []listedPackage{
		{ImportPath: sshImportPath},
		{
			ImportPath: expectedPackage,
			Dir:        directory,
			GoFiles:    []string{expectedSourceFile},
			Imports:    []string{sshImportPath},
		},
	}
}

func TestAllowsOnlyPublicKeyMarshalling(t *testing.T) {
	if err := validateSSHUsage(fixturePackages(t, allowedSource)); err != nil {
		t.Fatal(err)
	}
}

func TestAllowsUnrelatedNewServerConnSelector(t *testing.T) {
	source := allowedSource + `
type localRPC struct{}
func (localRPC) NewServerConn() {}
func unrelated() { var tunnelrpc localRPC; tunnelrpc.NewServerConn() }
`
	if err := validateSSHUsage(fixturePackages(t, source)); err != nil {
		t.Fatal(err)
	}
}

func TestRejectsSSHServerAuthenticationAPIs(t *testing.T) {
	tests := map[string]string{
		"default import NewServerConn": strings.Replace(
			strings.ReplaceAll(allowedSource, "gossh", "ssh"),
			"import ssh \"golang.org/x/crypto/ssh\"",
			"import \"golang.org/x/crypto/ssh\"",
			1,
		) + "func server(c any, cfg any) { _, _, _, _ = ssh.NewServerConn(c, cfg) }\n",
		"explicit alias NewServerConn": allowedSource +
			"func server(c any, cfg any) { _, _, _, _ = gossh.NewServerConn(c, cfg) }\n",
		"ServerConfig callbacks": allowedSource +
			"var config = gossh.ServerConfig{PasswordCallback: nil, KeyboardInteractiveCallback: nil, NoClientAuth: false, GSSAPIWithMICConfig: nil}\n",
		"dot import NewServerConn": strings.Replace(
			strings.ReplaceAll(allowedSource, "gossh.", ""),
			"import gossh \"golang.org/x/crypto/ssh\"",
			"import . \"golang.org/x/crypto/ssh\"",
			1,
		) + "func server(c any, cfg any) { _, _, _, _ = NewServerConn(c, cfg) }\n",
		"blank import": strings.Replace(
			allowedSource,
			"import gossh \"golang.org/x/crypto/ssh\"",
			"import _ \"golang.org/x/crypto/ssh\"",
			1,
		),
	}
	for name, source := range tests {
		t.Run(name, func(t *testing.T) {
			if err := validateSSHUsage(fixturePackages(t, source)); err == nil {
				t.Fatal("expected SSH server-authentication usage to be rejected")
			}
		})
	}
}

func TestRejectsSSHImportOutsideSSHGen(t *testing.T) {
	packages := fixturePackages(t, allowedSource)
	directory := t.TempDir()
	path := filepath.Join(directory, "server.go")
	if err := os.WriteFile(path, []byte(`package server
import ssh "golang.org/x/crypto/ssh"
var config ssh.ServerConfig
`), 0o600); err != nil {
		t.Fatal(err)
	}
	packages = append(packages, listedPackage{
		ImportPath: "github.com/cloudflare/cloudflared/server",
		Dir:        directory,
		GoFiles:    []string{"server.go"},
		Imports:    []string{sshImportPath},
	})
	if err := validateSSHUsage(packages); err == nil {
		t.Fatal("expected SSH import outside sshgen to be rejected")
	}
}

func TestRejectsSSHImportFromCompiledDependency(t *testing.T) {
	packages := fixturePackages(t, allowedSource)
	directory := t.TempDir()
	path := filepath.Join(directory, "server.go")
	if err := os.WriteFile(path, []byte(`package dependency
import ssh "golang.org/x/crypto/ssh"
var config ssh.ServerConfig
`), 0o600); err != nil {
		t.Fatal(err)
	}
	packages = append(packages, listedPackage{
		ImportPath: "example.com/compiled-dependency/server",
		Dir:        directory,
		GoFiles:    []string{"server.go"},
		Imports:    []string{sshImportPath},
	})
	if err := validateSSHUsage(packages); err == nil {
		t.Fatal("expected a compiled dependency SSH import to be rejected")
	}
}
