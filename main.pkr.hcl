packer {
  required_plugins {
  digitalocean = {
    version = ">= 1.0.4"
    source  = "github.com/hashicorp/digitalocean"
    }
  }
}

variable "do_token" {
  type      = string
  sensitive = true
}

source "digitalocean" "bullseye" {
  api_token     = var.do_token
  droplet_agent = false
  image         = "debian-11-x64"
  monitoring    = false
  region        = "nyc1"
  size          = "s-1vcpu-512mb-10gb"
  ssh_username  = "root"
  snapshot_name = "marketplace-pi-hole-vpn-{{timestamp}}"
}

build {
  sources = [
    "source.digitalocean.bullseye"
  ]

  # Update the base image
  provisioner "shell" {
    scripts = [
      "scripts/ssh-lock.sh",
      "scripts/system-setup.sh",
      "scripts/ssh-unlock.sh"
    ]
  }

  # Setup system on first boot after provisioning
  provisioner "file" {
    source      = "scripts/ssh-lock.sh"
    destination = "/tmp/"
  }
  provisioner "file" {
    source      = "scripts/system-setup.sh"
    destination = "/tmp/"
  }
  provisioner "file" {
    source      = "scripts/ssh-unlock.sh"
    destination = "/tmp/"
  }
  provisioner "shell" {
    inline = [
      "mkdir -p                 /var/lib//cloud/scripts/per-instance/",
      "mv /tmp/ssh-lock.sh      /var/lib/cloud/scripts/per-instance/01-lock-ssh.sh",
      "chmod 700                /var/lib/cloud/scripts/per-instance/01-lock-ssh.sh",
      "mv /tmp/system-setup.sh  /var/lib/cloud/scripts/per-instance/02-setup-system.sh",
      "chmod 700                /var/lib/cloud/scripts/per-instance/02-setup-system.sh",
      "mv /tmp/ssh-unlock.sh    /var/lib/cloud/scripts/per-instance/09-unlock-ssh.sh",
      "chmod 700                /var/lib/cloud/scripts/per-instance/09-unlock-ssh.sh"
    ]
  }

  # Setup wireguard on first boot after provisioning and install utility
  # script for users
  provisioner "file" {
    source      = "scripts/wg-setup.sh"
    destination = "/tmp/"
  }
  provisioner "shell" {
    inline = [
      "mkdir -p                 /var/lib/cloud/scripts/per-instance/",
      "cp /tmp/wg-setup.sh      /var/lib/cloud/scripts/per-instance/03-setup-wireguard.sh",
      "chmod 700                /var/lib/cloud/scripts/per-instance/03-setup-wireguard.sh",
      "mv /tmp/wg-setup.sh      /root/regen-vpn-keys.sh",
      "chmod 700                /root/regen-vpn-keys.sh"
    ]
  }

  # Setup pihole on first boot after provisioning
  provisioner "file" {
    source      = "scripts/pihole-setup.sh"
    destination = "/tmp/"
  }
  provisioner "shell" {
    inline = [
      "mkdir -p                 /var/lib/cloud/scripts/per-instance/",
      "mv /tmp/pihole-setup.sh  /var/lib/cloud/scripts/per-instance/04-setup-pihole.sh",
      "chmod 700                /var/lib/cloud/scripts/per-instance/04-setup-pihole.sh",
    ]
  }

  # Setup unbound on first boot after provisioning
  provisioner "file" {
    source      = "scripts/unbound-setup.sh"
    destination = "/tmp/"
  }
  provisioner "shell" {
    inline = [
      "mkdir -p                 /var/lib/cloud/scripts/per-instance/",
      "mv /tmp/unbound-setup.sh /var/lib/cloud/scripts/per-instance/05-setup-unbound.sh",
      "chmod 700                /var/lib/cloud/scripts/per-instance/05-setup-unbound.sh",
    ]
  }

  # Cleanup the base image
  provisioner "shell" {
    scripts = [
      "scripts/image-cleanup.sh",
      "scripts/image-check.sh"
    ]
  }
}
