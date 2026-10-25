# 声临 · 陌陌版（ShenglinMomo）
# 基于 AWECommentAudioTweak 的 TTS 引擎层，集成到陌陌私聊语音发送链路

ARCHS = arm64
TARGET := iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = ShenglinMomo

ShenglinMomo_FILES = Tweak/Tweak.x \
	Tweak/SLSettingsPanel.m \
	Tweak/SLPipeline.m \
	Tweak/AWECAUtils.m \
	Tweak/AWECATTSManager.m \
	Tweak/AWECATOSUploader.m \
	Tweak/AWECAAPISettingsController.m \
	Tweak/AWECATTSVoiceListController.m \
	Tweak/AWECAAudioReplacer.m

ShenglinMomo_CFLAGS = -fobjc-arc
ShenglinMomo_LDFLAGS = -Xlinker -not_for_dyld_shared_cache
ShenglinMomo_FRAMEWORKS = UIKit Foundation AVFoundation CoreAudio CoreMedia UniformTypeIdentifiers SafariServices PhotosUI
ShenglinMomo_LIBRARIES = objc

include $(THEOS_MAKE_PATH)/library.mk

# 产物拷到根目录
after-all::
	$(ECHO_NOTHING)cp -f "$(THEOS_OBJ_DIR)/$(LIBRARY_NAME).dylib" "$(THEOS_PROJECT_DIR)/$(LIBRARY_NAME).dylib"$(ECHO_END)
