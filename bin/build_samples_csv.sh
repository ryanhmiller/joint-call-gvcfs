#!/usr/bin/env bash
# Build samples.csv from an nf-core/sarek output tree.
#
# Sarek emits per-sample gVCFs at:
#   <SAREK_OUTDIR>/<SAMPLE>/results/variant_calling/haplotypecaller/<SAMPLE>/<SAMPLE>.haplotypecaller.g.vcf.gz
# (matches the layout produced by old/final_script6-ryan.sh)
#
# Usage:
#   bash bin/build_samples_csv.sh <ROOT_DIR> > samples.csv

set -euo pipefail

ROOT="${1:?usage: build_samples_csv.sh <root_dir>}"

echo "sample_id,gvcf,gvcf_tbi"
# -L so find descends into ROOT even when it is a symlink to a directory
# (e.g. the archive path is symlinked into /nobackup/archive/...).
find -L "${ROOT}" -name '*.haplotypecaller.g.vcf.gz' -not -name '*.tbi' | sort | while read -r gvcf; do
    sample=$(basename "${gvcf}" .haplotypecaller.g.vcf.gz)
    tbi="${gvcf}.tbi"
    if [[ ! -s "${tbi}" ]]; then
        echo "WARN: missing index for ${gvcf}" >&2
        continue
    fi
    echo "${sample},${gvcf},${tbi}"
done
