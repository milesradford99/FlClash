package core

import (
	"bufio"
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"net/netip"
	"slices"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	N "github.com/metacubex/mihomo/common/net"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/sing/common"
	"github.com/metacubex/sing/common/buf"
)

const (
	ispProbeURL       = "https://1.1.1.1/cdn-cgi/trace"
	ispProbeBatch     = 3
	ispProbeTimeout   = 8 * time.Second
	ispHealthyHold    = 15 * time.Second
	ispInitialBackoff = 30 * time.Second
	ispMaxBackoff     = 5 * time.Minute
)

var activeISPMonitor atomic.Pointer[ispMonitor]
var ispSwitchID atomic.Uint64

type ispMonitorParams struct {
	IntervalSeconds int     `json:"interval-seconds"`
	ExpectedIP      *string `json:"expected-ip,omitempty"`
}

type ispSwitch struct {
	ID   uint64 `json:"id"`
	From string `json:"from"`
	To   string `json:"to"`
}

type ispPick struct {
	name     string
	revision uint64
}

type ispProbeResult struct {
	ip      string
	latency time.Duration
}

type ispMonitor struct {
	exit     map[string]any
	selector *outboundgroup.Selector
	members  []C.Proxy
	probe    func(context.Context, C.Proxy, bool) (ispProbeResult, error)

	mu          sync.Mutex
	configured  bool
	interval    time.Duration
	expected    netip.Addr
	cycle       context.Context
	cancelCycle context.CancelFunc
	cancelProbe context.CancelFunc
	revision    uint64
	lastTraffic time.Time
	nextProbe   time.Time
	backoff     time.Duration
	state       string
	ip          string
	switched    *ispSwitch
	healthy     map[string]time.Time
}

type observedISP struct {
	C.Proxy
	monitor *ispMonitor
}

func (p observedISP) DialContext(ctx context.Context, metadata *C.Metadata) (C.Conn, error) {
	pick := p.monitor.activity()
	conn, err := p.Proxy.DialContext(ctx, metadata)
	if err == nil {
		p.monitor.connected(pick)
		if pick.name != "" {
			conn = &observedISPConn{Conn: conn, monitor: p.monitor, pick: pick}
		}
	} else if !errors.Is(ctx.Err(), context.Canceled) {
		p.monitor.request(pick, false)
	}
	return conn, err
}

type observedISPConn struct {
	C.Conn
	monitor *ispMonitor
	pick    ispPick
	read    atomic.Bool
	closing atomic.Bool
}

func (c *observedISPConn) Read(p []byte) (int, error) {
	n, err := c.Conn.Read(p)
	c.observeRead(n, err)
	return n, err
}

func (c *observedISPConn) ReadBuffer(buffer *buf.Buffer) error {
	before := buffer.Len()
	err := c.Conn.ReadBuffer(buffer)
	c.observeRead(buffer.Len()-before, err)
	return err
}

func (c *observedISPConn) observeRead(n int, err error) {
	if n > 0 {
		c.read.Store(true)
	} else if err != nil && !c.read.Load() && !c.closing.Load() && !errors.Is(err, net.ErrClosed) {
		c.monitor.request(c.pick, false)
	}
}

func (c *observedISPConn) NeedHandshake() bool { return N.NeedHandshake(c.Conn) }

func (c *observedISPConn) Close() error {
	c.closing.Store(true)
	return c.Conn.Close()
}

func (c *observedISPConn) CloseWrite() error {
	c.closing.Store(true)
	if half, ok := common.Cast[interface{ CloseWrite() error }](c.Conn); ok {
		return half.CloseWrite()
	}
	return c.Conn.Close()
}

