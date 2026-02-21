.PHONY: help image ostree-commit profile-test rauc-bundle flash lint test clean

SHELL := /bin/bash
FLIPPER_DEV ?= $(HOME)/flipper-one-dev
BOARD ?= rock-4d
OSTREE_REPO ?= $(FLIPPER_DEV)/ostree-work/repo

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

image: ## Build full disk image (BOARD=rock-4d)
	@echo "Building image for $(BOARD)..."
	./build/build-image.sh $(BOARD)

ostree-commit: ## Generate OSTree commit from rootfs
	./build/ostree-commit.sh

profile-test: ## Test a profile in QEMU (PROFILE=wifi-router)
	./tests/qemu-profile-test.sh $(PROFILE)

rauc-bundle: ## Create RAUC firmware update bundle
	./rauc/build-bundle.sh

flash: ## Flash image to board via Maskrom (BOARD=rock-4d)
	./build/flash-board.sh $(BOARD)

lint: ## Run linters on all code
	shellcheck build/*.sh profiles/cli/*.sh initramfs/*.sh 2>/dev/null || true
	find . -name '*.py' | xargs ruff check 2>/dev/null || true

test: ## Run integration tests
	./tests/run-tests.sh

clean: ## Remove build artifacts
	rm -rf out/ rootfs-*/ *.img *.img.gz
