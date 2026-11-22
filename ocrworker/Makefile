export TARGET = iphone:clang:latest:13.0
export ARCHS = arm64
export DEBUG = 0
include $(THEOS)/makefiles/common.mk

TOOL_NAME = zxtouch-ocr-worker
PADDLE_DEPS ?= $(CURDIR)/../third_party/paddleocr/runtime/ios
zxtouch-ocr-worker_FILES = main.mm PaddleOCR.mm ../third_party/paddleocr/clipper/clipper.cpp
zxtouch-ocr-worker_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -I$(PADDLE_DEPS)/include -I$(PADDLE_DEPS)/opencv/include/opencv4
zxtouch-ocr-worker_CCFLAGS = -std=c++17 -fexceptions -fcxx-exceptions
zxtouch-ocr-worker_FRAMEWORKS = Foundation CoreGraphics ImageIO
zxtouch-ocr-worker_LIBRARIES = z
zxtouch-ocr-worker_LDFLAGS = $(PADDLE_DEPS)/lib/libonnxruntime.a $(PADDLE_DEPS)/opencv/lib/libopencv_imgproc.a $(PADDLE_DEPS)/opencv/lib/libopencv_core.a
zxtouch-ocr-worker_CODESIGN_FLAGS = -Sentitlements.plist
zxtouch-ocr-worker_INSTALL_PATH = /usr/libexec/zxtouch
include $(THEOS_MAKE_PATH)/tool.mk

