ARCHS = arm64 arm64e
TARGET := iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = ADManager

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ADManagerRotation

ADManagerRotation_FILES = Tweak.x
ADManagerRotation_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
