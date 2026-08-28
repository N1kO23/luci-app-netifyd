#
# This is free software, licensed under the Apache License, Version 2.0
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-netifyd
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=Niko Huuskonen <niko.huuskonen.00@gmail.com>

LUCI_TITLE:=LuCI support for netifyd
LUCI_DESCRIPTION:=Dashboard for the netifyd deep-packet-inspection agent: live flow classification, protocol/application/category breakdowns and top talkers, sourced directly from netifyd's JSON socket.
LUCI_DEPENDS:=+netifyd +rpcd +socat +jq
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

define Package/$(PKG_NAME)/conffiles
/etc/config/netifyd-luci
endef

# call BuildPackage - OpenWrt buildroot signature
