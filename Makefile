# 声临 · 陌陌版（ShenglinMomo）
# 文字转语音（#tts 口令）→ 语音消息发送；TTS 引擎层复用 AWECommentAudioTweak

ARCHS = arm64
TARGET := iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = ShenglinMomo

ShenglinMomo_FILES = Tweak/Tweak.x \
	Tweak/SLSettingsPanel.m \
	Tweak/SLPipeline.m \
	Tweak/SLEntry.m \
	Tweak/SLAMREncoder.m \
	Tweak/SLPCMTool.m \
	Tweak/SLLog.m \
	Tweak/SLLogViewController.m \
	Tweak/AWECAUtils.m \
	Tweak/AWECATTSManager.m \
	Tweak/AWECATOSUploader.m \
	Tweak/AWECAAPISettingsController.m \
	Tweak/AWECATTSVoiceListController.m \
	Tweak/SLVoiceImportController.m \
	Tweak/SLVoicePack.m \
	Tweak/SLVoicePackController.m \
	Tweak/SLTrimController.m \
	Tweak/AWECAAudioReplacer.m

ShenglinMomo_CFLAGS = -fobjc-arc
ShenglinMomo_LDFLAGS = -Xlinker -not_for_dyld_shared_cache
ShenglinMomo_FRAMEWORKS = UIKit Foundation AVFoundation CoreAudio CoreMedia AudioToolbox UniformTypeIdentifiers SafariServices PhotosUI
ShenglinMomo_LIBRARIES = objc

# AMR-NB 编码器（opencore-amrnb 静态库，可选）
# 由 CI 的 vendor 步骤下载；缺失时自动降级为「直接发送原始音频」，不影响构建。
AMR_LIB := $(wildcard vendor/amr/lib/libopencore-amrnb.a)
ifneq ($(AMR_LIB),)
ShenglinMomo_CFLAGS += -DSL_HAS_AMR -Ivendor/amr/include
ShenglinMomo_LDFLAGS += $(AMR_LIB) -lc++
$(info ShenglinMomo: AMR encoder enabled -> $(AMR_LIB))
else
$(info ShenglinMomo: AMR encoder NOT found, will send raw audio)
endif

include $(THEOS_MAKE_PATH)/library.mk

# 产物拷到根目录
after-all::
	$(ECHO_NOTHING)cp -f "$(THEOS_OBJ_DIR)/$(LIBRARY_NAME).dylib" "$(THEOS_PROJECT_DIR)/$(LIBRARY_NAME).dylib"$(ECHO_END)
