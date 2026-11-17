TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e

# 神魔之塔 com.madhead.tos.zh
# 编译：make clean && make package FINALPACKAGE=1
# 部署：make install THEOS_DEVICE_IP=192.168.5.3 THEOS_DEVICE_PORT=22
#
# 注：本工程复用 ../tweak/TouchInjector.{h,m}，首次编译前先拷进来：
#   cp ../tweak/TouchInjector.* .

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = XiuGou

XiuGou_FILES = TOSHooks.xm TOSBoard.c XGConfig.m XGOverlay.m XGIl2Cpp.m XGFastWin.m XGSettlement.m TouchInjector.m
XiuGou_CFLAGS = -fobjc-arc -Wno-everything -Wno-deprecated-declarations -O2
XiuGou_FRAMEWORKS = UIKit Foundation QuartzCore CoreGraphics
XiuGou_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk

