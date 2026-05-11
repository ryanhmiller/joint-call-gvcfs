#!/usr/bin/env bash
# Pre-fetch Singularity/Apptainer images for the merge-gvcfs pipeline.
# Run this ONCE from a node with internet (e.g. a login node) before
# launching the pipeline in offline mode (NXF_OFFLINE=true).
#
# Usage:
#   export NXF_SINGULARITY_CACHEDIR=/path/to/cache   # same dir Nextflow will read
#   bash bin/fetch_images.sh

set -euo pipefail

: "${NXF_SINGULARITY_CACHEDIR:?Set NXF_SINGULARITY_CACHEDIR before running}"
mkdir -p "${NXF_SINGULARITY_CACHEDIR}"
cd "${NXF_SINGULARITY_CACHEDIR}"

# Pick the puller available on this host.
if command -v apptainer >/dev/null 2>&1; then
    PULL=(apptainer pull)
elif command -v singularity >/dev/null 2>&1; then
    PULL=(singularity pull)
else
    echo "ERROR: neither apptainer nor singularity is available on this host." >&2
    exit 1
fi

# Images required by main.nf modules.
# Filenames follow Nextflow's cache convention: docker URI with /, : replaced by - and .img suffix.
IMAGES=(
  "quay.io/biocontainers/gatk4:4.6.1.0--py310hdfd78af_0"
  "quay.io/biocontainers/bcftools:1.21--h8b25389_0"
)

for uri in "${IMAGES[@]}"; do
    # Nextflow expects: depot.galaxyproject.org-singularity-... OR quay.io-biocontainers-...-...img
    fname="$(echo "${uri}" | sed -e 's|[/:]|-|g').img"
    if [[ -s "${fname}" ]]; then
        echo "[skip] ${fname} already present"
        continue
    fi
    echo "[pull] ${uri} -> ${fname}"
    "${PULL[@]}" --name "${fname}" "docker://${uri}"
done

echo "Done. Images in: ${NXF_SINGULARITY_CACHEDIR}"
ls -lh "${NXF_SINGULARITY_CACHEDIR}"
