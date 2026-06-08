#!/usr/bin/env nextflow

nextflow.enable.dsl = 2

include { GATK4_GENOMICSDBIMPORT } from './modules/gatk4/genomicsdbimport.nf'
include { GATK4_GENOTYPEGVCFS    } from './modules/gatk4/genotypegvcfs.nf'
include { BCFTOOLS_CONCAT        } from './modules/bcftools/concat.nf'

// Split the reference (via .fai) into restartable chunks.
// Mirrors old/scripts/make_intervals.py.
def makeIntervals(faiPath, long chunkBp, boolean includeAlt, boolean includeMito) {
    def primaryRe = ~/^chr([1-9]|1[0-9]|2[0-2]|X|Y)$/
    // def primaryRe = ~/^chr22$/
    def out = []
    file(faiPath).eachLine { line ->
        def fields = line.split('\t')
        if (fields.size() < 2) return
        def contig = fields[0]
        long length = fields[1] as long

        def keep
        if (includeAlt) {
            keep = (contig == 'chrM') ? includeMito : true
        } else if (contig == 'chrM') {
            keep = includeMito
        } else {
            keep = (contig ==~ primaryRe)
        }
        if (!keep) return

        long nChunks = ((length - 1).intdiv(chunkBp)) + 1
        (0L..<nChunks).each { long i ->
            long start = i * chunkBp + 1
            long end = Math.min(start + chunkBp - 1, length)
            def id = String.format('%04d', out.size() + 1)
            out << [ id: id, interval: "${contig}:${start}-${end}" ]
        }
    }
    return out
}

workflow {
    // ---- Required params ----
    if (!params.input)  exit 1, "--input <samples.csv> is required (columns: sample_id,gvcf,gvcf_tbi)"
    if (!params.fasta)  exit 1, "--fasta <ref.fa> is required"
    if (!params.fai)    exit 1, "--fai <ref.fa.fai> is required"
    if (!params.dict)   exit 1, "--dict <ref.dict> is required"

    fasta = file(params.fasta, checkIfExists: true)
    fai   = file(params.fai,   checkIfExists: true)
    dict  = file(params.dict,  checkIfExists: true)

    // ---- Sample map: one line per sample, "sample_id<TAB>absolute_gvcf_path" ----
    // GATK reads gVCFs directly from these paths (no Nextflow staging), so the
    // gVCFs must be visible from compute nodes.
    sample_map = channel.fromPath(params.input, checkIfExists: true)
        .splitCsv(header: true)
        .map { row ->
            def gvcf = file(row.gvcf, checkIfExists: true)
            "${row.sample_id}\t${gvcf}"
        }
        .collectFile(name: 'sample_map.tsv', newLine: true, sort: true)
        .first()  // value channel so every interval task receives the same file

    // ---- Intervals ----
    intervals = makeIntervals(
        params.fai,
        params.interval_bp as long,
        params.include_alt as boolean,
        params.include_mito as boolean
    )
    log.info "Built ${intervals.size()} intervals of up to ${params.interval_bp} bp"
    intervals_ch = channel.fromList(intervals.collect { row -> [ row.id, row.interval ] })

    // ---- Joint calling ----
    GATK4_GENOMICSDBIMPORT(intervals_ch, sample_map, fasta, fai, dict)
    GATK4_GENOTYPEGVCFS(GATK4_GENOMICSDBIMPORT.out.gdb, fasta, fai, dict)

    // ---- Concatenate interval VCFs in genomic order ----
    // interval_id is zero-padded, so lexical sort == genomic order.
    concat_input = GATK4_GENOTYPEGVCFS.out.vcf
        .toSortedList { a, b -> a[0] <=> b[0] }
        .map { items ->
            tuple(
                items.collect { item -> item[1] },
                items.collect { item -> item[2] }
            )
        }

    BCFTOOLS_CONCAT(concat_input)
}
