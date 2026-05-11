# joint-call-gvcfs

A small Nextflow pipeline that joint-calls a cohort of per-sample gVCFs
(produced by [nf-core/sarek](https://nf-co.re/sarek)) into a single
multi-sample VCF. Designed to run on a Slurm HPC with `-resume`, so a
crashed or timed-out interval can be restarted without losing finished work.

## What it does

```
samples.csv (1500 rows)
   │
   ├──> intervals (~300 chunks of 10 Mb across chr1-22, X, Y, M)
   │
   ├──> GenomicsDBImport         per interval, parallel  (nf-core module)
   │
   ├──> GenotypeGVCFs            per interval, parallel  (nf-core module)
   │
   └──> bcftools concat          single task             (nf-core module)
         -> cohort.vcf.gz + .tbi
```

## Quick start

```bash
# 1. Pre-fetch container images (login node, once).
export NXF_SINGULARITY_CACHEDIR=/path/to/singularity_cache
bash bin/fetch_images.sh

# 2. Build samples.csv with absolute paths to your gVCFs.
#    Columns: sample_id,gvcf,gvcf_tbi
#    For a Sarek output tree, use the helper:
#      bash bin/build_samples_csv.sh /path/to/sarek/output > samples.csv
#    Otherwise see assets/samples.example.csv for the format.

# 3. Launch as a small Slurm driver job (the driver stays alive for the
#    whole run; compute tasks are submitted by Nextflow).
sbatch run.sh
```

A `run.sh` driver wraps the Nextflow command. A starter is below.

See [`run.sh`](run.sh) in this repo for a complete sbatch template — edit the
sections marked `EDIT ME` (email, conda path, image cache, sample sheet, reference,
workdir, outdir) and `sbatch run.sh`.

## Inputs

| Param | Required | Default | Meaning |
|---|---|---|---|
| `--input` | yes | — | CSV with `sample_id,gvcf,gvcf_tbi` (absolute paths) |
| `--fasta` | yes | — | Reference FASTA |
| `--fai` | yes | — | Reference `.fai` index |
| `--dict` | yes | — | Reference `.dict` |
| `--interval_bp` | no | 10_000_000 | Interval chunk size in bp |
| `--include_alt` | no | false | Include alt/decoy/unplaced contigs |
| `--include_mito` | no | true | Include `chrM` |
| `--outdir` | no | `results` | Output directory |
| `--cohort_name` | no | `cohort` | Output file prefix |

## Tuning

Per-process resources live in `conf/resources.config`. Defaults assume
~1500 samples × ~10 Mb intervals. On retry, memory and time escalate:

- GenomicsDBImport: 32 GB / 24 h → 48 GB / 36 h → 64 GB / 48 h
- GenotypeGVCFs:    16 GB /  8 h → 32 GB / 16 h → 48 GB / 24 h
- bcftools concat:  16 GB /  6 h → 32 GB / 12 h → 48 GB / 24 h

Concurrency cap: `executor.$slurm.queueSize = 100` in `nextflow.config`.
Raise or lower based on your share of the cluster.

Slurm partition/account: edit `conf/slurm.config` (uncomment `queue` and
`clusterOptions`).

## Why these defaults

A previous bash-orchestrated run hit Slurm wall time on a 25 Mb interval
after 23/31 sample batches (each batch ~1.5 h, sequential inside
GenomicsDBImport). Halving interval size keeps every task well under the
24 h queue limit while increasing parallelism.

`--genomicsdb-shared-posixfs-optimizations true` and `--consolidate true`
help GenomicsDB on networked filesystems and speed up the downstream
GenotypeGVCFs reads.

`process.scratch = true` makes Nextflow stage work to node-local `/tmp`
(`$SLURM_TMPDIR`) and copy outputs back, matching what the old bash
scripts did manually.

## Filtering

This pipeline outputs the **raw** joint-called VCF. Filtering (VQSR,
hard filters, `bcftools norm`, multi-allelic splitting, etc.) is done as
a separate downstream step.

## Resume

If anything fails or hits wall time, just rerun with `-resume`. Nextflow
will skip any process whose output is already cached and re-run only the
failed/missing intervals.

## Tools

- [Nextflow](https://nextflow.io) (DSL2)
- [GATK4](https://gatk.broadinstitute.org/) — `GenomicsDBImport`, `GenotypeGVCFs`
- [bcftools](https://samtools.github.io/bcftools/) — `concat`, `index`
- Module logic adapted from [nf-core/modules](https://github.com/nf-core/modules)

## Layout

```
main.nf                              workflow wiring + inline interval-splitter
nextflow.config                      global params, singularity, retry policy
run.sh                               sbatch driver (edit the marked sections)
conf/slurm.config                    Slurm executor
conf/resources.config                per-process cpus/mem/time
modules/gatk4/genomicsdbimport.nf
modules/gatk4/genotypegvcfs.nf
modules/bcftools/concat.nf
bin/make_intervals.py                standalone interval helper (mirrors main.nf)
bin/build_samples_csv.sh             build samples.csv from a Sarek output tree
bin/fetch_images.sh                  one-time apptainer pull for offline use
assets/samples.example.csv           sample sheet template
```
