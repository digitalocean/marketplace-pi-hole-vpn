terraform {
  required_providers {
    digitalocean = {
      source = "digitalocean/digitalocean"
      version = "~> 2.0"
    }
  }
}

# Set the variable values in terraform.tfvars
# or using -var="..." CLI option
variable "do_token" {}
variable "image" {}
variable "ssh_keys" { type = list(number) }

# Configure the DigitalOcean Provider
provider "digitalocean" {
  token = var.do_token
}

resource "digitalocean_droplet" "pihole" {
  image      = var.image
  ipv6       = true
  monitoring = false
  name       = "pihole"
  region     = "nyc1"
  size       = "s-1vcpu-512mb-10gb"
  ssh_keys   = var.ssh_keys
}
