#!/bin/bash
set -e

type az gh > /dev/null

template_setup() {
    template_file="setup.sh"
    sed_script="s|{{token}}|${RUNNER_TOKEN}|g"
    sed_script="${sed_script};s|{{repo}}|${GITHUB_REPO}|g"
    sed_script="${sed_script};s|{{label}}|${LABEL}|g"
    sed_script="${sed_script};s|{{vm_username}}|${VM_USERNAME}|g"
    sed "${sed_script}" "${template_file}.template" > "${template_file}"
}

if [[ -z "${GITHUB_REPO}" ]];then
    >&2 echo "env var GITHUB_REPO not defined"
    exit 1
fi

if [[ -z "${GH_TOKEN}" ]];then
    >&2 echo "env var GH_TOKEN not defined"
    exit 1
fi

if [[ -z "${RUN_ID}" ]];then
    >&2 echo "env var RUN_ID not defined"
    exit 1
fi

: "${RESOURCE_GROUP_NAME:=rgghrunner${RUN_ID}}"
: "${LOCATION:=westus2}"
: "${VM_IMAGE:=canonical:ubuntu-24_04-lts:server:latest}"
: "${VM_SPOT:=False}"
: "${VM_SIZE:=Standard_D4ms}"
: "${VM_DISK_SIZE:=127}"
: "${VM_NAME:=ghrunner${RUN_ID}}"
: "${VM_USERNAME:=ghradmin}"
: "${STORAGE_BLOB_URI:=}"
: "${SSH_KEY_BASENAME:=id_rsa}"

if [[ -z "${UNIQ_LABEL}" ]]; then
    UNIQ_LABEL=$(shuf -er -n8  {a..z} | paste -sd "")
fi
LABEL="azure,${UNIQ_LABEL}"

# Get runner token with error handling
if ! RUNNER_TOKEN=$(gh api -XPOST --jq '.token' "repos/${GITHUB_REPO}/actions/runners/registration-token" 2>/dev/null); then
    >&2 echo "Error: Failed to get GitHub runner registration token"
    >&2 echo "Check GH_TOKEN permissions and repository access"
    exit 1
fi

if [[ $1 = '--destroy' ]]; then
    >&2 echo "Starting destroy operation for VM: ${VM_NAME}"

    # Set up destroy script
    template_setup

    # Initialize cleanup success flag
    cleanup_success=false

    # Try to get VM IP, but don't fail if we can't
    >&2 echo "Retrieving VM IP address..."
    if VM_IP=$(az vm show --show-details --resource-group "${RESOURCE_GROUP_NAME}" --name "${VM_NAME}" --query publicIps --output tsv 2>/dev/null); then
        if [[ -n "$VM_IP" && "$VM_IP" != "null" ]]; then
            >&2 echo "VM IP found: ${VM_IP}"

            # Attempt SSH cleanup with proper error handling
            >&2 echo "Attempting to clean up GitHub runner service via SSH..."

            # Add VM to known hosts (ignore errors)
            ssh-keyscan -T 10 "${VM_IP}" >> "${HOME}/.ssh/known_hosts" 2>/dev/null || true

            # Try SSH cleanup with timeouts and error handling
            if timeout 60 ssh \
                -o ConnectTimeout=15 \
                -o ServerAliveInterval=5 \
                -o ServerAliveCountMax=3 \
                -o StrictHostKeyChecking=accept-new \
                -o UserKnownHostsFile="${HOME}/.ssh/known_hosts" \
                -o BatchMode=yes \
                "${VM_USERNAME}@${VM_IP}" 'bash -s -- --destroy' < setup.sh 2>/dev/null; then

                >&2 echo "Successfully cleaned up GitHub runner service"
                cleanup_success=true
            else
                >&2 echo "Warning: SSH cleanup failed or timed out"
                >&2 echo "Possible causes:"
                >&2 echo "  - VM is unreachable (spot eviction, network issues)"
                >&2 echo "  - SSH service not available"
                >&2 echo "  - GitHub runner service already stopped"
                >&2 echo "  - VM is in process of shutting down"
            fi

            # Clean up known hosts entry
            ssh-keygen -R "${VM_IP}" 2>/dev/null || true
        else
            >&2 echo "Warning: VM IP is null or empty"
        fi
    else
        >&2 echo "Warning: Could not retrieve VM information"
        >&2 echo "VM may already be deleted or resource group may not exist"
    fi

    # Check if VM actually exists before trying to delete it
    >&2 echo "Checking if VM exists before deletion..."
    if az vm show --resource-group "${RESOURCE_GROUP_NAME}" --name "${VM_NAME}" --output none 2>/dev/null; then
        >&2 echo "VM exists, proceeding with deletion..."

        # Delete the VM with retry logic
        max_delete_attempts=3
        delete_success=false

        for ((attempt=1; attempt<=max_delete_attempts; attempt++)); do
            >&2 echo "VM deletion attempt ${attempt}/${max_delete_attempts}..."

            if az vm delete --resource-group "${RESOURCE_GROUP_NAME}" --name "${VM_NAME}" --yes --output none 2>/dev/null; then
                >&2 echo "VM deletion successful"
                delete_success=true
                break
            else
                >&2 echo "VM deletion attempt ${attempt} failed"
                if [[ $attempt -lt $max_delete_attempts ]]; then
                    >&2 echo "Waiting 30 seconds before retry..."
                    sleep 30
                fi
            fi
        done

        if [[ "$delete_success" != "true" ]]; then
            >&2 echo "Warning: VM deletion failed after ${max_delete_attempts} attempts"
            >&2 echo "VM may have been deleted externally or there may be a permission issue"
        fi
    else
        >&2 echo "VM does not exist (already deleted or never created)"
    fi

    # Check for other VMs in the resource group
    >&2 echo "Checking for other VMs in resource group..."
    if _vms=$(az vm list --resource-group "${RESOURCE_GROUP_NAME}" --query "[].name" --output tsv 2>/dev/null); then
        if [[ -z "${_vms}" ]]; then
            >&2 echo "No other VMs found in resource group, initiating resource group deletion..."

            # Delete the resource group with error handling
            if az group delete --name "${RESOURCE_GROUP_NAME}" --no-wait --yes --output none 2>/dev/null; then
                >&2 echo "Resource group deletion initiated successfully"
            else
                >&2 echo "Warning: Resource group deletion failed"
                >&2 echo "Manual cleanup may be required:"
                >&2 echo "  az group delete --name ${RESOURCE_GROUP_NAME} --yes"
            fi
        else
            >&2 echo "Other VMs still exist in resource group:"
            >&2 echo "${_vms}" | sed 's/^/  - /'
            >&2 echo "Resource group will be preserved"
        fi
    else
        >&2 echo "Warning: Could not list VMs in resource group (may already be deleted)"
    fi

    # Final status
    if [[ "$cleanup_success" == "true" ]]; then
        >&2 echo "Destroy operation completed successfully"
    else
        >&2 echo "Destroy operation completed with warnings (SSH cleanup failed but VM was deleted)"
    fi

    exit 0
