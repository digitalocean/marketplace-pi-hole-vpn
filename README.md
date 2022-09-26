# Pi-Hole VPN [Beta]

Pi-hole VPN image with Unbound and Wireguard

In otherwords, an on-demand VPN, that you own and manage, with
it's own recursive DNS server, so you don't have to rely on an
upstream server like OpenDNS, Cloudflare, or Google, with ad
blocking built in.

Cool, cool cool cool...so how do I...

## Use It

**NB:** The image has not yet been posted to the Marketplace. Stay
tuned. In the meantime, you can create your own image if you like.
See the [Create the Pi-Hole VPN
Image](#create-the-pi-hole-vpn-image) section below.

If you want to get up and running in as little time as possible:

1. Go [here](https://marketplace.digitalocean.com/) (TODO: Change
   to direct link once image is posted on the Marketplace) &
   create a Droplet
2. SSH in & scan the QR code(s) presented from the [WireGuard
   App](https://www.wireguard.com/install/)
3. Profit

Slightly more info:

* This image was built using a $4 Droplet, and it should
(🤞) work just fine on one
* First boot setup takes a bit of time
    - Why? On first boot, the OS is updated. Then, WireGuard,
      Pi-Hole, & Unbound are installed.
* When you SSH in, you'll be promted with a pair of QR codes to
  scan (I recommend scanning both):
    - one for a DNS only VPN client configuration
    - one for a Full VPN client configuration
* The README in the Droplet provides info on multiple clients,
  alternative ports, and more


## Contribute Changes

### Create the Pi-Hole VPN Image

First, generate an `API_TOKEN` on the [API
page](https://cloud.digitalocean.com/account/api/tokens). Then,
create a vars file:

    echo 'do_token = <API_TOKEN>' > variables.pkr.hcl

Finnaly, validate and build the image:

    packer init -upgrade main.pkr.hcl
    packer validate -var-file=variables.pkr.hcl main.pkr.hcl
    packer build -var-file=variables.pkr.hcl main.pkr.hcl

### Provision Droplets for Testing

The recommended way to provision droplets for testing is by using
terraform.

#### Terraform Configuration

First, we need to create a vars file:

    cd terraform
    echo 'do_token = "API_TOKEN"' > delete.terraform.tfvars
    echo 'image    = "IMAGE_ID"' >> delete.terraform.tfvars
    echo 'ssh_keys = [SSH_ID]'   >> delete.terraform.tfvars

Now that we have a template, let's grab the required information:

**API_TOKEN:** If you haven't already, generate a new token on the
  [API page](https://cloud.digitalocean.com/account/api/tokens).

**IMAGE_ID:**  Found in the URL (`imageId=` for Snapshots,
  `distroImage=` for Distrutions) of the [Create
  Droplets page](https://cloud.digitalocean.com/droplets/new)
  after selecting the desired image. The `IMAGE_ID` for the distro
  Pi-Hole VPN is based on is `debian-11-x64`. Alternatively, using
  your `API_TOKEN` you can get the `IMAGE_ID` via the API:

* Distributions

        curl -s -X GET \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer API_TOKEN" \
        "https://api.digitalocean.com/v2/images?type=distribution" | \
        jq -r '.images | .[] | [.id, .name] | @tsv'

* Snapshots

        curl -s -X GET \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer API_TOKEN" \
        "https://api.digitalocean.com/v2/images?private=true" | \
        jq -r '.images | .[] | [.id, .name] | @tsv'

**SSH_ID:** Add your SSH public key on the [Settings -> Security
page](https://cloud.digitalocean.com/account/security) or
alternatively, using your `API_TOKEN` upload your public key via
the API:

      curl -X POST \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer API_TOKEN" \
      -d "{\"name\":\"Pi-Hole Key\",\"public_key\":\"$(cat test_rsa.pub)\"}" \
      "https://api.digitalocean.com/v2/account/keys"

If you uploaded your public key via the API, your `SSH_ID` will be in the respone.
Otherwise, using your `API_TOKEN` grab the `SSH_ID` via the API:

        curl -s -X GET \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer API_TOKEN" \
        "https://api.digitalocean.com/v2/account/keys" | \
        jq -r '.ssh_keys | .[] | [.name, .id] | @tsv'

#### Terraform Use

If you don't already have Terraform installed, checkout
Terraform's [installation page
](https://learn.hashicorp.com/tutorials/terraform/install-cli).

Make sure you've setup your vars file as described in the previous
section. Then:

    terraform init
    terraform plan
    terraform apply
