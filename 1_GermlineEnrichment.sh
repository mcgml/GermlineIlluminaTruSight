#!/bin/bash
#PBS -l walltime=12:00:00
#PBS -l ncpus=12
PBS_O_WORKDIR=(`echo $PBS_O_WORKDIR | sed "s/^\/state\/partition1//" `)
cd $PBS_O_WORKDIR

#Description: Germline Enrichment Pipeline (Illumina paired-end). Not for use with other library preps/ experimental conditions.
#Author: Matt Lyon, All Wales Medical Genetics Lab
#Mode: BY_SAMPLE
version="dev"

# Directory structure required for pipeline
#
# /data
# └── results
#     └── seqId
#         ├── panel1
#         │   ├── sample1
#         │   ├── sample2
#         │   └── sample3
#         └── panel2
#             ├── sample1
#             ├── sample2
#             └── sample3
#
# Script 1 runs in sample folder

#load sample variables
. *.variables

### Preprocessing ###

#map one or more lanes of data for a single sample
for fastqPair in $(ls "$sampleId"_*.fastq.gz | cut -d_ -f1-3 | sort | uniq); do
        
    #parse fastq filenames
    laneId=$(echo "$fastqPair" | cut -d_ -f3)
    read1Fastq=$(ls "$fastqPair"_R1*fastq.gz)
    read2Fastq=$(ls "$fastqPair"_R2*fastq.gz)
    
    #Trim adapters and remove short reads
    /share/apps/cutadapt-distros/cutadapt-1.9.1/bin/cutadapt \
    -a CTGTCTCTTATACACATCT \
    -A CTGTCTCTTATACACATCT \
    -o $(echo "$read1Fastq" | sed 's/\.fastq\.gz/_trimmed\.fastq/g') \
    -p $(echo "$read2Fastq" | sed 's/\.fastq\.gz/_trimmed\.fastq/g') \
    --minimum-length 30 \
    "$read1Fastq" \
    "$read2Fastq"

    #Align reads to reference genome, sort by coordinate and convert to BAM
    /share/apps/bwa-distros/bwa-0.7.15/bwa mem \
    -M \
    -R '@RG\tID:'"$seqId"_"$laneId"_"$sampleId"'\tSM:'"$sampleId"'\tPL:ILLUMINA\tLB:'"$worklistId_$panel_$sampleId" \
    -t 8 \
    /data/db/human/mappers/b37/bwa/human_g1k_v37.fasta \
    $(echo "$read1Fastq" | sed 's/\.fastq\.gz/_trimmed\.fastq/g') $(echo "$read2Fastq" | sed 's/\.fastq\.gz/_trimmed\.fastq/g') | \
    /share/apps/samtools-distros/samtools-1.3.1/samtools sort -l0 -o "$seqId"_"$sampleId"_"$laneId"_sorted.bam

done

#merge mulitple lanes
if [ $(ls "$seqId"_"$sampleId"_*_sorted.bam | wc -l | sed 's/^[[:space:]]*//g') -gt 1 ]; then
    /share/apps/samtools-distros/samtools-1.3.1/samtools merge -@ 8 -u "$seqId"_"$sampleId"_all_sorted.bam "$seqId"_"$sampleId"_*_sorted.bam
else
    mv "$seqId"_"$sampleId"_*_sorted.bam "$seqId"_"$sampleId"_all_sorted.bam
fi

#Mark duplicate reads
/share/apps/jre-distros/jre1.8.0_71/bin/java -Djava.io.tmpdir=tmp -Xmx8g -jar /share/apps/picard-tools-distros/picard-tools-2.5.0/picard.jar MarkDuplicates \
INPUT="$seqId"_"$sampleId"_all_sorted.bam \
OUTPUT="$seqId"_"$sampleId"_rmdup.bam \
METRICS_FILE="$seqId"_"$sampleId"_MarkDuplicatesMetrics.txt \
CREATE_INDEX=true \
COMPRESSION_LEVEL=0

#Identify regions requiring realignment
/share/apps/jre-distros/jre1.8.0_71/bin/java -Djava.io.tmpdir=tmp -Xmx4g -jar /share/apps/GATK-distros/GATK_3.6.0/GenomeAnalysisTK.jar \
-T RealignerTargetCreator \
-R /data/db/human/gatk/2.8/b37/human_g1k_v37.fasta \
-known /data/db/human/gatk/2.8/b37/1000G_phase1.indels.b37.vcf \
-known /data/db/human/gatk/2.8/b37/Mills_and_1000G_gold_standard.indels.b37.vcf \
-I "$seqId"_"$sampleId"_rmdup.bam \
-o "$seqId"_"$sampleId"_realign.intervals \
-L /data/diagnostics/pipelines/GermlineEnrichment/GermlineEnrichment-"$version"/"$panel"/"$panel"_ROI.bed \
-ip 230 \
-nt 8 \
-dt NONE