// Called under configMu, before the new proxy map is published.
func installISPMonitor(cfg *config.Config) {
	if old := activeISPMonitor.Swap(nil); old != nil {
		old.pause()
	}
	if cfg == nil {
		return
	}
	if _, ok := ispListenerOption(cfg); !ok {
		return
	}
	raw, err := readRawConfig(runningConfigPath())
	if err != nil {
		return
	}
	var exit map[string]any
	for _, definition := range raw.Proxy {
		if definition["name"] == ispOutboundName {
			exit = definition
			break
		}
	}
	if exit == nil {
		return
	}
	proxy := cfg.Proxies[ispOutboundName]
	selector := cfg.Proxies[ispSharedGroup].Adapter().(*outboundgroup.Selector)
	m := &ispMonitor{
		exit: exit, selector: selector, members: selector.GetProxies(false),
		state: "idle", healthy: make(map[string]time.Time),
	}
	m.probe = m.probeNode
	cfg.Proxies[ispOutboundName] = observedISP{Proxy: proxy, monitor: m}
	activeISPMonitor.Store(m)
}

func configureISPMonitor(params ispMonitorParams) error {
	if params.IntervalSeconds < 0 || params.IntervalSeconds > 86400 {
		return errors.New("invalid ISP monitoring interval")
	}
	var expected netip.Addr
	if params.ExpectedIP != nil && *params.ExpectedIP != "" {
		var err error
		expected, err = netip.ParseAddr(*params.ExpectedIP)
		if err != nil {
			return errors.New("invalid expected ISP address")
		}
	}
	configMu.Lock()
	defer configMu.Unlock()
	if m := activeISPMonitor.Load(); m != nil {
		m.configure(time.Duration(params.IntervalSeconds)*time.Second, params.ExpectedIP != nil, expected.Unmap())
	}
	return nil
}

func (m *ispMonitor) configure(interval time.Duration, setExpected bool, expected netip.Addr) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if !setExpected && !m.configured {
		return
	}
	if m.configured && interval == m.interval && (!setExpected || expected == m.expected) {
		return
	}
	m.configured = true
	m.interval = interval
	if setExpected {
		m.expected = expected
	}
	lastTraffic := m.lastTraffic
	m.pauseLocked()
	m.lastTraffic = lastTraffic
	m.resumeLocked()
}

func (m *ispMonitor) resume() {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.resumeLocked()
}

func (m *ispMonitor) resumeLocked() {
	if !m.configured || !isRunning.Load() || m.cycle != nil {
		return
	}
	ctx, cancel := context.WithCancel(context.Background())
	m.cycle, m.cancelCycle = ctx, cancel
	if m.interval > 0 {
		go m.periodic(ctx, m.interval)
	}
}

func (m *ispMonitor) pause() {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.pauseLocked()
}

func (m *ispMonitor) pauseLocked() {
	if m.cancelCycle != nil {
		m.cancelCycle()
	}
	m.cycle, m.cancelCycle = nil, nil
	m.lastTraffic = time.Time{}
	m.resetChoiceLocked()
}

func (m *ispMonitor) resetChoice() {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.resetChoiceLocked()
}

func (m *ispMonitor) resetChoiceLocked() {
	if m.cancelProbe != nil {
		m.cancelProbe()
		m.cancelProbe = nil
	}
	m.revision++
	m.nextProbe, m.backoff = time.Time{}, 0
	m.state, m.ip, m.switched = "idle", "", nil
}

func (m *ispMonitor) activity() ispPick {
	selectMu.Lock()
	defer selectMu.Unlock()
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.cycle == nil {
		return ispPick{}
	}
	m.lastTraffic = time.Now()
	return ispPick{name: m.selector.Now(), revision: m.revision}
}

func (m *ispMonitor) connected(pick ispPick) {
	if pick.name == "" {
		return
	}
	m.mu.Lock()
	if m.cycle == nil || m.revision != pick.revision {
		m.mu.Unlock()
		return
	}
	checkRecovered := m.state == "down" && m.expected.IsValid()
	if m.state == "idle" || (m.state == "down" && !checkRecovered) {
		m.state = "healthy"
		m.backoff, m.nextProbe = 0, time.Time{}
	}
	m.mu.Unlock()
	if checkRecovered {
		m.request(pick, false)
	}
}