fi

# Force destroy mode (skip SSH cleanup entirely)
if [[ $1 = '--force-destroy' ]]; then
    >&2 echo "Starting force destroy operation (skipping SSH cleanup)..."

    # Skip SSH cleanup, go straight to VM deletion
    >&2 echo "Skipping GitHub runner service cleanup"

    if az vm show --resource-group "${RESOURCE_GROUP_NAME}" --name "${VM_NAME}" --output none 2>/dev/null; then
        >&2 echo "Force deleting VM: ${VM_NAME}"
        az vm delete --resource-group "${RESOURCE_GROUP_NAME}" --name "${VM_NAME}" --yes --output none || {
            >&2 echo "Warning: Force VM deletion failed"
        }
    else
        >&2 echo "VM does not exist"
    fi

    # Check for other VMs and clean up resource group if empty
    _vms=$(az vm list --resource-group "${RESOURCE_GROUP_NAME}" --query "[].name" --output tsv 2>/dev/null || echo "")
    if [[ -z "${_vms}" ]]; then
        >&2 echo "Force deleting resource group: ${RESOURCE_GROUP_NAME}"
        az group delete --name "${RESOURCE_GROUP_NAME}" --no-wait --yes --output none || {
            >&2 echo "Warning: Force resource group deletion failed"
        }
    fi

    >&2 echo "Force destroy operation completed"
    exit 0
fi

# Create the resource group
>&2 echo "Checking/creating resource group: ${RESOURCE_GROUP_NAME}"
_rg_exists=$(az group show --name "${RESOURCE_GROUP_NAME}" --output none &> /dev/null;echo $?)
if [[ $_rg_exists -ne 0 ]];then
    >&2 echo "Creating resource group..."
    az group create --name "${RESOURCE_GROUP_NAME}" --location "${LOCATION}" --output none
else
    >&2 echo "Resource group already exists"
fi

# Set up setup script
template_setup

_vm_exists=$(az vm show --resource-group "${RESOURCE_GROUP_NAME}" --name "${VM_NAME}" --output none &> /dev/null;echo $?)

