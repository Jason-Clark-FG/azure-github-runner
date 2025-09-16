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

test -z "${UNIQ_LABEL}" && UNIQ_LABEL=$(shuf -er -n8  {a..z} | paste -sd "")
LABEL="azure,${UNIQ_LABEL}"
RUNNER_TOKEN=$(gh api -XPOST --jq '.token' "repos/${GITHUB_REPO}/actions/runners/registration-token")

if [[ $1 = '--destroy' ]]; then
    # Set up destroy script
    template_setup
    VM_IP=$(az vm show --show-details --resource-group "${RESOURCE_GROUP_NAME}" --name "${VM_NAME}" --query publicIps --output tsv 2>/dev/null)
    ssh-keyscan "${VM_IP}" >> "${HOME}/.ssh/known_hosts" 2> /dev/null
    ssh "${VM_USERNAME}@${VM_IP}" 'bash -s -- --destroy' < setup.sh 2> /dev/null
    ssh-keygen -R "${VM_IP}"
    # Delete the resource group
    az group delete --name "${RESOURCE_GROUP_NAME}" --no-wait --yes --output none
    exit 0
fi

# Create the resource group
_rg_exists=$(az group show --name "${RESOURCE_GROUP_NAME}" --output none &> /dev/null;echo $?)
if [[ $_rg_exists -ne 0 ]];then
    az group create --name "${RESOURCE_GROUP_NAME}" --location "${LOCATION}" --output none
fi

# Set up setup script
template_setup

_vm_exists=$(az vm show --resource-group "${RESOURCE_GROUP_NAME}" --name "${VM_NAME}" --output none &> /dev/null;echo $?)

if [[ $_vm_exists -ne 0 ]];then
    if [[ ! -z ${STORAGE_BLOB_URI} ]];then
        case ${VM_SPOT} in
            "True")
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
fi

VM_IP=$(az vm show --show-details --resource-group "${RESOURCE_GROUP_NAME}" --name "${VM_NAME}" --query publicIps --output tsv)

jq -n \
    --arg ip "$VM_IP" \
    --arg resource_group "$RESOURCE_GROUP_NAME" \
    --arg location "$LOCATION" \
    --arg vm_image "$VM_IMAGE" \
    --arg vm_size "$VM_SIZE" \
    --arg vm_name "$VM_NAME" \
    --arg vm_username "$VM_USERNAME" \
    --arg vm_disk_size "$VM_DISK_SIZE" \
    --arg uniq_label "$UNIQ_LABEL" \
    --arg ssh_key_basename "$SSH_KEY_BASENAME" \
    '$ARGS.named'

