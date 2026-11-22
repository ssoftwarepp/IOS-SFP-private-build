export ARCHS = arm64 arm64e
export TARGET = iphone:clang:16.5:15.0
export THEOS_PACKAGE_SCHEME = rootless

PADDLE_DEPS ?= $(CURDIR)/third_party/paddleocr/runtime/ios
SUBPROJECTS = appdelegate zxtouch-binary zxtouch-runner pccontrol
ifneq ($(wildcard $(PADDLE_DEPS)/include/onnxruntime_cxx_api.h),)
SUBPROJECTS += ocrworker
endif

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/aggregate.mk

ifneq ($(filter ocrworker,$(SUBPROJECTS)),)
after-stage::
	mkdir -p "$(THEOS_STAGING_DIR)/usr/share/zxtouch/paddleocr"
	cp third_party/paddleocr/models/det.onnx third_party/paddleocr/models/rec.onnx third_party/paddleocr/models/dictionary.json third_party/paddleocr/models/sha256.json "$(THEOS_STAGING_DIR)/usr/share/zxtouch/paddleocr/"
endif

after-install::
	install.exec "chown -R mobile:mobile /var/mobile/Library/ZXTouch && killall -9 SpringBoard;"
