packer {
  required_plugins {
    digitalocean = {
      version = ">= 1.4.1"
      source  = "github.com/digitalocean/digitalocean"
    }
  }
}

variable "do_token" {
  type        = string
  sensitive   = true
  default     = env("DIGITALOCEAN_TOKEN")
  description = "DigitalOcean API token. Set DIGITALOCEAN_TOKEN or pass -var do_token=..."
}

source "digitalocean" "ubuntu" {
  # Placeholder allows `packer validate` without a real token; build still needs a valid token.
  api_token     = coalesce(var.do_token, "0000000000000000000000000000000000000000000000000000000000000000")
  droplet_agent = false
  image         = "ubuntu-26-04-x64"
  monitoring    = false
  region        = "nyc1"
  size          = "s-1vcpu-1gb"
  ssh_username  = "root"
  snapshot_name = "marketplace-pi-hole-vpn-{{timestamp}}"
}

build {
  sources = [
    "source.digitalocean.ubuntu"
  ]

  # Managed adlist URLs + seeder must exist before Pi-hole bake runs.
  provisioner "shell" {
    inline = [
      "mkdir -p /usr/local/share/pihole-vpn /usr/local/sbin /tmp/marketplace-scripts",
    ]
  }

  provisioner "file" {
    source      = "files/pihole/blocklists.txt"
    destination = "/usr/local/share/pihole-vpn/blocklists.txt"
  }

  provisioner "file" {
    source      = "scripts/pihole-adlists.sh"
    destination = "/usr/local/sbin/pihole-adlists.sh"
  }

  provisioner "shell" {
    inline = [
      "chmod 755 /usr/local/sbin/pihole-adlists.sh",
      "chmod 644 /usr/local/share/pihole-vpn/blocklists.txt",
    ]
  }

  # Bake OS hardening, Unbound, WireGuard packages, and Pi-hole into the snapshot
  provisioner "shell" {
    environment_vars = [
      "MARKETPLACE_BUILD=1",
      "DEBIAN_FRONTEND=noninteractive",
    ]
    scripts = [
      "scripts/system-setup.sh",
      "scripts/unbound-setup.sh",
      "scripts/wg-setup.sh",
      "scripts/pihole-setup.sh",
    ]
  }

  # Destination must exist before Packer file/scp upload (DO marketplace guidance).
  provisioner "shell" {
    inline = ["mkdir -p /tmp/marketplace-scripts"]
  }

  # Stage first-boot finalize scripts (lexicographic order under per-instance)
  provisioner "file" {
    source      = "scripts/"
    destination = "/tmp/marketplace-scripts"
  }

  provisioner "shell" {
    inline = [
      "mkdir -p /var/lib/cloud/scripts/per-instance/",
      "install -m 700 /tmp/marketplace-scripts/system-setup.sh  /var/lib/cloud/scripts/per-instance/01-setup-system.sh",
      "install -m 700 /tmp/marketplace-scripts/unbound-setup.sh /var/lib/cloud/scripts/per-instance/02-setup-unbound.sh",
      "install -m 700 /tmp/marketplace-scripts/wg-setup.sh      /var/lib/cloud/scripts/per-instance/03-setup-wireguard.sh",
      "cp /tmp/marketplace-scripts/wg-setup.sh /root/regen-vpn-keys.sh",
      "chmod 700 /root/regen-vpn-keys.sh",
      "install -m 700 /tmp/marketplace-scripts/dns-troubleshoot.sh /root/dns-troubleshoot.sh",
      "mkdir -p /root/wg-mgmt/clients",
      "install -m 644 /tmp/marketplace-scripts/wg-mgmt/lib.sh /root/wg-mgmt/lib.sh",
      "install -m 700 /tmp/marketplace-scripts/wg-mgmt/add-wg-peer.sh /root/wg-mgmt/add-wg-peer.sh",
      "install -m 700 /tmp/marketplace-scripts/wg-mgmt/remove-wg-peer.sh /root/wg-mgmt/remove-wg-peer.sh",
      "install -m 700 /tmp/marketplace-scripts/wg-mgmt/list-wg-peers.sh /root/wg-mgmt/list-wg-peers.sh",
      "chmod 700 /root/wg-mgmt",
      "install -m 755 /tmp/marketplace-scripts/pihole-adlists.sh /usr/local/sbin/pihole-adlists.sh",
      "install -m 700 /tmp/marketplace-scripts/pihole-setup.sh  /var/lib/cloud/scripts/per-instance/04-setup-pihole.sh",
      "install -m 700 /tmp/marketplace-scripts/ssh-unlock.sh    /var/lib/cloud/scripts/per-instance/09-unlock-ssh.sh",
    ]
  }

  provisioner "shell" {
    scripts = [
      "scripts/ssh-lock.sh",
      "scripts/image-cleanup.sh",
      "scripts/image-check.sh",
    ]
  }
}
