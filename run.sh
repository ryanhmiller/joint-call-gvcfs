#!/usr/bin/env bash
# Slurm driver for joint-call-gvcfs.
# Submits the Nextflow head process; Nextflow itself submits compute tasks.
# Edit the marked sections (look for "EDIT ME"), then: sbatch run.sh
#
#SBATCH -J joint-call-gvcfs
#SBATCH -t 7-00:00:00
#SBATCH -c 2
#SBATCH --mem=9G
#SBATCH -o logs/joint-call-gvcfs.%j.out
#SBATCH -e logs/joint-call-gvcfs.%j.err
#SBATCH --mail-type=FAIL,END
#SBATCH --mail-user=ryanhm@byu.edu          # EDIT ME

set -eo pipefail
mkdir -p logs

# ---- Env: conda + apptainer ----
eval "$(/apps/miniconda3/latest/bin/conda shell.bash hook 2> /dev/null)"   # EDIT ME
conda activate nf
ml apptainer

# Apptainer mount tweaks (helpful on shared HPCs).
export APPTAINER_IMAGE_MOUNT_TIMEOUT=120
export SINGULARITY_IMAGE_MOUNT_TIMEOUT=120
export APPTAINER_DISABLE_CLONE_FD=1
export SINGULARITY_DISABLE_CLONE_FD=1

# ---- Offline + image cache ----
export NXF_OFFLINE=true
export NXF_SINGULARITY_CACHEDIR=/home/ryanhm/groups/grp_life_and_legacy_storage2/nobackup/autodelete/image_cache            # EDIT ME

# ---- Inputs ----
SAMPLES=/home/ryanhm/groups/grp_life_and_legacy_storage2/nobackup/autodelete/joint-vcf-results/life_legacy_sample_sheet-combined.csv                                          # EDIT ME
REF=/home/ryanhm/groups/grp_life_and_legacy_storage2/nobackup/autodelete/reference/WholeGenomeFasta       # EDIT ME
FASTA=${REF}/Homo_sapiens_assembly38.fasta
FAI=${REF}/Homo_sapiens_assembly38.fasta.fai
DICT=${REF}/Homo_sapiens_assembly38.dict

# ---- Workdir lives on shared scratch (so -resume can see prior tasks) ----
WORKDIR=/home/ryanhm/groups/grp_life_and_legacy_storage2/nobackup/autodelete/joint-vcf-results/work                        # EDIT ME
OUTDIR=/home/ryanhm/groups/grp_life_and_legacy_storage2/nobackup/autodelete/joint-vcf-results/results                      # EDIT ME
mkdir -p "${WORKDIR}" "${OUTDIR}"

# ---- Run ----
nextflow run . \
    -profile slurm \
    -work-dir "${WORKDIR}" \
    -resume \
    --input        "${SAMPLES}" \
    --fasta        "${FASTA}" \
    --fai          "${FAI}" \
    --dict         "${DICT}" \
    --interval_bp  10000000 \
    --outdir       "${OUTDIR}" \
    --cohort_name  life_legacies_may14_2026
