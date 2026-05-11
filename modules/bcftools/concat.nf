// bcftools concat — stitch per-interval joint-called VCFs into one cohort VCF.
// Input VCFs must be in genomic order (caller ensures via interval_id sort).

process BCFTOOLS_CONCAT {
    tag "${params.cohort_name}"
    label 'process_concat'
    publishDir "${params.outdir}", mode: 'copy'

    container 'quay.io/biocontainers/bcftools:1.21--h8b25389_0'

    input:
    tuple path(vcfs, stageAs: 'vcfs/*'), path(tbis, stageAs: 'vcfs/*')

    output:
    tuple path("${params.cohort_name}.vcf.gz"), path("${params.cohort_name}.vcf.gz.tbi"), emit: vcf

    script:
    """
    set -euo pipefail

    # Order is set by the workflow (sorted by interval_id); preserve it.
    ls vcfs/*.vcf.gz | sort > concat.list

    bcftools concat \\
        --threads ${task.cpus} \\
        --file-list concat.list \\
        -Oz \\
        -o ${params.cohort_name}.vcf.gz

    bcftools index -t -f --threads ${task.cpus} ${params.cohort_name}.vcf.gz
    """
}
