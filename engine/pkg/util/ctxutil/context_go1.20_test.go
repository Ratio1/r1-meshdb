// Copyright 2026 Ratio1.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package ctxutil

import (
	"context"
	"errors"
	"sync/atomic"
	"testing"
	"time"
)

func TestWhenDoneModernContext(t *testing.T) {
	cause := errors.New("test cancellation")
	ctx, cancel := context.WithCancelCause(context.Background())
	result := make(chan error, 1)
	var calls atomic.Int32

	if !WhenDone(ctx, func(err error) {
		calls.Add(1)
		result <- err
	}) {
		t.Fatal("expected cancellable context to register")
	}
	cancel(cause)

	select {
	case err := <-result:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("expected context.Canceled, got %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for cancellation callback")
	}

	time.Sleep(10 * time.Millisecond)
	if got := calls.Load(); got != 1 {
		t.Fatalf("expected one callback, got %d", got)
	}
	if !errors.Is(context.Cause(ctx), cause) {
		t.Fatalf("expected cancellation cause %v, got %v", cause, context.Cause(ctx))
	}
}

func TestWhenDoneRejectsNonCancellableContext(t *testing.T) {
	if WhenDone(context.Background(), func(error) {
		t.Fatal("non-cancellable callback must not run")
	}) {
		t.Fatal("expected non-cancellable context to be rejected")
	}
}
