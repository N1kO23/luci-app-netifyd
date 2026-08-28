#
# This is free software, licensed under the Apache License, Version 2.0
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-netifyd-history
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=Niko Huuskonen <niko.huuskonen.00@gmail.com>

LUCI_TITLE:=Persistent history for luci-app-netifyd
LUCI_DESCRIPTION:=Optional SQLite-backed history for luci-app-netifyd: logs completed flows and periodic traffic rollups so they survive reboots and aren't capped by the live dashboard's max_flows.
LUCI_DEPENDS:=+luci-app-netifyd +sqlite3-cli
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

define Package/$(PKG_NAME)/conffiles
/etc/config/netifyd-luci-history
endef

# call BuildPackage - OpenWrt buildroot signature