func (m *ispMonitor) periodic(ctx context.Context, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			selectMu.Lock()
			m.mu.Lock()
			pick := ispPick{name: m.selector.Now(), revision: m.revision}
			recent := m.cycle == ctx && time.Since(m.lastTraffic) <= 2*interval
			m.mu.Unlock()
			selectMu.Unlock()
			if recent {
				m.request(pick, true)
			}
		}
	}
}

func (m *ispMonitor) request(pick ispPick, periodic bool) {
	if pick.name == "" || !isRunning.Load() || activeISPMonitor.Load() != m {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.cycle == nil || m.cancelProbe != nil || pick.revision != m.revision ||
		(time.Now().Before(m.nextProbe) && (!periodic || m.state == "down")) {
		return
	}
	ctx, cancel := context.WithCancel(m.cycle)
	m.cancelProbe = cancel
	m.state = "checking"
	var current C.Proxy
	candidates := make([]C.Proxy, 0, len(m.members))
	for _, proxy := range m.members {
		if proxy.Name() == pick.name {
			current = proxy
		} else {
			candidates = append(candidates, proxy)
		}
	}
	slices.SortStableFunc(candidates, func(a, b C.Proxy) int {
		return m.healthy[b.Name()].Compare(m.healthy[a.Name()])
	})
	go m.recover(ctx, pick, current, candidates, m.expected, periodic)
}

func (m *ispMonitor) recover(ctx context.Context, pick ispPick, current C.Proxy, candidates []C.Proxy, expected netip.Addr, periodic bool) {
	if current != nil {
		result, err := m.probe(ctx, current, periodic || expected.IsValid())
		if err == nil && matchesISPAddress(result.ip, expected) {
			m.finish(ctx, pick, current.Name(), result.ip)
			return
		}
	}
	for batch := range slices.Chunk(candidates, ispProbeBatch) {
		if ctx.Err() != nil {
			return
		}
		type option struct {
			proxy C.Proxy
			probe ispProbeResult
		}
		results := make(chan option, len(batch))
		for _, proxy := range batch {
			go func() {
				result, err := m.probe(ctx, proxy, false)
				if err != nil {
					results <- option{}
					return
				}
				results <- option{proxy, result}
			}()
		}
		healthy := make([]option, 0, len(batch))
		for range batch {
			if result := <-results; result.proxy != nil {
				healthy = append(healthy, result)
			}
		}
		slices.SortFunc(healthy, func(a, b option) int {
			if a.probe.latency < b.probe.latency {
				return -1
			}
			if a.probe.latency > b.probe.latency {
				return 1
			}
			return strings.Compare(a.proxy.Name(), b.proxy.Name())
		})
		for _, result := range healthy {
			if ctx.Err() != nil {
				return
			}
			ip := ""
			if expected.IsValid() {
				proof, err := m.probe(ctx, result.proxy, true)
				if err != nil || !matchesISPAddress(proof.ip, expected) {
					continue
				}
				ip = proof.ip
			}
			m.finish(ctx, pick, result.proxy.Name(), ip)
			return
		}
	}
	m.finish(ctx, pick, "", "")
}

func matchesISPAddress(address string, expected netip.Addr) bool {
	if !expected.IsValid() {
		return true
	}
	actual, err := netip.ParseAddr(address)
	return err == nil && actual.Unmap() == expected
}

func (m *ispMonitor) finish(ctx context.Context, pick ispPick, choice, ip string) {
	configMu.Lock()
	defer configMu.Unlock()
	selectMu.Lock()
	defer selectMu.Unlock()
	m.mu.Lock()
	defer m.mu.Unlock()
	if ctx.Err() != nil || activeISPMonitor.Load() != m || !isRunning.Load() ||
		pick.revision != m.revision || m.cancelProbe == nil {
		return
	}
	m.cancelProbe()
	m.cancelProbe = nil
	if m.selector.Now() != pick.name {
		m.resetChoiceLocked()
		return
	}
	if choice == "" {
		m.backoff = min(ispMaxBackoff, max(ispInitialBackoff, 2*m.backoff))
		m.nextProbe = time.Now().Add(m.backoff)
		m.state, m.ip = "down", ""
		return
	}
	if choice != pick.name {
		if m.selector.Set(choice) != nil {
			m.resetChoiceLocked()
			return
		}
		m.revision++
		m.switched = &ispSwitch{ID: ispSwitchID.Add(1), From: pick.name, To: choice}
		refreshRouteLocked(routeUnchanged)
	}
	m.healthy[choice] = time.Now()
	m.backoff = 0
	m.nextProbe = time.Now().Add(ispHealthyHold)
	m.state, m.ip = "healthy", ip
}

func (m *ispMonitor) status() map[string]any {
	m.mu.Lock()
	defer m.mu.Unlock()
	return map[string]any{"state": m.state, "ip": m.ip, "switch": m.switched}
}

func (m *ispMonitor) probeNode(ctx context.Context, node C.Proxy, readIP bool) (ispProbeResult, error) {
	ctx, cancel := context.WithTimeout(ctx, ispProbeTimeout)
	defer cancel()
	probe, err := adapter.ParseProxy(m.exit, adapter.WithDialerForAPI(ispCandidateDialer{node: node}))
	if err != nil {
		return ispProbeResult{}, err
	}
	defer probe.Close()
	method := http.MethodHead
	if readIP {
		method = http.MethodGet
	}
	request, err := http.NewRequestWithContext(ctx, method, ispProbeURL, nil)
	if err != nil {
		return ispProbeResult{}, err
	}
	transport := &http.Transport{
		DisableKeepAlives: true,
		DialContext: func(ctx context.Context, _, address string) (net.Conn, error) {
			target, err := ispProbeDestination(address)
			if err != nil {
				return nil, err
			}
			return probe.DialContext(ctx, target)
		},
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, CheckRedirect: func(*http.Request, []*http.Request) error {
		return http.ErrUseLastResponse
	}}
	start := time.Now()
	response, err := client.Do(request)
	if err != nil {
		return ispProbeResult{}, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return ispProbeResult{}, errors.New("ISP health check returned an unexpected status")
	}
	result := ispProbeResult{latency: time.Since(start)}
	if !readIP {
		return result, nil
	}
	scanner := bufio.NewScanner(io.LimitReader(response.Body, 8192))
	for scanner.Scan() {
		if value, ok := strings.CutPrefix(scanner.Text(), "ip="); ok {
			if ip, err := netip.ParseAddr(value); err == nil {
				result.ip = ip.Unmap().String()
				return result, nil
			}
		}
	}
	return ispProbeResult{}, errors.New("ISP health check did not return an IP address")
}

type ispCandidateDialer struct {
	node C.Proxy
}

func (d ispCandidateDialer) DialContext(ctx context.Context, _, address string) (net.Conn, error) {
	target, err := ispProbeDestination(address)
	if err != nil {
		return nil, err
	}
	return d.node.DialContext(ctx, target)
}

func (ispCandidateDialer) ListenPacket(context.Context, string, string, netip.AddrPort) (net.PacketConn, error) {
	return nil, C.ErrNotSupport
}

func ispProbeDestination(address string) (*C.Metadata, error) {
	host, port, err := net.SplitHostPort(address)
	if err != nil {
		return nil, err
	}
	value, err := strconv.ParseUint(port, 10, 16)
	if err != nil {
		return nil, err
	}
	metadata := &C.Metadata{NetWork: C.TCP, Type: C.INNER, DstPort: uint16(value)}
	if ip, err := netip.ParseAddr(host); err == nil {
		metadata.DstIP = ip.Unmap()
	} else {
		metadata.Host = host
	}
	return metadata, nil
}
