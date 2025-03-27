.PHONY: validate-kustomize install-kustomize install-helm install-deps help

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-25s\033[0m %s\n", $$1, $$2}'

validate-kustomize: install-deps ## Validate all Kustomize builds
	@find clusters/talos-robbinsdale/apps/* -type d -maxdepth 0 | while read dir; do \
		echo "🔍 Validating $$dir..."; \
		if [ -f "$$dir/kustomization.yaml" ]; then \
			if ! KUBERNETES_VERSION=1.29.0 kustomize build --enable-helm "$$dir" > /dev/null; then \
				echo "❌ Failed to validate $$dir"; \
				exit 1; \
			else \
				echo "✅ Successfully validated $$dir"; \
			fi; \
		fi; \
	done

default: help 