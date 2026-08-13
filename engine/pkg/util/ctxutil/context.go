// Copyright 2023 The Cockroach Authors.
//
// Use of this software is governed by the Business Source License
// included in the file licenses/BSL.txt.
//
// As of the Change Date specified in that file, in accordance with
// the Business Source License, use of this software will be governed
// by the Apache License, Version 2.0, included in the file
// licenses/APL.txt.
//
// Modified by Ratio1 in 2026; see RATIO1_PATCHES.md.

package ctxutil

import (
	"context"

	"github.com/cockroachdb/cockroach/pkg/util/buildutil"
	"github.com/cockroachdb/cockroach/pkg/util/log"
)

// WhenDoneFunc is the callback invoked by context when it becomes done.
// The callback is passed the error from the parent context.
type WhenDoneFunc func(err error)

// WhenDone arranges for the specified function to be invoked when
// parent context becomes done and returns true.
// If the context is non-cancellable (i.e. `Done() == nil`), returns false and
// never calls the function.
// If the parent context is derived from context.WithCancel or
// context.WithTimeout/Deadline, then no additional goroutines are created.
// Otherwise, a goroutine is spun up by context.Context to detect
// parent cancellation.
func WhenDone(parent context.Context, done WhenDoneFunc) bool {
	if parent.Done() == nil {
		return false
	}

	// All contexts that complete (ctx.Done() != nil) used in cockroach should
	// support direct cancellation detection, since they should be derived from
	// one of the standard context.Context.
	// But, be safe and loudly fail tests in case somebody introduces strange
	// context implementation.
	if buildutil.CrdbTestBuild && !CanDirectlyDetectCancellation(parent) {
		log.Fatalf(parent, "expected context that supports direct cancellation detection, found %T", parent)
	}

	context.AfterFunc(parent, func() { done(parent.Err()) })
	return true
}

// CanDirectlyDetectCancellation reports whether the public context callback
// API can observe cancellation for parent.
func CanDirectlyDetectCancellation(parent context.Context) bool {
	return parent.Done() != nil
}
