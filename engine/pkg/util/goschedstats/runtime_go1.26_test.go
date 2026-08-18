// Copyright 2026 Ratio1
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

//go:build gc && go1.26
// +build gc,go1.26

package goschedstats

import "testing"

func TestRuntimeMetricsRunnableCount(t *testing.T) {
	runnable, procs := numRunnableGoroutines()
	if runnable < 0 {
		t.Fatalf("runnable goroutine count is negative: %d", runnable)
	}
	if procs < 1 {
		t.Fatalf("GOMAXPROCS metric must be positive: %d", procs)
	}
}