#Realign around indels
/share/apps/jre-distros/jre1.8.0_71/bin/java -Djava.io.tmpdir=tmp -Xmx8g -jar /share/apps/GATK-distros/GATK_3.6.0/GenomeAnalysisTK.jar \
-T IndelRealigner \
-R /data/db/human/gatk/2.8/b37/human_g1k_v37.fasta \
-known /data/db/human/gatk/2.8/b37/1000G_phase1.indels.b37.vcf \
-known /data/db/human/gatk/2.8/b37/Mills_and_1000G_gold_standard.indels.b37.vcf \
-targetIntervals "$seqId"_"$sampleId"_realign.intervals \
-I "$seqId"_"$sampleId"_rmdup.bam \
-o "$seqId"_"$sampleId"_realigned.bam \
-compress 0 \
-dt NONE

#Analyse patterns of covariation in the sequence dataset
/share/apps/jre-distros/jre1.8.0_71/bin/java -Djava.io.tmpdir=tmp -Xmx12g -jar /share/apps/GATK-distros/GATK_3.6.0/GenomeAnalysisTK.jar \
-T BaseRecalibrator \
-R /data/db/human/gatk/2.8/b37/human_g1k_v37.fasta \
-knownSites /data/db/human/gatk/2.8/b37/dbsnp_138.b37.vcf \
-knownSites /data/db/human/gatk/2.8/b37/1000G_phase1.indels.b37.vcf \
-knownSites /data/db/human/gatk/2.8/b37/Mills_and_1000G_gold_standard.indels.b37.vcf \
-I "$seqId"_"$sampleId"_realigned.bam \
-L /data/diagnostics/pipelines/GermlineEnrichment/GermlineEnrichment-"$version"/"$panel"/"$panel"_ROI.bed \
-o "$seqId"_"$sampleId"_recal_data.table \
-ip 230 \
-nct 8 \
-dt NONE

#Do a second pass to analyze covariation remaining after recalibration
/share/apps/jre-distros/jre1.8.0_71/bin/java -Djava.io.tmpdir=tmp -Xmx8g -jar /share/apps/GATK-distros/GATK_3.6.0/GenomeAnalysisTK.jar \
-T BaseRecalibrator \
-R /data/db/human/gatk/2.8/b37/human_g1k_v37.fasta \
-knownSites /data/db/human/gatk/2.8/b37/dbsnp_138.b37.vcf \
-knownSites /data/db/human/gatk/2.8/b37/1000G_phase1.indels.b37.vcf \
-knownSites /data/db/human/gatk/2.8/b37/Mills_and_1000G_gold_standard.indels.b37.vcf \
-BQSR "$seqId"_"$sampleId"_recal_data.table \
-I "$seqId"_"$sampleId"_realigned.bam \
-L /data/diagnostics/pipelines/GermlineEnrichment/GermlineEnrichment-"$version"/"$panel"/"$panel"_ROI.bed \
-o "$seqId"_"$sampleId"_post_recal_data.table \
-nct 8 \
-ip 230 \
-dt NONE

#Apply the recalibration to your sequence data
/share/apps/jre-distros/jre1.8.0_71/bin/java -Djava.io.tmpdir=tmp -Xmx8g -jar /share/apps/GATK-distros/GATK_3.6.0/GenomeAnalysisTK.jar \
-T PrintReads \
-R /data/db/human/gatk/2.8/b37/human_g1k_v37.fasta \
-I "$seqId"_"$sampleId"_realigned.bam \
-BQSR "$seqId"_"$sampleId"_post_recal_data.table \
-o "$seqId"_"$sampleId".bam \
-compress 0 \
-nct 8 \
-dt NONE

### Variant calling ###

#SNPs and Indels with Haplotypecaller
/share/apps/jre-distros/jre1.8.0_71/bin/java -Djava.io.tmpdir=tmp -Xmx12g -jar /share/apps/GATK-distros/GATK_3.6.0/GenomeAnalysisTK.jar \
-T HaplotypeCaller \
-R /data/db/human/gatk/2.8/b37/human_g1k_v37.fasta \
--dbsnp /data/db/human/gatk/2.8/b37/dbsnp_138.b37.vcf \
-I "$seqId"_"$sampleId".bam \
-L /data/diagnostics/pipelines/GermlineEnrichment/GermlineEnrichment-"$version"/"$panel"/"$panel"_ROI.bed \
-o "$seqId"_"$sampleId".g.vcf \
--genotyping_mode DISCOVERY \
-stand_emit_conf 10 \
-stand_call_conf 30 \
--emitRefConfidence GVCF \
-nct 8 \
-dt NONE

#Add VCF meta data
grep '^##' "$seqId"_"$sampleId".g.vcf > "$seqId"_"$sampleId"_meta.g.vcf
echo \#\#SAMPLE\=\<ID\="$sampleId",WorklistId\="$worklistId",SeqId\="$seqId",Panel\="$panel",PipelineName\=GermlineEnrichment,PipelineVersion\="$version",RemoteBamFilePath\=$(find $PWD "$seqId"_"$sampleId".bam)\> >> "$seqId"_"$sampleId"_meta.g.vcf
grep -v '^##' "$seqId"_"$sampleId".g.vcf >> "$seqId"_"$sampleId"_meta.g.vcf

#Structural variants with pindel
#echo -e "$seqId"_"$sampleId".bam"\t"300"\t""$sampleId" > pindel.txt
#/share/apps/pindel-distros/pindel-0.2.5b8/pindel \
#-f /data/db/human/gatk/2.8/b37/human_g1k_v37.fasta \
#-i pindel.txt \
#-c ALL \
#-T 8 \
#--max_range_index 6 \
#-o "$seqId"_"$sampleId"_pindel

#Convert pindel output to VCF format and filter calls
#/share/apps/pindel-distros/pindel-0.2.5b8/pindel2vcf \
#-P "$seqId"_"$sampleId"_pindel \
#-r /data/db/human/gatk/2.8/b37/human_g1k_v37.fasta \
#-R human_g1k_v37 \
#-d none \
#-e 3 \
#--min_size 50 \
#--min_coverage 10 \
#-v "$seqId"_"$sampleId"_pindel.vcf

### QC ###

#Split BED files by contig for later
grep -P '^[1-22]' /data/diagnostics/pipelines/GermlineEnrichment/GermlineEnrichment-"$version"/"$panel"/"$panel"_ROI.bed > autosomal.bed
grep -P '^Y' /data/diagnostics/pipelines/GermlineEnrichment/GermlineEnrichment-"$version"/"$panel"/"$panel"_ROI.bed > y.bed

#Convert BED to interval_list for later
/share/apps/jre-distros/jre1.8.0_71/bin/java -Djava.io.tmpdir=tmp -Xmx8g -jar /share/apps/picard-tools-distros/picard-tools-2.5.0/picard.jar BedToIntervalList \
I=/data/diagnostics/pipelines/GermlineEnrichment/GermlineEnrichment-"$version"/"$panel"/"$panel"_ROI.bed \
O="$bedFileName".interval_list \
SD=/data/db/human/gatk/2.8/b37/human_g1k_v37.dict

#Fastqc: raw sequence quality
for i in $(ls *_trimmed.fastq); do
    /share/apps/fastqc-distros/fastqc_v0.11.5/fastqc -t8 --extract "$i"
    
    basicStats=$(head -n1 "$seqId"_"$sampleId"_R1_trimmed_fastqc/summary.txt | tail -n1 |cut -s -f1)
    perBaseSeqQuality=$(head -n2 "$seqId"_"$sampleId"_R1_trimmed_fastqc/summary.txt | tail -n1 |cut -s -f1)
    perTileSeqQuality=$(head -n3 "$seqId"_"$sampleId"_R1_trimmed_fastqc/summary.txt | tail -n1 |cut -s -f1)
    perSeqQualityScore=$(head -n4 "$seqId"_"$sampleId"_R1_trimmed_fastqc/summary.txt | tail -n1 |cut -s -f1)
    perBaseNContent=$(head -n7 "$seqId"_"$sampleId"_R1_trimmed_fastqc/summary.txt | tail -n1 |cut -s -f1)
    overRepresentedSeq=$(head -n10 "$seqId"_"$sampleId"_R1_trimmed_fastqc/summary.txt | tail -n1 |cut -s -f1)
    adapterContent=$(head -n11 "$seqId"_"$sampleId"_R1_trimmed_fastqc/summary.txt | tail -n1 |cut -s -f1)
    
    echo -e "$i\t$basicStats\t$perBaseSeqQuality\t$perTileSeqQuality\tperSeqQualityScore\t$perBaseNContent\t$overRepresentedSeq\t$adapterContent"
done

#Calculate insert size: fragmentation performance
/share/apps/jre-distros/jre1.8.0_71/bin/java -Djava.io.tmpdir=tmp -Xmx8g -jar /share/apps/picard-tools-distros/picard-tools-2.5.0/picard.jar CollectInsertSizeMetrics \
I="$seqId"_"$sampleId".bam \
O="$seqId"_"$sampleId"_insert_metrics.txt \
H="$seqId"_"$sampleId"_insert_metrics.pdf

meanInsertSize=$(head -n8 "$seqId"_"$sampleId"_insert_metrics.txt | tail -n1 | cut -s -f5) #mean insert size
sdInsertSize=$(head -n8 "$seqId"_"$sampleId"_insert_metrics.txt | tail -n1 | cut -s -f6) #insert size standard deviation

#Extract duplicationRate: identify over-amplification
duplicationRate=$(head -n8 "$seqId"_"$sampleId"_MarkDuplicatesMetrics.txt | tail -n1 | cut -s -f9) #The percentage of mapped sequence that is marked as duplicate.

#HsMetrics: capture performance
/share/apps/jre-distros/jre1.8.0_71/bin/java -Djava.io.tmpdir=tmp -Xmx8g -jar /share/apps/picard-tools-distros/picard-tools-2.5.0/picard.jar CollectHsMetrics \
I="$seqId"_"$sampleId".bam \
O="$seqId"_"$sampleId"_hs_metrics.txt \
R=/data/db/human/gatk/2.8/b37/human_g1k_v37.fasta \
BAIT_INTERVALS="$bedFileName".interval_list \
TARGET_INTERVALS="$bedFileName".interval_list

totalReads=$(head -n8 "$seqId"_"$sampleId"_hs_metrics.txt | tail -n1 | cut -s -f6) #The total number of reads in the SAM or BAM file examine.
pctSelectedBases=$(head -n8 "$seqId"_"$sampleId"_hs_metrics.txt | tail -n1 | cut -s -f19) #On+Near Bait Bases / PF Bases Aligned.

#Generate per-base/per-target coverage: variant detection sensitivity
/share/apps/jre-distros/jre1.8.0_71/bin/java -Djava.io.tmpdir=tmp -Xmx8g -jar /share/apps/GATK-distros/GATK_3.6.0/GenomeAnalysisTK.jar \
-T DepthOfCoverage \
-R /data/db/human/gatk/2.8/b37/human_g1k_v37.fasta \
-o "$seqId"_"$sampleId"_DepthOfCoverage \
-I "$seqId"_"$sampleId".bam \
-L /data/diagnostics/pipelines/GermlineEnrichment/GermlineEnrichment-"$version"/"$panel"/"$panel"_ROI.bed \
--countType COUNT_FRAGMENTS \
--minMappingQuality 20 \
--omitIntervalStatistics \
-ct 30 \
-nt 8 \
-dt NONE

meanOnTargetCoverage=$(head -n2 $seqId"_"$sampleId"_DepthOfCoverage".sample_summary | tail -n1 | cut -s -f3)
pctTargetBases30x=$(head -n2 $seqId"_"$sampleId"_DepthOfCoverage".sample_summary | tail -n1 | cut -s -f7)

#Calculate gene percentage coverage
/share/apps/jre-distros/jre1.8.0_71/bin/java -Djava.io.tmpdir=tmp -Xmx8g -jar /data/diagnostics/apps/CoverageCalculator-2.0.0/CoverageCalculator-2.0.0.jar \
"$seqId"_"$sampleId"_DepthOfCoverage \
/data/diagnostics/pipelines/GermlineEnrichment/GermlineEnrichment-"$version"/"$panel"/"$panel"_genes.txt \
/data/db/human/refseq/ref_GRCh37.p13_top_level.gff3 \
-p5 > "$seqId"_"$sampleId"_PercentageCoverage.txt