if [[ $_vm_exists -ne 0 ]];then
    >&2 echo "Creating VM: ${VM_NAME}"
    >&2 echo "  Type: ${VM_SPOT}"
    >&2 echo "  Size: ${VM_SIZE}"
    >&2 echo "  Image: ${VM_IMAGE}"

    if [[ ! -z ${STORAGE_BLOB_URI} ]];then
        case ${VM_SPOT} in
            "True")
                >&2 echo "Creating spot instance VM with boot diagnostics storage..."
                # Create the spot instance vm
                az vm create \
                    --resource-group "${RESOURCE_GROUP_NAME}" \
                    --name "${VM_NAME}" \
                    --image "${VM_IMAGE}" \
                    --admin-username "${VM_USERNAME}" \
                    --security-type "Standard" \
                    --size "${VM_SIZE}" \
                    --priority "Spot" \
                    --max-price "-1" \
                    --eviction-policy "Delete" \
                    --ssh-key-values "${HOME}/.ssh/${SSH_KEY_BASENAME}.pub" \
                    --custom-data setup.sh \
                    --public-ip-sku Standard \
                    --boot-diagnostics-storage ${STORAGE_BLOB_URI} \
                    --os-disk-delete-option Delete \
                    --os-disk-size-gb ${VM_DISK_SIZE} \
                    --output none \
                    --verbose
            ;;
            *)
                >&2 echo "Creating regular VM with boot diagnostics storage..."
                # Create the regular vm
                az vm create \
                    --resource-group "${RESOURCE_GROUP_NAME}" \
                    --name "${VM_NAME}" \
                    --image "${VM_IMAGE}" \
                    --admin-username "${VM_USERNAME}" \
                    --security-type "Standard" \
                    --size "${VM_SIZE}" \
                    --ssh-key-values "${HOME}/.ssh/${SSH_KEY_BASENAME}.pub" \
                    --custom-data setup.sh \
                    --public-ip-sku Standard \
                    --boot-diagnostics-storage ${STORAGE_BLOB_URI} \
                    --os-disk-delete-option Delete \
                    --os-disk-size-gb ${VM_DISK_SIZE} \
                    --output none \
                    --verbose
            ;;
        esac
    else
        case ${VM_SPOT} in
            "True")
                >&2 echo "Creating spot instance VM with managed boot diagnostics..."
                # Create the spot instance vm
                az vm create \
                    --resource-group "${RESOURCE_GROUP_NAME}" \
                    --name "${VM_NAME}" \
                    --image "${VM_IMAGE}" \
                    --admin-username "${VM_USERNAME}" \
                    --security-type "Standard" \
                    --size "${VM_SIZE}" \
                    --priority "Spot" \
                    --max-price "-1" \
                    --eviction-policy "Delete" \
                    --ssh-key-values "${HOME}/.ssh/${SSH_KEY_BASENAME}.pub" \
                    --custom-data setup.sh \
                    --public-ip-sku Standard \
                    --os-disk-delete-option Delete \
                    --os-disk-size-gb ${VM_DISK_SIZE} \
                    --output none \
                    --verbose
                az vm boot-diagnostics enable \
                    --resource-group "${RESOURCE_GROUP_NAME}" \
                    --name "${VM_NAME}" \
                    --output none \
                    --verbose
            ;;
            *)
                >&2 echo "Creating regular VM with managed boot diagnostics..."
                # Create the regular vm
                az vm create \
                    --resource-group "${RESOURCE_GROUP_NAME}" \
                    --name "${VM_NAME}" \
                    --image "${VM_IMAGE}" \
                    --security-type "Standard" \
                    --admin-username "${VM_USERNAME}" \
                    --size "${VM_SIZE}" \
                    --ssh-key-values "${HOME}/.ssh/${SSH_KEY_BASENAME}.pub" \
                    --custom-data setup.sh \
                    --public-ip-sku Standard \
                    --os-disk-delete-option Delete \
                    --os-disk-size-gb ${VM_DISK_SIZE} \
                    --output none \
                    --verbose
                az vm boot-diagnostics enable \
                    --resource-group "${RESOURCE_GROUP_NAME}" \
                    --name "${VM_NAME}" \
                    --output none \
                    --verbose
            ;;
        esac
    fi
    >&2 echo "VM creation completed"
else
    >&2 echo "VM already exists: ${VM_NAME}"
fi

# Get VM IP with error handling
>&2 echo "Retrieving VM IP address..."
if VM_IP=$(az vm show --show-details --resource-group "${RESOURCE_GROUP_NAME}" --name "${VM_NAME}" --query publicIps --output tsv 2>/dev/null); then
    if [[ -n "$VM_IP" && "$VM_IP" != "null" ]]; then
        >&2 echo "VM IP: ${VM_IP}"
    else
        >&2 echo "Warning: VM IP is null or empty"
        VM_IP=""
    fi
else
    >&2 echo "Warning: Could not retrieve VM IP"
    VM_IP=""
fi

# Output results
jq -n \
    --arg ip "${VM_IP}" \
    --arg resource_group "${RESOURCE_GROUP_NAME}" \
    --arg location "${LOCATION}" \
    --arg vm_image "${VM_IMAGE}" \
    --arg vm_size "${VM_SIZE}" \
    --arg vm_name "${VM_NAME}" \
    --arg vm_username "${VM_USERNAME}" \
    --arg vm_disk_size "${VM_DISK_SIZE}" \
    --arg uniq_label "${UNIQ_LABEL}" \
    --arg ssh_key_basename "${SSH_KEY_BASENAME}" \
    '$ARGS.named'
