.PHONY: help test diff

CLUSTERS := talos-ottawa talos-robbinsdale talos-stpetersburg
FLATE := tools/flate.sh
FLATE_FLAGS := --no-progress --allow-missing-secrets

help: ## Show this help
	@grep -E '^[a-zA-Z0-9_%.-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-25s\033[0m %s\n", $$1, $$2}'

test: ## Render-test all clusters with flate
	@$(MAKE) --no-print-directory -j$(words $(CLUSTERS)) $(addprefix test-,$(CLUSTERS))

test-%: ## Render-test one cluster, e.g. make test-talos-ottawa
	@$(FLATE) test all --path clusters/$*/flux/config $(FLATE_FLAGS)
# Application manifests live in two trees while the migration is completed.
# A standalone location-tree scan is incomplete: shared bootstrap sources live
# under clusters/common, so Flate aliases both the self GitRepository and any
# foreign source (for example csi-addons) to this working tree. In baseline
# mode, scan the complete cluster root instead. Its bootstrap follows common
# and the location app tree, while the root walk also covers legacy apps.
ifneq ($(strip $(FLATE_BASE)),)
	@$(FLATE) test all --path clusters/$* $(FLATE_FLAGS)
endif

diff: ## Show rendered diff vs origin/main for all clusters
	@for c in $(CLUSTERS); do \
		echo "=== $$c ==="; \
		$(FLATE) diff all --path clusters/$$c/flux/config --base origin/main $(FLATE_FLAGS) || exit 1; \
	done

default: help
