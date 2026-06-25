// GATK4 fused GenomicsDBImport -> GenotypeGVCFs for one interval (Option B).
//
// Builds the per-interval GenomicsDB workspace, joint-genotypes straight out of
// it, then DELETES the workspace inside the same task. The GDB is NEVER declared
// as a Nextflow output, which is the whole point:
//   * its ~2,282 TileDB files exist only for the task's lifetime, so peak file
//     count is bounded by concurrency (maxForks x ~2,282), not by the 1,558
//     intervals -> the 2M-inode autodelete quota is never approached;
//   * deleting it cannot invalidate the -resume cache (only the VCF is an
//     output), so the cache-poisoning failure from runbook 2026-06-21 cannot
//     happen here;
//   * --consolidate is dropped: it only existed to shrink a *persisted*
//     workspace, and nothing persists now -> the ~10h/task I/O-wait pass that
//     blew the 7-day wall (runbook 2026-06-25) is gone.
//
// Replaces the separate GATK4_GENOMICSDBIMPORT + GATK4_GENOTYPEGVCFS pair; emits
// the same (interval_id, vcf, tbi) tuple so BCFTOOLS_CONCAT is unchanged.

process GATK4_GDB_GENOTYPE {
    tag "${interval_id}"
    label 'process_jointcall'

    container 'quay.io/biocontainers/gatk4:4.6.1.0--py310hdfd78af_0'

    input:
    tuple val(interval_id), val(interval)
    path  sample_map
    path  fasta
    path  fai
    path  dict

    output:
    tuple val(interval_id), path("${interval_id}.vcf.gz"), path("${interval_id}.vcf.gz.tbi"), emit: vcf

    script:
    def gdb            = "${interval_id}_gdb"
    // Both GATK steps run sequentially, so peak heap = max(import, genotype) heap,
    // not the sum. Import is the bigger consumer. 0.7 (vs the old 0.8) leaves room
    // for GenomicsDB's off-heap TileDB buffers, which also count against the Slurm
    // cgroup memory limit -- import alone ran fine at Xmx38g in a 48 GB slot.
    def import_mem     = Math.max(8, (task.memory.toGiga() * 0.7) as int)
    def genotype_mem   = Math.max(4, (task.memory.toGiga() * 0.7) as int)
    def batch_size     = params.gdb_batch_size ?: 50
    def reader_threads = params.gdb_reader_threads ?: 4
    """
    set -euo pipefail
    mkdir -p tmp

    # ---- 1. Import all sample gVCFs into a transient per-interval GenomicsDB ----
    # No --consolidate: the workspace is deleted below, so fragment count is moot.
    gatk --java-options "-Xms4g -Xmx${import_mem}g -Djava.io.tmpdir=\$PWD/tmp -DGATK_STACKTRACE_ON_USER_EXCEPTION=true" \\
        GenomicsDBImport \\
            --sample-name-map ${sample_map} \\
            --genomicsdb-workspace-path ${gdb} \\
            --intervals ${interval} \\
            --batch-size ${batch_size} \\
            --reader-threads ${reader_threads} \\
            --bypass-feature-reader \\
            --genomicsdb-shared-posixfs-optimizations true \\
            --tmp-dir \$PWD/tmp

    # ---- 2. Joint-genotype straight out of the workspace ----
    gatk --java-options "-Xms2g -Xmx${genotype_mem}g -Djava.io.tmpdir=\$PWD/tmp" \\
        GenotypeGVCFs \\
            -R ${fasta} \\
            -V gendb://${gdb} \\
            -L ${interval} \\
            -O ${interval_id}.vcf.gz \\
            --tmp-dir \$PWD/tmp

    # ---- 3. Drop the workspace now that the VCF exists ----
    # Reached only if genotyping succeeded (set -e). On failure the workspace is
    # left in the failed task dir for debugging, and the retry rebuilds from
    # scratch in a fresh dir -- no partial GDB is ever reused.
    rm -rf ${gdb}
    """
}
