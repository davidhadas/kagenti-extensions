package ctxlogger

import (
	"context"
	"testing"

	"github.com/rossoctl/cortex/authbridge/authlib/pipeline"
	"github.com/rossoctl/cortex/authbridge/authlib/plugins"
)

// The plugin is a read-only observer: every hook must return Continue and
// never mutate the Context, on both phases and both legs, with or without a
// session present.

func TestRegistered(t *testing.T) {
	found := false
	for _, name := range plugins.RegisteredPlugins() {
		if name == "ctx-logger" {
			found = true
			break
		}
	}
	if !found {
		t.Fatalf("ctx-logger not in RegisteredPlugins(); init() side-effect registration missing")
	}
}

func TestName(t *testing.T) {
	if got := NewCtxLogger().Name(); got != "ctx-logger" {
		t.Errorf("Name() = %q, want %q", got, "ctx-logger")
	}
}

func TestOnRequestContinues(t *testing.T) {
	p := NewCtxLogger()
	for _, dir := range []pipeline.Direction{pipeline.Inbound, pipeline.Outbound} {
		pctx := &pipeline.Context{Direction: dir, Method: "POST", Host: "example", Path: "/x"}
		if act := p.OnRequest(context.Background(), pctx); act.Type != pipeline.Continue {
			t.Errorf("OnRequest(%s) action.Type = %v, want Continue", dir, act.Type)
		}
	}
}

func TestOnResponseContinues(t *testing.T) {
	p := NewCtxLogger()
	for _, dir := range []pipeline.Direction{pipeline.Inbound, pipeline.Outbound} {
		pctx := &pipeline.Context{Direction: dir, StatusCode: 200}
		if act := p.OnResponse(context.Background(), pctx); act.Type != pipeline.Continue {
			t.Errorf("OnResponse(%s) action.Type = %v, want Continue", dir, act.Type)
		}
	}
}

// A nil session (before any session is attached) must not panic — the plugin
// logs "session is nil" and continues.
func TestNilSessionDoesNotPanic(t *testing.T) {
	p := NewCtxLogger()
	pctx := &pipeline.Context{Direction: pipeline.Inbound, Session: nil}
	if act := p.OnRequest(context.Background(), pctx); act.Type != pipeline.Continue {
		t.Errorf("OnRequest with nil session action.Type = %v, want Continue", act.Type)
	}
}

// A nil Context must not panic either — the plugin logs "nil context".
func TestNilContextDoesNotPanic(t *testing.T) {
	p := NewCtxLogger()
	if act := p.OnRequest(context.Background(), nil); act.Type != pipeline.Continue {
		t.Errorf("OnRequest(nil) action.Type = %v, want Continue", act.Type)
	}
	if act := p.OnResponse(context.Background(), nil); act.Type != pipeline.Continue {
		t.Errorf("OnResponse(nil) action.Type = %v, want Continue", act.Type)
	}
}
