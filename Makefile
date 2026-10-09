# Sandbox helpers for the cosmic-container fork.
#
# Every target runs inside the podman containers (see docs/SANDBOX.md), except
# `interactive` which runs on the host so it can open a QEMU window. Override
# the knobs below on the command line, e.g.:
#
#   make smoke SECS=20
#   make vm BOOT_TIMEOUT=420
#   make screenshot OUTDIR=/work/.vm-tmp/shots
#
# `make` with no target lists everything.

COMPOSE      ?= podman-compose
DEV          ?= dev
VM           ?= vm
SECS         ?= 12
BOOT_TIMEOUT ?= 240
OUTDIR       ?=

.DEFAULT_GOAL := help

.PHONY: help images dev-image vm-image up down shell shell-vm \
        smoke functional vm screenshot initramfs interactive clean-vm

help: ## List the available targets
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

# --- container images -------------------------------------------------------
dev-image: ## Build the dev image (Dockerfile.dev)
	podman build -f Dockerfile.dev -t cosmic-comp-dev .

vm-image: ## Build the vm image (Dockerfile.vm: QEMU + guest kernel)
	podman build -f Dockerfile.vm -t cosmic-comp-vm .

images: dev-image vm-image ## Build both images

# --- container lifecycle ---
up: ## Start the dev container
	$(COMPOSE) up -d $(DEV)

down: ## Stop and remove the containers
	$(COMPOSE) down

shell: up ## Open an interactive shell in the dev container
	$(COMPOSE) exec $(DEV) bash

shell-vm: ## Open a shell in the vm tooling container
	$(COMPOSE) run --rm $(VM) bash

## Test targets (run in the containers)
smoke: up ## Headless winit boot smoke test (SECS=12)
	$(COMPOSE) exec -T $(DEV) bash /work/scripts/smoke-winit.sh $(SECS)

functional: up ## Functional zoom-to-subtree test (winit)
	$(COMPOSE) exec -T $(DEV) bash /work/scripts/functional-zoom.sh

vm: ## Real KMS acceptance test in a QEMU guest (BOOT_TIMEOUT=240)
	$(COMPOSE) run --rm -e BOOT_TIMEOUT=$(BOOT_TIMEOUT) $(VM) \
		bash /work/scripts/vm/run-vm.sh

screenshot: ## Capture tiled/zoomed/restored PNGs from the KMS guest
	$(COMPOSE) run --rm -e BOOT_TIMEOUT=$(BOOT_TIMEOUT) \
		$(if $(OUTDIR),-e OUTDIR=$(OUTDIR),) \
		$(VM) bash /work/scripts/vm/screenshot.sh

initramfs: ## Build just the guest initramfs (into .vm-tmp/initramfs.cpio.gz)
	$(COMPOSE) run --rm -e CLIENT=/tmp/cosmic-vm-toplevel $(VM) bash -lc '\
		BUILD=/tmp/vmb; mkdir -p $$BUILD; \
		wayland-scanner client-header /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml $$BUILD/xdg-shell-client-protocol.h && \
		wayland-scanner private-code /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml $${BUILD}/xdg-shell-protocol.c && \
		cc -O2 -I$$BUILD /work/scripts/test-client/toplevel.c $$BUILD/xdg-shell-protocol.c -lwayland-client -o /tmp/cosmic-vm-toplevel && \
		bash /work/scripts/vm/build-initramfs.sh /work/.vm-tmp/initramfs.cpio.gz'

# Host-side target: opens a real QEMU window (see docs/SANDBOX.md).
interactive: ## Interactive host QEMU window (run on the HOST, not in the container)
	scripts/vm/interactive.sh

clean-vm: ## Remove the vm working dir (.vm-tmp)
	rm -rf .vm-tmp