#Generate BQSR plots
/share/apps/jre-distros/jre1.8.0_71/bin/java -Djava.io.tmpdir=tmp -Xmx2g -jar /share/apps/GATK-distros/GATK_3.6.0/GenomeAnalysisTK.jar \
-T AnalyzeCovariates \
-R /data/db/human/gatk/2.8/b37/human_g1k_v37.fasta \
-before "$seqId"_"$sampleId"_recal_data.table \
-after "$seqId"_"$sampleId"_post_recal_data.table \
-plots "$seqId"_"$sampleId"_recalibration_plots.pdf \
-csv "$seqId"_"$sampleId"_recalibration.csv \
-dt NONE

#Extract 1kg autosomal snps for contamination analysis
/share/apps/jre-distros/jre1.8.0_71/bin/java -Djava.io.tmpdir=tmp -Xmx4g -jar /share/apps/GATK-distros/GATK_3.6.0/GenomeAnalysisTK.jar \
-R /data/db/human/gatk/2.8/b37/human_g1k_v37.fasta \
-T SelectVariants \
--variant /data/db/human/gatk/2.8/b37/1000G_phase1.snps.high_confidence.b37.vcf \
-o 1kg_highconfidence_autosomal_ontarget_monoallelic_snps.vcf \
-selectType SNP \
-restrictAllelesTo BIALLELIC \
-env \
-ef \
-L autosomal.bed \
-nt 8 \
-dt NONE

#Calculate dna contamination: sample-to-sample contamination
/share/apps/verifyBamID-distros/verifyBamID_1.1.3/verifyBamID/bin/verifyBamID \
--bam "$seqId"_"$sampleId".bam \
--vcf 1kg_highconfidence_autosomal_ontarget_monoallelic_snps.vcf \
--out "$seqId"_"$sampleId"_contamination \
--maxDepth 1000 \
--precise \
--ignoreRG \
--verbose

freemix=$(tail -n1 "$seqId"_"$sampleId"_contamination.selfSM | cut -s -f7)

#Calculate mean coverage for Y chrom: gender check
#TODO try whole chromosome Y. ?Normalisation
/share/apps/jre-distros/jre1.8.0_71/bin/java -Djava.io.tmpdir=tmp -Xmx8g -jar /share/apps/GATK-distros/GATK_3.6.0/GenomeAnalysisTK.jar \
-R /data/db/human/gatk/2.8/b37/human_g1k_v37.fasta \
-T DepthOfCoverage \
-o y \
-L y.bed \
-I "$seqId"_"$sampleId".bam \
--omitDepthOutputAtEachBase \
--omitIntervalStatistics \
--omitLocusTable \
-nt 8 \
-dt NONE

yMeanCoverage=$(head -n2 y.sample_summary | tail -n1 | cut -s -f3)

#Print QC metrics
echo -e "$totalReads\t$duplicationRate\t$pctSelectedBases\t$pctTargetBases30x\t$meanOnTargetCoverage\t$yMeanCoverage\t$freemix\t$meanInsertSize\t$sdInsertSize"

### Clean up ###
#rm -r tmp
#rm "$seqId"_"$sampleId"_R?_trimmed.fastq
#rm "$seqId"_"$sampleId"_rmdup.ba?
#rm "$seqId"_"$sampleId"_sorted.ba?
#rm "$seqId"_"$sampleId"_recal.ba?
#rm "$seqId"_"$sampleId"_realigned.ba?
#rm autosome.sample_statistics x.sample_statistics y.sample_statistics
#rm autosomal.bed x.bed y.bed
#rm pindel.txt
#rm "$seqId"_"$sampleId"_R?_trimmed_fastqc.html
#rm "$seqId"_"$sampleId"_R?_trimmed_fastqc.zip
#rm "$seqId"_"$sampleId".g.vcf "$seqId"_"$sampleId".g.vcf.idx

#create BAM and VCF list for script 2
find $PWD -name "$seqId"_"$sampleId"_meta.g.vcf >> ../VCFsforFiltering.list
find $PWD -name "$seqId"_"$sampleId".bam >> ../FinalBAMs.list

#check if all VCFs are written
if [ $(find .. -maxdepth 1 -mindepth 1 -type d | wc -l | sed 's/^[[:space:]]*//g') -eq $(sort ../VCFsforFiltering.list | uniq | wc -l | sed 's/^[[:space:]]*//g') ]; then
    echo "$seqId" > ../variables
    echo "$panel" >> ../variables
    cp 2_GermlineEnrichment.sh .. && cd .. && qsub 2_GermlineEnrichment.sh
fi