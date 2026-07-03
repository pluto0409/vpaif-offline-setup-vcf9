#!/bin/bash

# ==============================================================================
# VCF 9.1 & Private AI - Air Gap Preparation (Direct Artifactory Method)
# ==============================================================================
# FIXED:
# 1. Corrected VCF CLI binary detection to handle 'vcf-cli-linux_amd64' naming.
# 2. Uses direct Artifactory links (No Broadcom Portal Token required).
# ==============================================================================

set -o pipefail
source ./config/env.config

# --- Configuration ---
# Direct URLs for VCF 9.1.0 (Verified from KB 415112 / User Testing)
VCF_CLI_URL="https://${PRIVATE_REPO_URL}/artifactory/vcf-distro/vcf-cli/linux/amd64/v9.1.0/VCF-Consumption-CLI-Linux_AMD64-9.1.0.0.25296329.tar.gz"
VCF_PLUGIN_BUNDLE_URL="https://${PRIVATE_REPO_URL}/artifactory/vcf-distro/vcf-cli-plugins/v9.1.0/linux/amd64/VCF-Consumption-CLI-PluginBundle-Linux_AMD64-9.1.0.0300.25509668.tar.gz"

DOWNLOAD_DIR="$DOWNLOAD_DIR_BIN"
mkdir -p "$DOWNLOAD_DIR"

echo "=== Starting VCF 9.1 Air-Gap Preparation ==="

# 1. Update System & Install Dependencies
echo "[1/6] Updating package list and installing base dependencies..."
sudo apt update
sudo apt install -y \
    wget curl jq git openssl openssh-server \
    nginx ca-certificates sshpass software-properties-common \
    python3 python3-pip apt-transport-https gnupg lsb-release

# 2. Install Docker Engine
echo "[2/6] Installing Docker Engine..."
if ! command -v docker &> /dev/null; then
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt-get update
    sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    sudo usermod -aG docker $USER
    echo "Docker installed."
else
    echo "Docker already installed."
fi

# Install kubectl
if ! command -v kubectl >/dev/null 2>&1 ; then
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
    mv kubectl $DOWNLOAD_DIR
    rm kubectl
fi

# Helm
if ! command -v helm >/dev/null 2>&1 ; then
    curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
    chmod 700 get_helm.sh
    ./get_helm.sh
    sudo cp /usr/local/bin/helm $DOWNLOAD_DIR
    rm get_helm.sh
fi

# yq (YAML processor)
if ! command -v yq >/dev/null 2>&1 ; then
    sudo wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/bin/yq
    sudo chmod +x /usr/bin/yq
    sudo cp /usr/bin/yq $DOWNLOAD_DIR
fi

# 3. Fetch & Install GOVC CLI (Direct Download)
echo "[4/6] Downloading govc from github..."
# Download to a temporary filename to ensure we handle it correctly
wget -c https://github.com/vmware/govmomi/releases/download/v0.52.0/govc_Linux_x86_64.tar.gz -O "$DOWNLOAD_DIR/govc_Linux_x86_64.tar.gz"

# Extract and move govc CLI
sudo tar -xvf "$DOWNLOAD_DIR/govc_Linux_x86_64.tar.gz" -C "$DOWNLOAD_DIR"
sudo mv "$DOWNLOAD_DIR/govc" /usr/bin/govc

# 4. Fetch & Install VCF CLI (Direct Download)
echo "[4/6] Downloading VCF 9 CLI from Artifactory..."
# Download to a temporary filename to ensure we handle it correctly
wget -c --user="$PRIVATE_REPO_USERNAME" --password="$PRIVATE_REPO_PASSWORD" "$VCF_CLI_URL" -O "$DOWNLOAD_DIR/vcf-cli.tar.gz"

# Extract and move VCF CLI
sudo tar -xvf "$DOWNLOAD_DIR/vcf-cli.tar.gz" -C /usr/bin
sudo mv /usr/bin/vcf-cli-linux_amd64 /usr/bin/vcf

# 5. Fetch & Install Offline Plugins (Direct Download)
echo "[5/6] Downloading VCF Offline Plugin Bundle..."
PLUGIN_BUNDLE="$DOWNLOAD_DIR/plugins.tar.gz"
wget -c --user="$PRIVATE_REPO_USERNAME" --password="$PRIVATE_REPO_PASSWORD" "$VCF_PLUGIN_BUNDLE_URL" -O "$PLUGIN_BUNDLE"

#echo "Extracting Plugin Bundle for Local Install..."
BUNDLE_EXTRACT_DIR="$DOWNLOAD_DIR/vcf_plugins_extracted"
rm -rf "$BUNDLE_EXTRACT_DIR"
mkdir -p "$BUNDLE_EXTRACT_DIR"
tar -xvf "$PLUGIN_BUNDLE" -C "$BUNDLE_EXTRACT_DIR"

echo "Installing Plugins from Local Source..."
# Installs all plugins from the offline bundle
vcf plugin install all --local-source "$BUNDLE_EXTRACT_DIR"

echo "Verifying Plugin Installation..."
vcf plugin list

# 6. Prepare Private AI Artifacts (Helm & Images)
echo "[6/6] Pre-fetching Private AI Helm Charts..."

# NVIDIA GPU Operator
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm repo update
helm pull nvidia/gpu-operator --untar --untardir "$DOWNLOAD_DIR/charts"

# download nginx deb files
TMP_NGINX_DIR="/tmp/nginx_offline_deb"
rm -rf "$TMP_NGINX_DIR" && mkdir -p "$TMP_NGINX_DIR"

# _apt 계정이 접근할 수 있도록 임시 폴더 권한 부여
sudo chown -R _apt:root "$TMP_NGINX_DIR"
cd "$TMP_NGINX_DIR"

sudo apt-get update
sudo apt-get download $(apt-cache depends --recurse --no-recommends --no-suggests \
  --no-conflicts --no-breaks --no-replaces --no-enhances nginx | grep "^\w" | sort -u)

# 원래 목적인 실제 프로젝트 폴더로 파일 이동 및 복귀
cd - > /dev/null
mkdir -p "$NGINX_OFFLINE"
mv "$TMP_NGINX_DIR"/* "$NGINX_OFFLINE/"
rm -rf "$TMP_NGINX_DIR"

echo "
==============================================================================
AIR GAP PREPARATION COMPLETE
==============================================================================
1. VCF CLI installed successfully.
2. VCF Plugins installed from offline bundle.
3. Dependencies (Docker, Helm, Kubectl) ready.

Artifacts location: $DOWNLOAD_DIR
==============================================================================
"
sudo systemctl daemon-reload
