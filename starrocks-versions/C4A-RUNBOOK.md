# Google Cloud C4A (Axion ARM64) Benchmarking Runbook

This runbook documents the exact procedures for provisioning a Google Cloud C4A instance (Google Axion / Arm Neoverse-V2), configuring dependencies, building custom StarRocks release candidates, and executing the ClickHouse ClickBench benchmark suite.

---

## 1. Architecture & Machine Specifications

* **Instance Type**: `c4a-standard-16` (16 vCPU, 64 GB RAM)
* **Processor Architecture**: ARM64 (Armv9.0-A, Arm Neoverse-V2 cores, 4x128-bit vector pipelines)
* **Hardware Capabilities**:
  * Large System Extensions (LSE atomics: `ldadd`, `cas`, `swp`)
  * Advanced SIMD (NEON), Cryptographic Extensions (PMULL, AES, SHA3), SVE2
* **Storage**: 100 GB - 200 GB Hyperdisk Balanced (provisioned for high IOPS & throughput)
* **Operating System**: Ubuntu 24.04 LTS ARM64 (`ubuntu-os-cloud/ubuntu-2404-lts-arm64`)

---

## 2. Instance Provisioning Command

```bash
gcloud compute instances create starrocks-arm64-clickbench \
    --project=oranged-experimentation \
    --zone=ZONE_NAME \
    --machine-type=c4a-standard-16 \
    --image-family=ubuntu-2404-lts-arm64 \
    --image-project=ubuntu-os-cloud \
    --boot-disk-size=200GB \
    --boot-disk-type=hyperdisk-balanced \
    --metadata=enable-oslogin=TRUE \
    --scopes=cloud-platform
```

---

## 3. Host System Setup & Dependencies

Once SSH connection is established (`gcloud compute ssh starrocks-arm64-clickbench --project=oranged-experimentation --zone=ZONE_NAME`):

```bash
# Update repositories and install runtime essentials
sudo apt-get update
sudo apt-get install -y \
    build-essential \
    cmake \
    git \
    curl \
    wget \
    jq \
    python3 \
    python3-pip \
    python3-pytest \
    openjdk-17-jdk \
    mysql-client \
    psmisc \
    zstd \
    pigz

# Install Docker engine for containerized builds
sudo apt-get install -y docker.io
sudo usermod -aG docker $USER
newgrp docker

# Verify CPU features on Axion VM
lscpu
grep -m1 'Features' /proc/cpuinfo
# Confirm 'lse', 'asimd', 'pmull', 'crc32', 'sve2' are present
```

---

## 4. Repository & ClickBench Setup

```bash
# Clone repositories
git clone https://github.com/jimmystewpot/starrocks.git ~/starrocks
git clone https://github.com/jimmystewpot/ClickBench.git ~/ClickBench

# Navigate to ClickBench starrocks-versions
cd ~/ClickBench/starrocks-versions

# Download ClickBench datasets
# For 100M rows (standard ClickBench):
cd ~/ClickBench/starrocks
bash load # or prepare hits.tsv.gz / hits.parquet
```

---

## 5. Artifact Packaging Workflow

Use `package-artifact.sh` to package each test candidate directly on the VM:

```bash
cd ~/ClickBench/starrocks-versions

# Candidate 1: 4.1.7 Official Release
# (Automatically downloaded by run-version.sh from official CDN)

# Candidate 2: Upstream main baseline (standard flags)
./package-artifact.sh \
    -v main-baseline \
    -b main \
    --use-docker

# Candidate 3: Consolidated custom candidate (all PRs + Bitshuffle patches, baseline flags)
./package-artifact.sh \
    -v main-custom-default \
    -b perf/arm64-aggregate-rc \
    --use-docker

# Candidate 4: Consolidated custom candidate + LSE atomics
./package-artifact.sh \
    -v main-custom-lse \
    -b perf/arm64-aggregate-rc \
    -c "-march=armv8-a+crc+lse" \
    --use-docker
```

---

## 6. Matrix Execution & Comparison

```bash
cd ~/ClickBench/starrocks-versions

# Run official 4.1.7
./run-version.sh --suite all 4.1.7

# Run upstream main baseline
./run-version.sh --suite all main-baseline

# Run consolidated candidate (default flags)
./run-version.sh --suite all main-custom-default

# Run consolidated candidate (+LSE flags)
./run-version.sh --suite all main-custom-lse

# Generate comparisons
python3 compare.py --markdown \
    results/main-baseline.json \
    results/main-custom-default.json

python3 compare.py --markdown \
    results/main-custom-default.json \
    results/main-custom-lse.json

python3 compare.py --markdown \
    results/4.1.7.json \
    results/main-custom-lse.json
```
