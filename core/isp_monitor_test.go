package core

import (
	"context"
	"errors"
	"net/netip"
	"slices"
	"sync"
	"testing"
	"time"

	"github.com/metacubex/mihomo/adapter/outboundgroup"
	C "github.com/metacubex/mihomo/constant"
)

func testISPMonitor(t *testing.T, nodes ...string) *ispMonitor {
	t.Helper()
	selector := selectorGroup(t, ispSharedGroup, nodes...).Adapter().(*outboundgroup.Selector)
	m := &ispMonitor{selector: selector, members: selector.GetProxies(false), healthy: map[string]time.Time{}, state: "idle"}
	previous := activeISPMonitor.Swap(m)
	running := isRunning.Swap(true)
	m.configure(0, true, netip.MustParseAddr("203.0.113.20"))
	t.Cleanup(func() {
		m.pause()
		activeISPMonitor.Store(previous)
		isRunning.Store(running)
	})
	return m
}

func TestISPMonitorChoosesFirstHealthyBatchWithExpectedExit(t *testing.T) {
	m := testISPMonitor(t, "a", "b", "c", "d", "e")
	var mu sync.Mutex
	var calls []string
	m.probe = func(_ context.Context, node C.Proxy, readIP bool) (ispProbeResult, error) {
		mu.Lock()
		calls = append(calls, node.Name())
		mu.Unlock()
		if node.Name() == "a" {
			return ispProbeResult{}, errors.New("link failed")
		}
		latency := map[string]time.Duration{"b": 20, "c": 50, "d": 30}[node.Name()] * time.Millisecond
		result := ispProbeResult{latency: latency}
		if readIP {
			result.ip = "203.0.113.20"
			if node.Name() == "b" {
				result.ip = "203.0.113.21"
			}
		}
		return result, nil
	}
	m.request(m.activity(), false)
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		state := m.status()
		if result, _ := state["switch"].(*ispSwitch); result != nil {
			if result.From != "a" || result.To != "d" || state["ip"] != "203.0.113.20" {
				t.Fatalf("unexpected switch: %+v (%v)", result, state)
			}
			mu.Lock()
			defer mu.Unlock()
			if len(calls) != 6 || slices.Contains(calls, "e") {
				t.Fatalf("unexpected probes: %v", calls)
			}
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatalf("no recovery recorded: %v", m.status())
}

func TestISPMonitorDoesNotOverwriteManualSelectionDuringProbe(t *testing.T) {
	m := testISPMonitor(t, "a", "b", "c")
	started := make(chan struct{})
	released := make(chan struct{})
	m.probe = func(ctx context.Context, node C.Proxy, _ bool) (ispProbeResult, error) {
		if node.Name() == "a" {
			close(started)
			<-ctx.Done()
			close(released)
			return ispProbeResult{}, ctx.Err()
		}
		return ispProbeResult{ip: "203.0.113.20"}, nil
	}
	m.request(m.activity(), false)
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("probe did not start")
	}
	selectMu.Lock()
	err := m.selector.Set("c")
	m.resetChoice()
	selectMu.Unlock()
	if err != nil {
		t.Fatal(err)
	}
	select {
	case <-released:
	case <-time.After(time.Second):
		t.Fatal("probe was not canceled")
	}
	if state := m.status(); state["state"] != "idle" || state["switch"].(*ispSwitch) != nil {
		t.Fatalf("stale state after a manual pick: %v", state)
	}
}
