// GATK4 GenomicsDBImport — per-interval combine of all sample gVCFs into a TileDB workspace.
// One task per interval. The workspace directory is emitted for downstream genotyping.

process GATK4_GENOMICSDBIMPORT {
    tag "${interval_id}"
    label 'process_genomicsdb'

    container 'quay.io/biocontainers/gatk4:4.6.1.0--py310hdfd78af_0'

    input:
    tuple val(interval_id), val(interval)
    path  sample_map
    path  fasta
    path  fai
    path  dict

    output:
    tuple val(interval_id), val(interval), path("${interval_id}_gdb"), emit: gdb

    script:
    def avail_mem = Math.max(8, (task.memory.toGiga() - 4))
    def batch_size = params.gdb_batch_size ?: 50
    def reader_threads = params.gdb_reader_threads ?: 4
    """
    set -euo pipefail
    mkdir -p tmp

    gatk --java-options "-Xms4g -Xmx${avail_mem}g -Djava.io.tmpdir=\$PWD/tmp -DGATK_STACKTRACE_ON_USER_EXCEPTION=true" \\
        GenomicsDBImport \\
            --sample-name-map ${sample_map} \\
            --genomicsdb-workspace-path ${interval_id}_gdb \\
            --intervals ${interval} \\
            --batch-size ${batch_size} \\
            --reader-threads ${reader_threads} \\
            --consolidate true \\
            --genomicsdb-shared-posixfs-optimizations true \\
            --tmp-dir \$PWD/tmp
    """
}
