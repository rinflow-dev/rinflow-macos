# make run     构建并启动 Rinflow（先退出正在运行的那个）
# make build   只构建（Rust Core 由 Xcode 的构建阶段一起编译）
# make test    跑单元测试
# make log     实时查看 app 的日志
# make stop    退出正在运行的 Rinflow
# make clean   删除构建产物
# make candidate  Developer ID 签名的通用版（未公证，其他 Mac 需手动放行）
# make release    签名 + 公证，可以公开分发（需要 notarytool 配置，见 README）
#
# CONFIG=Release make run 构建 Release；TEAM=XXXXXXXXXX 指定签名团队。

PROJECT := Rinflow.xcodeproj
SCHEME  := Rinflow
CONFIG  ?= Debug
DERIVED := DerivedData
APP     := $(DERIVED)/Build/Products/$(CONFIG)/Rinflow.app

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
else
SIGNING := CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
endif

XCODEBUILD := xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
	-configuration $(CONFIG) -derivedDataPath $(DERIVED) $(SIGNING) \
	-destination "platform=macOS,arch=$(shell uname -m)"

NOTARY_PROFILE ?= rinflow-notary

.PHONY: run build test log stop clean candidate release

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
	log stream --style compact --level debug --predicate 'subsystem == "com.rinflow.mac"'

# Two copies cannot run at once: they share the UDP ports, the settings and
# the paired devices. Ask first; one held by a debugger ignores that.
stop:
	@if pkill -x Rinflow; then \
		for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Rinflow >/dev/null || exit 0; sleep 0.3; done; \
		pkill -9 -x Rinflow; \
	fi; true

clean:
	rm -rf $(DERIVED)

candidate:
	scripts/package-release.sh

release:
	NOTARY_PROFILE=$(NOTARY_PROFILE) scripts/package-release.sh
