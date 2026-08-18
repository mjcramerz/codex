SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

REPO_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
DIST_DIR ?= codex-rs/target/dist
BUILD_ARTIFACT_DIR ?= $(DIST_DIR)/build
STAGE_ARTIFACT_DIR ?= $(DIST_DIR)/stage
DEBIAN_SOURCE_ARTIFACT_DIR ?= $(DIST_DIR)/source
DEBIAN_PACKAGE_ARTIFACT_DIR ?= $(DIST_DIR)/debian
GITLAB_ARTIFACT_DIR ?= $(DIST_DIR)/gitlab

EMPTY :=
SPACE := $(EMPTY) $(EMPTY)
TAB := $(shell printf '\t')

RUST_MANIFEST_PATH ?= codex-rs/Cargo.toml
RUST_PACKAGE ?= codex-cli
RUST_BINARY ?= codex
RUST_PROFILE ?= release
RUST_TARGET ?= x86_64-unknown-linux-gnu
RUST_TARGET_DIR ?= $(if $(strip $(CARGO_TARGET_DIR)),$(CARGO_TARGET_DIR),codex-rs/target)
PACKAGE_CARGO_FLAGS ?= --manifest-path $(RUST_MANIFEST_PATH) --locked --release -p $(RUST_PACKAGE) --bin $(RUST_BINARY)
PACKAGE_BINARY_PATH ?= $(RUST_TARGET_DIR)/$(RUST_PROFILE)/$(RUST_BINARY)

RELEASE_BUILD_SCRIPT ?= $(REPO_ROOT)/scripts/release/build-codex.sh
RELEASE_BUILD_ROOT ?= /pool/build/codex
RELEASE_CACHE_ROOT ?= /pool/cache/codex
RELEASE_TARGET ?= $(RUST_TARGET)
RELEASE_TARGET_CPU ?= skylake
RELEASE_TOOLCHAIN ?= nightly
RELEASE_BAZEL_TARGET ?= //bazel/release:release-binaries
RELEASE_JOBS ?=
RELEASE_BASE_REF ?= mcr/main
VERSION ?=
COMP ?= both
RELEASE_ARCHIVE_NAME ?= codex.tar.gz
RELEASE_LATEST_DIR := $(RELEASE_BUILD_ROOT)/latest
RELEASE_ARCHIVE_PATH := $(RELEASE_LATEST_DIR)/$(RELEASE_ARCHIVE_NAME)
RELEASE_ARCHIVE_CHECKSUM_PATH := $(RELEASE_ARCHIVE_PATH).sha256
RELEASE_CONFIG_SCHEMA_PATH := $(RELEASE_LATEST_DIR)/config.schema.json
BUILD_ARTIFACT_PATH ?= $(BUILD_ARTIFACT_DIR)/$(RUST_BINARY)

RELEASE_BUILD_ARGS := --comp "$(COMP)" \
	--build-root "$(RELEASE_BUILD_ROOT)" \
	--cache-root "$(RELEASE_CACHE_ROOT)" \
	--target "$(RELEASE_TARGET)" \
	--target-cpu "$(RELEASE_TARGET_CPU)"
ifneq ($(filter both cargo,$(strip $(COMP))),)
ifneq ($(strip $(RELEASE_TOOLCHAIN)),)
RELEASE_BUILD_ARGS += --toolchain "$(RELEASE_TOOLCHAIN)"
endif
endif
ifneq ($(filter both bazel,$(strip $(COMP))),)
ifneq ($(strip $(RELEASE_BAZEL_TARGET)),)
RELEASE_BUILD_ARGS += --bazel-target "$(RELEASE_BAZEL_TARGET)"
endif
endif
ifneq ($(strip $(RELEASE_JOBS)),)
RELEASE_BUILD_ARGS += --jobs "$(RELEASE_JOBS)"
endif
ifneq ($(strip $(RELEASE_BASE_REF)),)
RELEASE_BUILD_ARGS += --base-ref "$(RELEASE_BASE_REF)"
endif
ifneq ($(strip $(VERSION)),)
RELEASE_BUILD_ARGS += --version "$(VERSION)"
endif

