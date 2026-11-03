# Bannerless — public domain. Build from source, no accounts, no keys.
CLT_DEV := /Library/Developer/CommandLineTools/Library/Developer
TEST_FLAGS := -Xswiftc -F$(CLT_DEV)/Frameworks -Xlinker -F$(CLT_DEV)/Frameworks \
              -Xlinker -rpath -Xlinker $(CLT_DEV)/Frameworks -Xlinker -rpath -Xlinker $(CLT_DEV)/usr/lib

.PHONY: build test app install run clean

build:
	swift build -c release

test:
	@if [ -d "$(CLT_DEV)/Frameworks/Testing.framework" ] && ! xcode-select -p | grep -q Xcode.app; then \
		swift test $(TEST_FLAGS); else swift test; fi

app:
	./scripts/build-app.sh

install: app
	./scripts/install.sh dist/Bannerless.app

run: app
	open dist/Bannerless.app

clean:
	rm -rf .build dist
