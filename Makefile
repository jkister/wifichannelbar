include $(THEOS)/makefiles/common.mk

#export TARGET = simulator:clang
#export ARCH = x86_64

TWEAK_NAME = WifiChannelBar
WifiChannelBar_FILES = Reachability.m Tweak.xm
WifiChannelBar_FRAMEWORKS = CoreFoundation UIKit SystemConfiguration
WifiChannelBar_CODESIGN_FLAGS = -Sentitlements.xml

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 SpringBoard"
include $(THEOS_MAKE_PATH)/aggregate.mk
