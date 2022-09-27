# Pi-hole VPN [Beta]

Pi-hole VPN image with Unbound and Wireguard

In otherwords, an on-demand VPN, that you own and manage, with
it's own recursive DNS server, so you don't have to rely on an
upstream server like OpenDNS, Cloudflare, or Google, with ad
blocking built in.

Cool, cool cool cool...so how do I...

## Use It

**NB:** The image has not yet been posted to the Marketplace. Stay
tuned. In the meantime, you can create your own image if you like.
See the [Create the Pi-hole VPN
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
      Pi-hole, & Unbound are installed.
* When you SSH in, you'll be promted with a pair of QR codes to
  scan (I recommend scanning both):
    - one for a DNS only VPN client configuration
    - one for a Full VPN client configuration
* The README in the Droplet provides info on multiple clients,
  alternative ports, and more


## Contribute Changes

### Create the Pi-hole VPN Image

First, generate an `API_TOKEN` on the [API
page](https://cloud.digitalocean.com/account/api/tokens). Then,
create a vars file:

    echo 'do_token = "API_TOKEN"' > variables.auto.pkrvars.hcl

Finally, validate and build the image:

    packer init .
    packer validate .
    packer build .

### Provision Droplets for Testing

The recommended way to provision droplets for testing is by using
terraform.

Use Cases:
1. You created an image by following the steps in the [Create the
   Pi-hole VPN Image](#create-the-pi-hole-vpn-image) section above
   and you would like to now create a Droplet using that image.
2. You want to create a Droplet using the image that the packer
   build is based off of so you can test the build scripts in a
   clean environment.

#### Terraform Configuration


First, we need to create a vars file:

    cd terraform
    echo 'do_token = "API_TOKEN"' > terraform.auto.tfvars
    echo 'image    = "IMAGE_ID"' >> terraform.auto.tfvars
    echo 'ssh_keys = [SSH_ID]'   >> terraform.auto.tfvars
    
_NB: the square brackets `[]` around `SSH_ID` are required._

Now that we have a template, let's grab the required information:

**API_TOKEN:** use the API_TOKEN that you generated in the [Create
the Pi-hole VPN Image](#create-the-pi-hole-vpn-image) section
above.

**IMAGE_ID:** the `IMAGE_ID` you use here depends on the use case
(listed [above](#provision-droplets-for-testing))

1. For use case 1, the `IMAGE_ID` is a string of numbers output by
   the Packer build process.
2. For use case 2, the `IMAGE_ID` is `debian-11-x64`

Alternatively:

* Find the `IMAGE_ID` in the URL (`imageId=` for Snapshots,
  `distroImage=` for Distributions) of the [Create Droplets
  page](https://cloud.digitalocean.com/droplets/new) after
  selecting the desired image in the "Snapshots" tab.
* Acquire the `IMAGE_ID` from the API:

    - Distributions

            curl -s -X GET \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer API_TOKEN" \
            "https://api.digitalocean.com/v2/images?type=distribution" | \
            jq -r '.images | .[] | [.id, .name] | @tsv'

    - Snapshots

            curl -s -X GET \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer API_TOKEN" \
            "https://api.digitalocean.com/v2/images?private=true" | \
            jq -r '.images | .[] | [.id, .name] | @tsv'

**SSH_ID:** DO's ID for your SSH public key. You can obtain the
`SSH_ID` for any previously added keys (i.e. any public keys
added via the API or via the [Settings -> Security
page](https://cloud.digitalocean.com/account/security)) with the
following query:

        curl -s -X GET \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer API_TOKEN" \
        "https://api.digitalocean.com/v2/account/keys" | \
        jq -r '.ssh_keys | .[] | [.name, .id] | @tsv'

If you haven't yet added a key, you can use the query below to
upload your SSH public key and get its `SSH_ID`:

      curl -X POST \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer API_TOKEN" \
      -d "{\"name\":\"Pi-hole Key\",\"public_key\":\"$(cat ~/.ssh/id_rsa.pub)\"}" \
      "https://api.digitalocean.com/v2/account/keys"



#### Terraform Use

If you don't already have Terraform installed, checkout
Terraform's [installation page
](https://learn.hashicorp.com/tutorials/terraform/install-cli).
The terraform code requires version 1.2.0 or later.

Make sure you've setup your vars file as described in the previous
section. Then:

    terraform init
    terraform validate
    terraform plan
    terraform apply

You may use `terraform show` to see your Droplet's IP address:

    terraform show

Finally, to destroy your Droplet:

    terraform destroy
