// Copyright 2026 Ratio1
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

package storage

import (
	"strings"
	"testing"

	"github.com/cockroachdb/errors"
	"github.com/cockroachdb/pebble"
)

func capturePanic(fn func()) (recovered interface{}) {
	defer func() {
		recovered = recover()
	}()
	fn()
	return nil
}

func TestPanicOnLocalPebbleCorruption(t *testing.T) {
	for _, err := range []error{
		pebble.ErrCorruption,
		errors.Wrap(pebble.ErrCorruption, "checksum mismatch"),
	} {
		recovered := capturePanic(func() { panicOnLocalPebbleCorruption(err) })
		recoveredErr, ok := recovered.(error)
		if !ok {
			t.Fatalf("expected an error panic, got %T", recovered)
		}
		if !errors.Is(recoveredErr, pebble.ErrCorruption) {
			t.Fatalf("panic lost Pebble corruption marker: %v", recoveredErr)
		}
		if !strings.Contains(recoveredErr.Error(), "local corruption detected:") {
			t.Fatalf("panic has no recovery signal: %v", recoveredErr)
		}
	}

	for _, err := range []error{
		nil,
		errors.New("pebble: corruption: checksum mismatch"),
	} {
		if recovered := capturePanic(func() { panicOnLocalPebbleCorruption(err) }); recovered != nil {
			t.Fatalf("non-corruption error caused panic: %v", recovered)
		}
	}
}
