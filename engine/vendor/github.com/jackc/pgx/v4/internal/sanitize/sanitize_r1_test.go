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

package sanitize

import (
	"math"
	"testing"
)

func TestDollarQuotedStringDoesNotExposePlaceholder(t *testing.T) {
	query, err := NewQuery("select $tag$ $1 $tag$, $1")
	if err != nil {
		t.Fatal(err)
	}
	got, err := query.Sanitize("$tag$; select 2; --")
	if err != nil {
		t.Fatal(err)
	}
	want := "select $tag$ $1 $tag$,  '$tag$; select 2; --' "
	if got != want {
		t.Fatalf("unexpected sanitized SQL:\n got: %q\nwant: %q", got, want)
	}
}

func TestPlaceholderOverflowIsRejected(t *testing.T) {
	query, err := NewQuery("select $92233720368547758070")
	if err != nil {
		t.Fatal(err)
	}
	if len(query.Parts) != 2 || query.Parts[1] != math.MaxInt32 {
		t.Fatalf("placeholder was not clamped: %#v", query.Parts)
	}
	if _, err := query.Sanitize(int64(1)); err == nil {
		t.Fatal("expected an overflowing placeholder to be rejected")
	}
}
