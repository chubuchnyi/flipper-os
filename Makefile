.PHONY: help kernel rootfs image ostree-commit profile-test qemu-test rauc-bundle flash lint test clean

SHELL := /bin/bash
FLIPPER_DEV ?= $(HOME)/flipper-one-dev
BOARD ?= rock-4d
OSTREE_REPO ?= $(FLIPPER_DEV)/ostree-work/repo

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

kernel: ## Build kernel with Flipper OS fragments (uses upstream build scripts)
	./build/build-kernel.sh

rootfs: ## Build OSTree-ready rootfs (requires sudo)
	sudo ./build/build-rootfs.sh

image: ## Build full disk image (BOARD=rock-4d, requires sudo)
	sudo ./build/build-image.sh $(BOARD)

ostree-commit: ## Generate OSTree commit from rootfs
	./build/ostree-commit.sh

profile-test: ## Test profile system in QEMU (BOARD=rock-4d, requires sudo)
	sudo ./tests/qemu-profile-test.sh $(BOARD)

qemu-test: ## Boot image in QEMU and verify systemd starts (requires sudo)
	sudo ./tests/qemu-boot-test.sh $(BOARD)

rauc-bundle: ## Create RAUC firmware update bundle
	./rauc/build-bundle.sh

flash: ## Flash image to board via Maskrom (BOARD=rock-4d)
	./build/flash-board.sh $(BOARD)

lint: ## Run linters on all code
	shellcheck build/*.sh build/lib/*.sh 2>/dev/null || true
	shellcheck profiles/cli/* profiles/profiled/flipper-profiled profiles/lib/*.sh 2>/dev/null || true
	shellcheck initramfs/hooks/* initramfs/scripts/local-bottom/* 2>/dev/null || true
	shellcheck tests/*.sh 2>/dev/null || true
	find . -name '*.py' | xargs ruff check 2>/dev/null || true

test: ## Run integration tests
	./tests/run-tests.sh

clean: ## Remove build artifacts
	rm -rf out/ rootfs-*/ *.img *.img.gz
