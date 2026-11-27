# 声临 · 抖音版（ShenglinDouyin）
# 抖音评论区录音转 AI 音色；悬浮球 / 设置页 / 玻璃外观沿用声临·陌陌版。

ARCHS = arm64
TARGET := iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = ShenglinDouyin

ShenglinDouyin_FILES = Tweak/Tweak.x \
	Tweak/SLEntry.m \
	Tweak/SLSettingsPanel.m \
	Tweak/SLGlass.m \
	Tweak/SLAlignBox.m \
	Tweak/SLLog.m \
	Tweak/SLLogViewController.m \
	Tweak/SLWatchOnce.m \
	Tweak/SLProfile.m \
	Tweak/SLBallCommand.m \
	Tweak/SLAPIBackup.m \
	Tweak/SLTrimController.m \
	Tweak/SLPCMTool.m \
	Tweak/SLPipeline.m \
	Tweak/SLAMREncoder.m \
	Tweak/SLVoicePack.m \
	Tweak/SLVoicePackController.m \
	Tweak/SLVoiceImportController.m \
	Tweak/SLTTSComposeController.m \
	Tweak/AWECAUtils.m \
	Tweak/AWECATTSManager.m \
	Tweak/AWECATTSController.m \
	Tweak/AWECATTSVoiceListController.m \
	Tweak/AWECAAPISettingsController.m \
	Tweak/AWECAAudioReplacer.m \
	Tweak/AWECARecordEnhance.m \
	Tweak/AWECACommentHeaderButton.m \
	Tweak/AWECADownloadManager.m \
	Tweak/AWECATOSUploader.m

ShenglinDouyin_CFLAGS = -fobjc-arc
ShenglinDouyin_LDFLAGS = -Xlinker -not_for_dyld_shared_cache
ShenglinDouyin_FRAMEWORKS = UIKit Foundation AVFoundation CoreAudio CoreMedia AudioToolbox UniformTypeIdentifiers SafariServices PhotosUI
ShenglinDouyin_LIBRARIES = objc

include $(THEOS_MAKE_PATH)/library.mk

# 产物拷到根目录
after-all::
	$(ECHO_NOTHING)cp -f "$(THEOS_OBJ_DIR)/$(LIBRARY_NAME).dylib" "$(THEOS_PROJECT_DIR)/$(LIBRARY_NAME).dylib"$(ECHO_END)
