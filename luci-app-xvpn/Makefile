# SPDX-License-Identifier: MIT

include $(TOPDIR)/rules.mk

LUCI_TITLE:=XVPN - xray VPN client with auto failover
LUCI_DEPENDS:=+xray-core +curl +kmod-nft-tproxy +kmod-nft-socket +kmod-nft-bridge \
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

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
