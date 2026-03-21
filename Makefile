ARCHS = arm64
TARGET := iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = ADManagerRotation

ADManagerRotation_FILES = Tweak.x
ADManagerRotation_CFLAGS = -fobjc-arc
ADManagerRotation_LDFLAGS = -Wl,-install_name,@executable_path/ADManagerRotation.dylib
ADManagerRotation_CODESIGN = /usr/bin/true

include $(THEOS_MAKE_PATH)/library.mk

