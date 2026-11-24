package core

import (
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	inbound "github.com/metacubex/mihomo/listener/inbound"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
)

const (
	ispInboundName  = "__flclash_chrome_isp__"
	ispOutboundName = "__flclash_isp_exit__"
	ispSharedGroup  = "FlClash Shared VPN"
	ispLocalPort    = "17890"
)

var ispListener C.InboundListener

func updateISPListener(cfg *config.Config) {
	options, valid := ispListenerOption(cfg)
	if valid && ispListener != nil && options.Equal(ispListener.Config()) {
		return
	}

	stopISPListener()
	if !valid {
		return
	}

	listener, err := inbound.NewMixed(options)
	if err == nil {
		err = listener.Listen(tunnel.Tunnel)
	}
	if err != nil {
		if listener != nil {
			_ = listener.Close()
		}
		log.Warnln("Chrome ISP listener could not start: %v", err)
		return
	}
	ispListener = listener
}

func ispListenerOption(cfg *config.Config) (*inbound.MixedOption, bool) {
	listener := cfg.Listeners[ispInboundName]
	if listener == nil || cfg.Proxies[ispOutboundName] == nil || cfg.Proxies[ispSharedGroup] == nil {
		return nil, false
	}
	options, ok := listener.Config().(*inbound.MixedOption)
	exit := cfg.Proxies[ispOutboundName]
	group, isSelector := cfg.Proxies[ispSharedGroup].Adapter().(*outboundgroup.Selector)
	if !ok || options.Listen != "127.0.0.1" || options.Port != ispLocalPort ||
		options.SpecialRules != "" || options.SpecialProxy != ispOutboundName || options.UDP ||
		exit.Type() != C.Socks5 || exit.SupportUDP() || exit.ProxyInfo().DialerProxy != ispSharedGroup ||
		!isSelector || group.EmptyFallback().Name() != "REJECT" {
		return nil, false
	}

	members := group.GetProxies(false)
	if len(members) == 0 {
		return nil, false
	}
	for _, proxy := range members {
		if proxy.Addr() == "" || proxy.ProxyInfo().DialerProxy != "" {
			return nil, false
		}
	}
	return options, true
}

func stopISPListener() {
	if ispListener != nil {
		_ = ispListener.Close()
		ispListener = nil
	}
}
