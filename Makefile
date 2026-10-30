# make run     构建并启动 LinkCursor（先退出正在运行的那个）
# make build   只构建（Rust Core 由 Xcode 的构建阶段一起编译）
# make test    跑单元测试
# make log     实时查看 app 的日志
# make stop    退出正在运行的 LinkCursor
# make clean   删除构建产物
#
# CONFIG=Release make run 构建 Release；TEAM=XXXXXXXXXX 指定签名团队。

PROJECT := LinkCursor.xcodeproj
SCHEME  := LinkCursor
CONFIG  ?= Debug
DERIVED := DerivedData
APP     := $(DERIVED)/Build/Products/$(CONFIG)/LinkCursor.app

# Sign with the keychain's "Apple Development" certificate. The Accessibility
# permission is bound to the signature: an ad-hoc one changes on every build
# and the permission is lost each time, a certificate keeps it.
ifndef TEAM
TEAM := $(shell security find-certificate -c "Apple Development" -p 2>/dev/null \
	| openssl x509 -noout -subject -nameopt multiline 2>/dev/null \
	| awk -F' = ' '/organizationalUnitName/ { print $$2; exit }')
endif
ifneq ($(TEAM),)
SIGNING := CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM=$(TEAM)
endif

XCODEBUILD := xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
	-configuration $(CONFIG) -derivedDataPath $(DERIVED) $(SIGNING) \
	-destination "platform=macOS,arch=$(shell uname -m)"

.PHONY: run build test log stop clean

run: build
	@$(MAKE) --no-print-directory stop
	open "$(APP)"

build:
ifeq ($(TEAM),)
	@echo "warning: 钥匙串里没有 Apple Development 证书，改用临时签名；每次重新构建后都要重新授予辅助功能权限。"
endif
	$(XCODEBUILD) -quiet build

test:
	$(XCODEBUILD) -quiet test

log:
	log stream --style compact --level debug --predicate 'subsystem == "com.linkcursor.mac"'

# Two copies cannot run at once: they share the UDP ports, the settings and
# the paired devices. Ask first; one held by a debugger ignores that.
stop:
	@if pkill -x LinkCursor; then \
		for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -x LinkCursor >/dev/null || exit 0; sleep 0.3; done; \
		pkill -9 -x LinkCursor; \
	fi; true

clean:
	rm -rf $(DERIVED)
