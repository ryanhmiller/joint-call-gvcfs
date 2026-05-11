// GATK4 GenotypeGVCFs — joint-genotype a single interval from a GenomicsDB workspace.

process GATK4_GENOTYPEGVCFS {
    tag "${interval_id}"
    label 'process_genotype'

    container 'quay.io/biocontainers/gatk4:4.6.1.0--py310hdfd78af_0'

    input:
    tuple val(interval_id), val(interval), path(gdb)
    path  fasta
    path  fai
    path  dict

    output:
    tuple val(interval_id), path("${interval_id}.vcf.gz"), path("${interval_id}.vcf.gz.tbi"), emit: vcf

    script:
    def avail_mem = Math.max(4, (task.memory.toGiga() - 2))
    """
    set -euo pipefail
    mkdir -p tmp

    gatk --java-options "-Xms2g -Xmx${avail_mem}g -Djava.io.tmpdir=\$PWD/tmp" \\
        GenotypeGVCFs \\
            -R ${fasta} \\
            -V gendb://${gdb} \\
            -L ${interval} \\
            -O ${interval_id}.vcf.gz \\
            --tmp-dir \$PWD/tmp
    """
}
