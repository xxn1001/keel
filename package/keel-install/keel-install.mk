KEEL_INSTALL_VERSION = 0.1
KEEL_INSTALL_SITE = $(BR2_EXTERNAL_KEEL_PATH)/src/installer
KEEL_INSTALL_SITE_METHOD = local
# TODO: choose the project license before release.
KEEL_INSTALL_LICENSE = Proprietary
KEEL_INSTALL_INSTALL_STAGING = NO
# ADR-0016/ADR-0018: the installer never enters the system root. It is
# installed into $(BINARIES_DIR) and only mkrecovery.sh consumes it.
KEEL_INSTALL_INSTALL_TARGET = NO
KEEL_INSTALL_INSTALL_IMAGES = YES

define KEEL_INSTALL_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D) clean
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D) \
		CC="$(TARGET_CC)" \
		CFLAGS="$(TARGET_CFLAGS) -std=c99 -Wall -Wextra -Werror" \
		LDFLAGS="$(TARGET_LDFLAGS)"
endef

define KEEL_INSTALL_INSTALL_IMAGES_CMDS
	$(INSTALL) -D -m 0755 $(@D)/keel-install $(BINARIES_DIR)/keel-install
endef

$(eval $(generic-package))
