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
#SBATCH --mail-user=you@example.edu          # EDIT ME

set -eo pipefail
mkdir -p logs

# ---- Env: conda + apptainer ----
eval "$(/path/to/miniconda3/bin/conda shell.bash hook 2>/dev/null)"   # EDIT ME
conda activate nf
ml apptainer

# Apptainer mount tweaks (helpful on shared HPCs).
export APPTAINER_IMAGE_MOUNT_TIMEOUT=120
export SINGULARITY_IMAGE_MOUNT_TIMEOUT=120
export APPTAINER_DISABLE_CLONE_FD=1
export SINGULARITY_DISABLE_CLONE_FD=1

# ---- Offline + image cache ----
export NXF_OFFLINE=true
export NXF_SINGULARITY_CACHEDIR=/path/to/singularity_cache            # EDIT ME

# ---- Inputs ----
SAMPLES=/path/to/samples.csv                                          # EDIT ME
REF=/path/to/Homo_sapiens/GATK/GRCh38/Sequence/WholeGenomeFasta       # EDIT ME
FASTA=${REF}/Homo_sapiens_assembly38.fasta
FAI=${REF}/Homo_sapiens_assembly38.fasta.fai
DICT=${REF}/Homo_sapiens_assembly38.dict

# ---- Workdir lives on shared scratch (so -resume can see prior tasks) ----
WORKDIR=/path/to/scratch/joint-call-gvcfs/work                        # EDIT ME
OUTDIR=/path/to/scratch/joint-call-gvcfs/results                      # EDIT ME
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
    --cohort_name  cohort
