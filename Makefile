.PHONY: help macos-info ubuntu-iso ubuntu-bootstrap tailscale-install k3s-install argocd-install argocd-repo-credential observability-secret gitops-bootstrap tailscale-operator-secret pgadmin-secret cloudflared-install observability-install observability-uninstall check registry-test gitops-validator-test gitops-check

help:
	@echo "Common commands:"
	@echo "  make macos-info           Install UTM on macOS using Homebrew"
	@echo "  make ubuntu-iso           Download and verify Ubuntu Server ARM64 ISO"
	@echo "  make ubuntu-bootstrap     Bootstrap packages inside Ubuntu VM"
	@echo "  make tailscale-install    Install Tailscale in Ubuntu and enable Tailscale SSH"
	@echo "  make k3s-install          Install single-node K3s inside Ubuntu VM"
	@echo "  make argocd-install       Install Argo CD into K3s"
	@echo "  make argocd-repo-credential Configure private GitHub repository access"
	@echo "  make observability-secret Create Grafana credentials; requires GRAFANA_ADMIN_PASSWORD"
	@echo "  make gitops-bootstrap     Register the root Argo CD Application"
	@echo "  make tailscale-operator-secret Create the Tailscale Operator OAuth Secret"
	@echo "  make pgadmin-secret       Create the pgAdmin web login Secret"
	@echo "  make cloudflared-install  Install Cloudflare Tunnel; requires TUNNEL_TOKEN"
	@echo "  make observability-install Manual observability install when Argo CD is unavailable"
	@echo "  make observability-uninstall Remove observability releases; keeps PVCs"
	@echo "  make check                Run shell syntax checks"
	@echo "  make registry-test        Test generic application registry failure modes"
	@echo "  make gitops-check         Validate platform and registered applications"

macos-info:
	./scripts/macos/01-install-host-tools.sh

ubuntu-iso:
	./scripts/macos/02-download-ubuntu-iso.sh

ubuntu-bootstrap:
	./scripts/ubuntu/11-bootstrap.sh

tailscale-install:
	./scripts/ubuntu/12-install-tailscale.sh

k3s-install:
	./scripts/k3s/20-install-k3s.sh

argocd-install:
	./scripts/k8s/30-install-argocd.sh

argocd-repo-credential:
	./scripts/k8s/45-configure-argocd-github-app.sh

observability-secret:
	./scripts/k8s/32-configure-observability-secret.sh

gitops-bootstrap:
	./scripts/k8s/33-bootstrap-gitops.sh

tailscale-operator-secret:
	./scripts/k8s/34-configure-tailscale-operator-secret.sh

pgadmin-secret:
	./scripts/k8s/39-configure-pgadmin-secret.sh

cloudflared-install:
	./scripts/k8s/40-install-cloudflared.sh

observability-install:
	./scripts/k8s/31-install-observability.sh

observability-uninstall:
	./scripts/k8s/90-uninstall-observability.sh

check:
	bash -n scripts/*.sh scripts/macos/*.sh scripts/ubuntu/*.sh scripts/k3s/*.sh scripts/k8s/*.sh

registry-test:
	python3 scripts/k8s/test_application_registry.py

gitops-validator-test: registry-test

gitops-check:
	python3 scripts/k8s/validate_application_registry.py \
		--base-ref "$${BASE_REF:-}"
	python3 scripts/k8s/verify_registered_images.py
	./scripts/k8s/42-validate-headlamp.sh
