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
