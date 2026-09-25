MARKETPLACE_PARTNERS_RAW ?= https://raw.githubusercontent.com/digitalocean/marketplace-partners/master/scripts

.PHONY: update-scripts validate

# Re-sync DigitalOcean Marketplace cleanup and image validation scripts.
update-scripts:
	curl -fsSL "$(MARKETPLACE_PARTNERS_RAW)/90-cleanup.sh" -o scripts/image-cleanup.sh
	curl -fsSL "$(MARKETPLACE_PARTNERS_RAW)/99-img-check.sh" -o scripts/image-check.sh
	@echo "Updated scripts/image-cleanup.sh and scripts/image-check.sh from marketplace-partners"

validate:
	packer init .
	packer validate -var "do_token=ci-validate-placeholder" .
