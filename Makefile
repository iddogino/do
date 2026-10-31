# Do — developer entry points. See README.md.
SHELL := /bin/bash
DERIVED := build/DerivedData
CONFIG ?= Release
VERSION ?= 0.0.0-dev
BUILD_NUMBER ?= 1

.PHONY: project build app test cli dmg clean open

project: ## Generate Do.xcodeproj from project.yml
	xcodegen generate --spec project.yml

build: project ## Build Do.app (ad-hoc signed unless Config/Local.xcconfig says otherwise)
	xcodebuild -project Do.xcodeproj -scheme Do -configuration $(CONFIG) \
		-destination 'platform=macOS,arch=arm64' -derivedDataPath $(DERIVED) \
		MARKETING_VERSION=$(VERSION) CURRENT_PROJECT_VERSION=$(BUILD_NUMBER) build

app: build ## Print the path of the built app
	@echo "$(DERIVED)/Build/Products/$(CONFIG)/Do.app"

test: ## Unit tests (agent harness, parser, key mapping, safety, shell runner)
	cd Packages/DoKit && swift test --filter DoCoreTests

cli: ## Build mage-cli (parity checks, single-turn runs)
	cd Packages/DoKit && xcodebuild -scheme mage-cli -configuration Release \
		-destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode build
	@echo "Packages/DoKit/.build/xcode/Build/Products/Release/mage-cli"

dmg: build ## Package Do.app into dist/Do-$(VERSION).dmg
	scripts/make-dmg.sh "$(DERIVED)/Build/Products/$(CONFIG)/Do.app" "dist/Do-$(VERSION).dmg"

open: project
	open Do.xcodeproj

clean:
	rm -rf build dist Do.xcodeproj
