// GATK4 ReblockGVCF — compress/normalize a HaplotypeCaller gVCF before joint calling.
// One task per sample (embarrassingly parallel). Collapses per-base reference-confidence
// bands into a few GQ bands and drops alt alleles absent from any genotype, producing a
// smaller, simpler gVCF. This makes both GenomicsDBImport and GenotypeGVCFs much cheaper
// downstream and is GATK's standard "best practice" prep (the WARP recipe).
//
// Opt-in via --reblock. The recipe below (-do-qual-approx -floor-blocks -GQB 20/30/40)
// is the population-scale default; we deliberately omit -drop-low-quals so borderline
// rare variants are retained for downstream adjudication.

process GATK4_REBLOCKGVCF {
    tag "${sample_id}"
    label 'process_reblock'

    container 'quay.io/biocontainers/gatk4:4.6.1.0--py310hdfd78af_0'

    publishDir "${params.outdir}/reblocked", mode: 'link'

    input:
    tuple val(sample_id), path(gvcf), path(tbi)
    path  fasta
    path  fai
    path  dict

    output:
    tuple val(sample_id),
          path("${sample_id}.reblocked.g.vcf.gz"),
          path("${sample_id}.reblocked.g.vcf.gz.tbi"), emit: gvcf

    script:
    def avail_mem = Math.max(3, (task.memory.toGiga() * 0.8) as int)
    """
    set -euo pipefail
    mkdir -p tmp

    gatk --java-options "-Xms2g -Xmx${avail_mem}g -Djava.io.tmpdir=\$PWD/tmp" \\
        ReblockGVCF \\
            -R ${fasta} \\
            -V ${gvcf} \\
            -do-qual-approx \\
            -floor-blocks -GQB 20 -GQB 30 -GQB 40 \\
            -O ${sample_id}.reblocked.g.vcf.gz \\
            --tmp-dir \$PWD/tmp
    """
}
