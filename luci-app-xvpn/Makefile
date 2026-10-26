# SPDX-License-Identifier: MIT

include $(TOPDIR)/rules.mk

LUCI_TITLE:=XVPN - xray VPN client with auto failover
LUCI_DEPENDS:=+luci-base +xray-core +curl +kmod-nft-tproxy +kmod-nft-socket +kmod-nft-bridge \
	+ucode +ucode-mod-fs +ucode-mod-uci +ucode-mod-ubus +ucode-mod-uloop
LUCI_PKGARCH:=all

PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_MAINTAINER:=Artem Sokolov <arseso.main@gmail.com>

# luci.mk writes these into the ipk control file instead of PKG_MAINTAINER/URL
LUCI_MAINTAINER:=$(PKG_MAINTAINER)
LUCI_URL:=https://github.com/Arseso/openwrt-xray-vless-client

define Package/luci-app-xvpn/conffiles
/etc/config/xvpn
/etc/xvpn/
endef

define Package/luci-app-xvpn/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	uci -q delete firewall.xvpn && uci commit firewall
	# fixed names of the VPN SSIDs (xvpn-apN); applied at the next radio restart, not now:
	# the package may be removed over that very Wi-Fi
	c=
	for s in $$(uci -q -X show wireless | sed -n "s/^wireless\.\([^.]*\)\.ifname='xvpn-ap[0-9]*'$$/\1/p"); do
		uci -q delete wireless.$$s.ifname && c=1
	done
	[ -z "$$c" ] || uci commit wireless
}
exit 0
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
