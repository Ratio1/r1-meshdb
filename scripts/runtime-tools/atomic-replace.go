// Copyright 2026 Ratio1
// Licensed under the Apache License, Version 2.0. See LICENSE.

// Command r1-atomic-replace atomically replaces one regular file with another
// in the same directory. It deliberately exposes less behavior than mv.
package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

func fail(format string, values ...any) {
	fmt.Fprintf(os.Stderr, "r1-atomic-replace: "+format+"\n", values...)
	os.Exit(1)
}

func regularFile(path string, allowMissing bool) error {
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) && allowMissing {
		return nil
	}
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() {
		return fmt.Errorf("not a regular file")
	}
	return nil
}

func main() {
	if len(os.Args) != 3 {
		fail("usage: r1-atomic-replace <source> <destination>")
	}

	source, err := filepath.Abs(os.Args[1])
	if err != nil {
		fail("invalid source: %v", err)
	}
	destination, err := filepath.Abs(os.Args[2])
	if err != nil {
		fail("invalid destination: %v", err)
	}
	if filepath.Dir(source) != filepath.Dir(destination) {
		fail("source and destination must be in the same directory")
	}
	if err := regularFile(source, false); err != nil {
		fail("invalid source %q: %v", source, err)
	}
	if err := regularFile(destination, true); err != nil {
		fail("invalid destination %q: %v", destination, err)
	}
	if err := os.Rename(source, destination); err != nil {
		fail("rename failed: %v", err)
	}
}
