package core

import (
	"net/url"
	"slices"

	"github.com/metacubex/mihomo/adapter/outboundgroup"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/listener"
	"github.com/metacubex/mihomo/tunnel"
)

const managedISPGroup = "Managed ISP"

func handleISPStatus() map[string]any {
	configMu.Lock()
	defer configMu.Unlock()
	cfg := currentConfig
	if cfg == nil {
		return map[string]any{"loaded": false}
	}

	rules := tunnel.Rules()
	ruleOK := false
	if len(rules) == 1 && rules[0].RuleType() == C.MATCH {
		ruleOK = rules[0].Adapter() == managedISPGroup
		if rule, ok := rules[0].(C.RuleWrapper); ok && rule.IsDisabled() {
			ruleOK = false
		}
	}

	count, chainOK := inspectISPGroup(tunnel.Proxies())
	dnsOK := cfg.DNS != nil && cfg.DNS.Enable && !cfg.DNS.IPv6 &&
		cfg.DNS.UseHosts && !cfg.DNS.UseSystemHosts &&
		cfg.DNS.EnhancedMode.String() == "fake-ip" &&
		managedDoH(cfg.DNS.NameServer) && managedDoH(cfg.DNS.ProxyServerNameserver) &&
		len(cfg.DNS.Fallback) == 0 && len(cfg.DNS.DirectNameServer) == 0 &&
		len(cfg.DNS.NameServerPolicy) == 0 && len(cfg.DNS.ProxyServerPolicy) == 0

	tun := cfg.General.Tun
	return map[string]any{
		"loaded":      true,
		"running":     isRunning.Load(),
		"rule_mode":   tunnel.Mode() == tunnel.Rule,
		"rule_chain":  ruleOK && chainOK,
		"candidates":  count,
		"managed_doh": dnsOK,
		"tun":         tun.Enable,
		"native_dns": tun.DNSMode == "native" && tun.StrictRoute &&
			len(tun.DNSHijack) == 2 && slices.Contains(tun.DNSHijack, "any:53") &&
			slices.Contains(tun.DNSHijack, "tcp://any:53"),
		"mixed_port": listener.GetPorts().MixedPort,
		"allow_lan":  cfg.General.AllowLan,
		"ipv6":       cfg.General.IPv6,
		"has_hosts":  cfg.Hosts != nil,
	}
}

func inspectISPGroup(proxies map[string]C.Proxy) (int, bool) {
	proxy := proxies[managedISPGroup]
	if proxy == nil {
		return 0, false
	}
	group, ok := proxy.Adapter().(*outboundgroup.Fallback)
	if !ok || group.EmptyFallback().Name() != "REJECT" || group.SupportUDP() {
		return 0, false
	}
	members := group.GetProxies(false)
	if len(members) == 0 {
		return 0, false
	}
	for _, member := range members {
		upstream := proxies[member.ProxyInfo().DialerProxy]
		if member.Type() != C.Socks5 || member.Addr() != members[0].Addr() ||
			upstream == nil || upstream.Addr() == "" || upstream.ProxyInfo().DialerProxy != "" {
			return len(members), false
		}
	}
	return len(members), true
}

func managedDoH(servers []dns.NameServer) bool {
	return len(servers) > 0 && !slices.ContainsFunc(servers, func(server dns.NameServer) bool {
		endpoint, err := url.Parse(server.Addr)
		return err != nil || endpoint.Scheme != "https" || endpoint.User != nil ||
			server.Net != "https" || server.ProxyName != managedISPGroup ||
			server.Params["skip-cert-verify"] == "true"
	})
}
