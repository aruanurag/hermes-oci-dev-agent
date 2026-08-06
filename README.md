# hermes-oci-dev-agent

Private, always-on [Nous Hermes Agent](https://github.com/NousResearch/hermes-agent)
on OCI Compute, configured as a single-user developer agent. It uses OCI Generative
AI through the Compute instance principal, so no reusable model API key is stored on
the VM.

Hermes is installed using its supported installer:

```sh
curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
```

The Hermes Dashboard is only reachable through an OCI Bastion SSH tunnel, while model
calls use the Compute instance principal through a localhost OCI Generative AI signing proxy.

## What Hermes can do

The initial deployment is deliberately scoped for developer work:

- Work inside its dedicated `/home/hermes/workspace` directory.
- Read and edit code, create artifacts, and run terminal commands and tests.
- Handle ticket-style requests such as “investigate DEV-123”, “add tests”, or
  “prepare a PR summary”.
- Persist its workspace and sessions across service or VM restarts.

Messaging integrations—including WhatsApp—and external MCP servers remain disabled by
default. Enable them only after establishing repository permissions and an approval
policy for pushes, pull requests, deployments, and destructive commands.

![Private Hermes developer-agent architecture](docs/hermes-oci-architecture.svg)

The editable source is [docs/hermes-oci-architecture.excalidraw](docs/hermes-oci-architecture.excalidraw).

## Prerequisites

- Terraform >= 1.7 and authenticated OCI CLI credentials on your Mac.
- An OCI region where Generative AI is available for your tenancy. Before deploying,
  create a Generative AI project in that same region and confirm it offers an
  on-demand model compatible with this deployment. Chicago (`us-chicago-1`) is the
  documented example; this will not work in every OCI region.
- An OCI compartment, region, availability domain, Oracle Linux image OCID, SSH public
  key, and OCI Generative AI project OCID.

## Select the OCI profile explicitly

Do not rely on whichever profile your shell happens to select. This project uses an
explicit `OCI_PROFILE` value: Make passes it to Terraform's OCI provider and every
OCI CLI call used to create or close the Bastion session. It defaults to `DEFAULT`
only when you do not specify it.

List the profiles configured on your Mac, then choose one deliberately:

```sh
awk -F'[][]' '/^\[.*\]$/{print $2}' "$HOME/.oci/config"

export OCI_PROFILE='HERMES'
make plan OCI_PROFILE="$OCI_PROFILE"
make up OCI_PROFILE="$OCI_PROFILE" SSH_PRIVATE_KEY="$HOME/.ssh/hermes_oci"
```

Use `OCI_PROFILE=DEFAULT` only when `[DEFAULT]` is the intended tenancy and user.
`OCI_CLI_PROFILE` alone is not enough: it affects OCI CLI commands but does not
guarantee Terraform selects the same provider identity.

### Optional provider override file

If you prefer to configure Terraform's profile in HCL, create the local Terraform
override file below and replace `HERMES` with the chosen profile name. Its
`_override.tf` filename deliberately merges these provider settings with the tracked
provider definitions:

```sh
cp terraform/profile_override.tf.example terraform/profile_override.tf
# Edit terraform/profile_override.tf.
```

The override configures both the deployment-region provider and the home-region IAM
provider. It is ignored by Git. Still pass the same profile to Make so the Terraform
provider and OCI CLI Bastion commands cannot use different identities:

```sh
make up OCI_PROFILE=HERMES SSH_PRIVATE_KEY="$HOME/.ssh/hermes_oci"
```

## Choose Compute image, GenAI project, and model

Choose these values before filling `terraform.tfvars`; they are regional and cannot
be safely guessed from another OCI region.

### Compute image

This deployment uses `VM.Standard.E5.Flex`. List current compatible Oracle Linux 9
platform images in your target region, then copy the newest `id` into
`compute_image_ocid`:

```sh
export OCI_REGION='us-chicago-1'
export TENANCY_OCID='ocid1.tenancy.oc1..REPLACE'

oci compute image list \
  --profile "$OCI_PROFILE" \
  --region "$OCI_REGION" \
  --compartment-id "$TENANCY_OCID" \
  --operating-system 'Oracle Linux' \
  --operating-system-version '9' \
  --shape 'VM.Standard.E5.Flex' \
  --all \
  --sort-by TIMECREATED \
  --sort-order DESC \
  --query 'data[?"lifecycle-state"==`AVAILABLE`].{name:"display-name",id:id,created:"time-created"}' \
  --output table
```

OCI refreshes platform-image listings regularly, so do not copy an image OCID from a
blog post or another region. See OCI's [image-list command reference](https://docs.oracle.com/en-us/iaas/tools/oci-cli/latest/oci_cli_docs/cmdref/compute/image/list.html).

### OCI Generative AI project

Create the project in the same region as the Compute instance and copy its OCID into
`genai_project_ocid`. OCI requires a project for its OpenAI-compatible API, and the
project is the boundary for conversations and response data. Use the OCI Console:
**Generative AI → Projects → Create project**, then copy the project OCID from its
details page. See [OCI project creation](https://docs.oracle.com/en-us/iaas/Content/generative-ai/create-project.htm).

For this deployment, a Chicago (`us-chicago-1`) project is the right choice when the
instance also runs in Chicago.

### Model selection

Start with the tested on-demand model alias below. It passed OCI Chat Completions
streaming and function/tool-calling validation in Chicago:

```hcl
genai_model_id = "openai.gpt-oss-120b"
```

Do not choose a model only because it appears in the Console. Hermes needs a model
that is enabled in the selected region and works with OCI's OpenAI-compatible Chat
Completions streaming and tool-calling flow. Some Gemini models and configurations
may be available in OCI but not work with this Hermes request path. Validate a
different model before adopting it, and consult OCI's [model and region availability
table](https://docs.oracle.com/en-us/iaas/Content/generative-ai/model-endpoint-regions.htm).

## Prepare local values and SSH

Choose an existing SSH key or create a dedicated ED25519 key. Keep the private key
on your Mac; Terraform needs only the contents of the `.pub` file.

```sh
ssh-keygen -t ed25519 -f "$HOME/.ssh/hermes_oci" -C "hermes-oci"
cat "$HOME/.ssh/hermes_oci.pub"
```

Create the local variable file, paste that public-key line into `ssh_public_key`, and
fill every remaining `REQUIRED` value. This file is ignored by Git and must never be
committed.

```sh
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Edit terraform/terraform.tfvars.
```

## Option 1: Makefile workflow

This is the normal, one-command path. From the repository root:

```sh
make up OCI_PROFILE="$OCI_PROFILE" SSH_PRIVATE_KEY="$HOME/.ssh/hermes_oci"
```

It provisions the Terraform-managed OCI stack, creates a time-limited Bastion
session, opens both SSH hops, waits for a real Dashboard HTTP 200 response, and then
prints the local URL. Press Ctrl-C to close the tunnels and revoke the Bastion session.

Use the individual targets when the stack already exists or you want to review the
infrastructure first:

```sh
make plan OCI_PROFILE="$OCI_PROFILE"
make provision OCI_PROFILE="$OCI_PROFILE"
make dashboard OCI_PROFILE="$OCI_PROFILE" SSH_PRIVATE_KEY="$HOME/.ssh/hermes_oci"
make destroy OCI_PROFILE="$OCI_PROFILE"
```

The default key is `~/.ssh/id_rsa`; override `SSH_PRIVATE_KEY` whenever the key in
`terraform.tfvars` has a different name. If port `9119` is in use, choose another
local port and browse to it instead:

```sh
make dashboard OCI_PROFILE="$OCI_PROFILE" SSH_PRIVATE_KEY="$HOME/.ssh/hermes_oci" LOCAL_DASHBOARD_PORT=9919
```

## Option 2: Manual Terraform and SSH workflow

Use this path when you want to see or troubleshoot every step. It creates exactly the
same private deployment and Dashboard tunnel as the Makefile.

### 1. Provision the infrastructure

```sh
export TF_VAR_oci_config_file_profile="$OCI_PROFILE"
terraform -chdir=terraform init -input=false
terraform -chdir=terraform plan
terraform -chdir=terraform apply
```

Cloud-init creates the dedicated non-root `hermes` user, installs Hermes, configures
the OCI instance-principal signing proxy, and starts the services. First boot can take
several minutes.

### 2. Create a Bastion session

```sh
export SSH_PRIVATE_KEY="$HOME/.ssh/hermes_oci"
export SSH_PUBLIC_KEY="${SSH_PRIVATE_KEY}.pub"
export OCI_REGION="$(terraform -chdir=terraform output -raw region)"
export BASTION_ID="$(terraform -chdir=terraform output -raw bastion_id)"
export INSTANCE_ID="$(terraform -chdir=terraform output -raw instance_id)"
export PRIVATE_IP="$(terraform -chdir=terraform output -raw private_ip)"

export SESSION_ID="$(
  oci --profile "$OCI_PROFILE" bastion session create-port-forwarding \
    --region "$OCI_REGION" \
    --bastion-id "$BASTION_ID" \
    --target-resource-id "$INSTANCE_ID" \
    --target-private-ip "$PRIVATE_IP" \
    --target-port 22 \
    --key-type PUB \
    --ssh-public-key-file "$SSH_PUBLIC_KEY" \
    --session-ttl 10800 \
    --wait-for-state SUCCEEDED \
    --query 'data.resources[0].identifier' \
    --raw-output
)"
```

`SESSION_ID` must start with `ocid1.bastionsession`. Do not use the work-request OCID
as an SSH username.

### 3. Open the two SSH tunnels

In **Terminal 1**, forward a local maintenance port to private SSH through Bastion:

```sh
ssh -i "$SSH_PRIVATE_KEY" -o IdentitiesOnly=yes \
  -o PubkeyAcceptedAlgorithms=+ssh-rsa \
  -o ExitOnForwardFailure=yes -N \
  -L 2222:"$PRIVATE_IP":22 \
  -p 22 \
  "$SESSION_ID@host.bastion.$OCI_REGION.oci.oraclecloud.com"
```

In **Terminal 2**, forward the loopback-only Hermes Dashboard through that SSH hop:

```sh
ssh -i "$SSH_PRIVATE_KEY" -o IdentitiesOnly=yes -o ExitOnForwardFailure=yes -N \
  -L 9119:127.0.0.1:9119 \
  -p 2222 opc@127.0.0.1
```

Open <http://localhost:9119>. If the VM has just started, wait for cloud-init to
finish; `channel open failed: connect failed` is transient until the Dashboard service
is listening.

For maintenance while the first tunnel is open:

```sh
ssh -i "$SSH_PRIVATE_KEY" -o IdentitiesOnly=yes -p 2222 opc@127.0.0.1 \
  'sudo journalctl -u cloud-final -f'
```

When finished, close both SSH terminals and revoke the session:

```sh
oci --profile "$OCI_PROFILE" bastion session delete --region "$OCI_REGION" --session-id "$SESSION_ID" \
  --force --wait-for-state SUCCEEDED
```

The Makefile enables the legacy `ssh-rsa` signature algorithm only for the OCI
Bastion hop because some Bastion endpoints still require it for RSA session keys.
Using the ED25519 key above avoids that compatibility setting.

Use the Dashboard's **Chat** view for a live developer-agent conversation. The
**Sessions** view is for reviewing saved sessions and their workspace activity.

The Dashboard listens only on VM loopback and has no public IP or internet ingress.
It is reachable only through the time-limited Bastion-and-SSH tunnel; when the tunnel
ends, browser access ends while the Hermes gateway remains running.

## Model configuration

The included OCI GenAI signing proxy signs requests with OCI's instance-principal credentials and
forwards them to the region's OpenAI-compatible Generative AI API. Hermes sees the
proxy as an OpenAI-compatible `custom` provider at `http://127.0.0.1:8181/v1` and has
no OCI API key. The proxy supplies the OCI Generative AI project and compartment context
required by the endpoint.

Choose a tool-calling model that is enabled in the configured OCI region and set its
exact ID in `genai_model_id`. The current tested default is `openai.gpt-oss-120b`.
The included verification script validates the selected model with a streaming tool-call
request before Hermes is considered ready.

## Alternative: direct OpenAI or Anthropic API

The Terraform deployment currently implements the OCI GenAI path above. It does not
accept an OpenAI or Anthropic API key today. A direct-provider variant would preserve
the private Compute instance and Dashboard tunnel, but change the model path to:

```text
Hermes → private-subnet NAT Gateway → OpenAI or Anthropic API
```

The local OCI signing proxy would no longer be used. Configure Hermes with its native
provider name and an exact model ID available to your account; do not keep the OCI
`custom` provider, `base_url`, or `api_key: "not-used"` settings.

```yaml
# Direct OpenAI
model:
  provider: openai
  default: "YOUR_OPENAI_MODEL_ID"
```

```yaml
# Direct Anthropic
model:
  provider: anthropic
  default: "YOUR_ANTHROPIC_MODEL_ID"
```

Hermes reads native provider credentials from its environment rather than from the
normal configuration file:

```text
OPENAI_API_KEY=...       # OpenAI
ANTHROPIC_API_KEY=...    # Anthropic
```

See the upstream [Hermes configuration guide](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/user-guide/configuration.md)
for the current provider and credential behavior.

### Keep direct-provider keys out of Terraform

Never place either API key in `terraform.tfvars`, Terraform variables, cloud-init,
Git, or `/home/hermes/.hermes/config.yaml`: Terraform state and instance metadata can
otherwise retain it. Store the key in OCI Vault instead, pass only the secret OCID to
Terraform, and let the VM retrieve it at startup using its instance principal. The
retrieved value should be written to a root-owned `0600` systemd `EnvironmentFile`
that is supplied to `hermes-gateway`.

Grant the deployment's exact Compute dynamic group permission to read the required
secret bundle only. Keep the existing OCI GenAI dynamic-group policy only when OCI
GenAI remains in use. Direct OpenAI or Anthropic calls leave through the existing NAT
Gateway; no public IP or inbound Dashboard rule is needed.

This is a security tradeoff: the current OCI path uses short-lived instance credentials
and stores no reusable model key on the VM. A direct provider needs a reusable API key,
even when it is injected securely from Vault.

## Suggested developer-agent workflow

1. Give Hermes a bounded task, including the repository path and acceptance criteria.
2. Have it inspect the code and propose its approach before editing.
3. Let it implement and run the relevant tests in its dedicated workspace.
4. Review the diff and test output in the Dashboard.
5. Add GitHub or a ticket integration later, with an explicit human approval step before
   any external write such as a push, pull request, or deployment.

## Operations

```sh
sudo systemctl status hermes-genai-proxy hermes-gateway hermes-dashboard
sudo journalctl -u hermes-gateway -f
sudo systemctl restart hermes-gateway hermes-dashboard
```

If the Dashboard displays an HTTP error, inspect the model proxy and Dashboard together:

```sh
sudo journalctl -u hermes-dashboard -u hermes-genai-proxy -n 100 --no-pager
```

An OCI HTTP `429` normally means the selected on-demand model is temporarily at
capacity; switch to another enabled model or retry later. An HTTP `400` generally
indicates an unsupported model or request shape and should include a useful OCI error
in the proxy log.

Use `terraform destroy` only when you intentionally want to remove the Compute,
networking, and persistent block volume.