DEBIAN_SOURCE_FLAGS ?= -S -sa -us -uc
DEBIAN_SBUILD_FLAGS ?= --no-run-lintian
DEBIAN_SOURCE_FLAGS_ARG ?= $(subst $(SPACE),$(TAB),$(strip $(DEBIAN_SOURCE_FLAGS)))
DEBIAN_SBUILD_FLAGS_ARG ?= $(subst $(SPACE),$(TAB),$(strip $(DEBIAN_SBUILD_FLAGS)))
APTLY_CHANNEL ?= stable
TEST_BOOTSTRAP_COMMAND ?= command -v cargo-nextest >/dev/null 2>&1 || cargo install --locked cargo-nextest
RECONCILED_WORKTREE_RUNNER ?= ./scripts/release/run_in_reconciled_worktree.sh

PACKAGE_VERSION := $(shell dpkg-parsechangelog -SVersion 2>/dev/null || printf '0.0.0')
STAGE_BUNDLE_BASENAME ?= $(RUST_BINARY)-$(PACKAGE_VERSION)-$(RUST_TARGET)
STAGE_BUNDLE_PATH ?= $(STAGE_ARTIFACT_DIR)/$(STAGE_BUNDLE_BASENAME).tar.gz
STAGE_CHECKSUM_PATH ?= $(STAGE_BUNDLE_PATH).sha256

.PHONY: verify test build stage publish \
	package-build package-install package-clean publish-gitlab-bundle

verify:
	./scripts/release/verify_packaging.sh

test:
	RELEASE_CACHE_ROOT="$(RELEASE_CACHE_ROOT)" \
		CI_TEST_BOOTSTRAP_COMMAND="$${CI_TEST_BOOTSTRAP_COMMAND:-$(TEST_BOOTSTRAP_COMMAND)}" \
		"$(RECONCILED_WORKTREE_RUNNER)" \
		bash -c 'cd codex-rs && bash -c "$$CI_TEST_BOOTSTRAP_COMMAND" && just test -p $(RUST_PACKAGE)'

build:
	"$(RELEASE_BUILD_SCRIPT)" $(RELEASE_BUILD_ARGS)
	test -x "$(RELEASE_LATEST_DIR)/bin/$(RUST_BINARY)"
	test -f "$(RELEASE_ARCHIVE_PATH)"
	test -f "$(RELEASE_ARCHIVE_CHECKSUM_PATH)"
	test -f "$(RELEASE_CONFIG_SCHEMA_PATH)"
	install -d -m 0755 "$(BUILD_ARTIFACT_DIR)"
	install -m 0755 "$(RELEASE_LATEST_DIR)/bin/$(RUST_BINARY)" "$(BUILD_ARTIFACT_PATH)"

stage:
	test -f "$(RELEASE_ARCHIVE_PATH)" || { \
		printf "missing release archive: %s\nRun the build stage first and restore its artifacts before staging.\n" "$(RELEASE_ARCHIVE_PATH)" >&2; \
		exit 1; \
	}
	install -d -m 0755 "$(STAGE_ARTIFACT_DIR)"
	rm -f -- "$(STAGE_BUNDLE_PATH)" "$(STAGE_CHECKSUM_PATH)"
	install -m 0644 "$(RELEASE_ARCHIVE_PATH)" "$(STAGE_BUNDLE_PATH)"
	sha256sum -- "$(STAGE_BUNDLE_PATH)" > "$(STAGE_CHECKSUM_PATH)"

publish:
	printf "Generic publish flows now live in the shared GitLab delivery pipeline.\n" >&2
	exit 1

publish-gitlab-bundle:
	@$(MAKE) publish

package-build:
	cargo build $(PACKAGE_CARGO_FLAGS)

package-install: package-build
	install -D -m 0755 "$(PACKAGE_BINARY_PATH)" "$(DESTDIR)/usr/bin/$(RUST_BINARY)"

package-clean:
	rm -rf -- "$(BUILD_ARTIFACT_DIR)" "$(STAGE_ARTIFACT_DIR)" "$(GITLAB_ARTIFACT_DIR)" "$(DEBIAN_SOURCE_ARTIFACT_DIR)" "$(DEBIAN_PACKAGE_ARTIFACT_DIR)"
