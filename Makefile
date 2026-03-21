ARCHS = arm64 arm64e
TARGET := iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = ADManager

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ADManagerRotation

ADManagerRotation_FILES = Tweak.x
ADManagerRotation_CFLAGS = -fobjc-arc
ADManagerRotation_CODESIGN_FLAGS = -S/dev/null

include $(THEOS_MAKE_PATH)/tweak.mk

