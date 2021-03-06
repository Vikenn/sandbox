#!/bin/bash

if [ $# -lt 3 ]
then
    echo usage $0 [sampleList] [batchDirectory] [node] [scratchDirectory] [outputRoot]
    exit 1
fi

# Directory and data names
SAMPLELIST=$1
BATCHDIR=$2
# default this to batch1 for legacy, but allow cmd line arg
ROOTDIR=/scratch/cc2qe/1kg/batch1
if [ ! -z $4 ]
then
    ROOTDIR=$4
fi
OUTPUTROOT=$BATCHDIR
if [ ! -z $5 ]
then
    OUTPUTROOT=$5
fi

# Annotations
REF=/mnt/thor_pool1/user_data/cc2qe/refdata/genomes/b37/human_b37_hs37d5.fa
#NOVOREF=/mnt/thor_pool1/user_data/cc2qe/refdata/genomes/b37/human_b37_hs37d5.k14s1.novoindex
INDELS1=/mnt/thor_pool1/user_data/cc2qe/refdata/genomes/b37/annotations/ALL.wgs.indels_mills_devine_hg19_leftAligned_collapsed_double_hit.indels.sites.vcf.gz
INDELS2=/mnt/thor_pool1/user_data/cc2qe/refdata/genomes/b37/annotations/ALL.wgs.low_coverage_vqsr.20101123.indels.sites.vcf.gz
DBSNP=/mnt/thor_pool1/user_data/cc2qe/refdata/genomes/b37/annotations/ALL.wgs.dbsnp.build135.snps.sites.vcf.gz

# PBS parameters
NODE=$3
QUEUE=primary

# Software paths
BWA=/shared/bin/bwa-0.7.4/bwa0.7.4
#NOVOALIGN=/shared/external_bin/novoalign
NOVOALIGN=/shared/external_bin/novocraft-2.08.03/novoalign
GATK=/shared/external_bin/GenomeAnalysisTK-2.5-2-gf57256b/GenomeAnalysisTK.jar
# samtools 0.1.18
SAMTOOLS=/shared/bin/samtools
PICARD=/mnt/thor_pool1/user_data/cc2qe/software/picard-tools-1.90
QUICK_Q=/mnt/thor_pool1/user_data/cc2qe/code/bin/quick_q

# ---------------------
# STEP 1: Allocate the data to the local drive

# copy the files to the local drive
# Require a lot of memory for this so we don't have tons of jobs writing to drives at once

MOVE_FILES_CMD="for SAMPLE in \`cat $SAMPLELIST\`
do 
    WORKDIR=$ROOTDIR/\$SAMPLE &&
    SAMPLEDIR=$BATCHDIR/\$SAMPLE &&

    mkdir -p \$WORKDIR &&
    rsync -avPtL \$SAMPLEDIR/fqlist* \$SAMPLEDIR/rglist \$SAMPLEDIR/*_readgroup.txt \$SAMPLEDIR/*.fastq.gz \$WORKDIR
done" &&

#MOVE_FILES_CMD="echo MOVE_FILES_CMD"



#MOVE_FILES_Q=`$QUICK_Q -m 1gb -d $NODE -t 1 -n move_${NODE} -c " $MOVE_FILES_CMD " -p 10 -q $QUEUE` &&


for SAMPLE in `cat $SAMPLELIST`
do
    WORKDIR=$ROOTDIR/$SAMPLE &&
    SAMPLEDIR=$BATCHDIR/$SAMPLE &&


# ---------------------
# STEP 2: Align the fastq files with bwa-0.7.4
# 2 cores and 5000mb of memory

ALIGN_CMD="cd $WORKDIR &&
for i in \$(seq 1 \`cat fqlist1 | wc -l\`)
do
    FASTQ1=\`sed -n \${i}p fqlist1\` &&
    FASTQ2=\`sed -n \${i}p fqlist2\` &&
    READGROUP=\`echo \$FASTQ1 | sed 's/_.*//g'\` &&

    RGSTRING=\`cat \${READGROUP}_readgroup.txt\` &&

    echo \$READGROUP &&

    time $BWA aln -t 2 -q 15 -f $SAMPLE.\${READGROUP}_1.sai $REF \$FASTQ1 &&
    time $BWA aln -t 2 -q 15 -f $SAMPLE.\${READGROUP}_2.sai $REF \$FASTQ2 &&

    time $BWA sampe -r \$RGSTRING $REF $SAMPLE.\${READGROUP}_1.sai $SAMPLE.\${READGROUP}_2.sai \$FASTQ1 \$FASTQ2 | $SAMTOOLS view -Sb - > $SAMPLE.\$READGROUP.bwa.raw.bam

done &&

echo 'cleaning up...' &&
for i in \$(seq 1 \`cat fqlist1 | wc -l\`)
do
    FASTQ1=\`sed -n \${i}p fqlist1\` &&
    FASTQ2=\`sed -n \${i}p fqlist2\` &&
    READGROUP=\`echo \$FASTQ1 | sed 's/_.*//g'\` &&

    rm \$FASTQ1 \$FASTQ2 $SAMPLE.\${READGROUP}_*.sai

done" &&

#ALIGN_CMD="echo ALIGN_CMD"

#echo $ALIGN_CMD

ALIGN_Q=`$QUICK_Q -d $NODE -t 2 -m 5000mb -n bwa_${SAMPLE}_${NODE} -c " $ALIGN_CMD " -q $QUEUE ` &&


# ---------------------
# STEP 3: Sort and fix flags on the bam file

# this only requires one core but a decent amount of memory.
SORT_CMD="cd $WORKDIR &&
for READGROUP in \`cat rglist\`
do
    time $SAMTOOLS view -bu $SAMPLE.\$READGROUP.bwa.raw.bam | \
        $SAMTOOLS sort -n -o - samtools_nsort_tmp | \
	$SAMTOOLS fixmate /dev/stdin /dev/stdout | $SAMTOOLS sort -o - samtools_csort_tmp | \
	$SAMTOOLS fillmd -b - $REF > $SAMPLE.\$READGROUP.bwa.fixed.bam &&
    
    time $SAMTOOLS index $SAMPLE.\$READGROUP.bwa.fixed.bam

done &&

echo 'clean up the raw bam files...' &&
for READGROUP in \`cat rglist\`
do
    rm $SAMPLE.\$READGROUP.bwa.raw.bam
done" &&

# echo $SORT_CMD
#SORT_CMD="echo SORT_CMD"

SORT_Q=`$QUICK_Q -m 4gb -d $NODE -t 1 -n sort_${SAMPLE}_${NODE} -c " $SORT_CMD " -q $QUEUE -z "-W depend=afterok:$ALIGN_Q"` &&


# ---------------------
# STEP 5: GATK reprocessing

GATK_CMD="cd $WORKDIR &&
for READGROUP in \`cat rglist\`
do
    time java -Xmx7800m -Djava.io.tmpdir=$WORKDIR/tmp/ -jar $PICARD/MarkDuplicates.jar \
         INPUT=$SAMPLE.\$READGROUP.bwa.fixed.bam \
         OUTPUT=$SAMPLE.\$READGROUP.bwa.fixed.mkdup.bam \
         ASSUME_SORTED=TRUE \
         METRICS_FILE=/dev/null \
         VALIDATION_STRINGENCY=SILENT \
         MAX_FILE_HANDLES=1000 \
         CREATE_INDEX=true &&

    time java -Xmx7800m -Djava.io.tmpdir=$WORKDIR/tmp -jar $GATK \
        -T RealignerTargetCreator \
        -nt 3 \
        -R $REF \
        -I $SAMPLE.\$READGROUP.bwa.fixed.mkdup.bam \
        -o $SAMPLE.\$READGROUP.intervals \
        -known $INDELS1 \
        -known $INDELS2 &&

    time java -Xmx7800m -Djava.io.tmpdir=$WORKDIR/tmp/ -jar $GATK \
         -T IndelRealigner \
         -R $REF \
         -I $SAMPLE.\$READGROUP.bwa.fixed.mkdup.bam \
         -o $SAMPLE.\$READGROUP.bwa.realign.fixed.bam \
         -targetIntervals $SAMPLE.\$READGROUP.intervals \
         -known $INDELS1 \
         -known $INDELS2 \
         -LOD 0.4 \
         -model KNOWNS_ONLY &&

    echo 'cleaning up fixed.mkdup.bam...' &&
    rm $SAMPLE.\$READGROUP.bwa.fixed.mkdup.bam \
        $SAMPLE.\$READGROUP.bwa.fixed.mkdup.bai &&

    time java -Xmx7800m -Djava.io.tmpdir=$WORKDIR/tmp/ -jar $GATK \
        -T BaseRecalibrator \
        -nct 3 \
        -I $SAMPLE.\$READGROUP.bwa.realign.fixed.bam \
        -R $REF \
        -knownSites $DBSNP \
        -l INFO \
        -rf BadCigar \
        -cov ReadGroupCovariate \
        -cov QualityScoreCovariate \
        -cov CycleCovariate \
        -cov ContextCovariate \
        -o $SAMPLE.\$READGROUP.recal_data.grp &&

    time java -Xmx7800m -Djava.io.tmpdir=$WORKDIR/tmp/ -jar $GATK \
        -T PrintReads \
        -R $REF \
        -I $SAMPLE.\$READGROUP.bwa.realign.fixed.bam \
        -BQSR $SAMPLE.\$READGROUP.recal_data.grp \
        --disable_bam_indexing \
        -l INFO \
        -o $SAMPLE.\$READGROUP.bwa.recal.bam

done &&

echo 'cleaning up...' &&
for READGROUP in \`cat rglist\`
do
    rm $SAMPLE.\$READGROUP.bwa.realign.fixed.bam \
        $SAMPLE.\$READGROUP.bwa.realign.fixed.bai \
        $SAMPLE.\$READGROUP.bwa.fixed.bam \
        $SAMPLE.\$READGROUP.bwa.fixed.bam.bai
done" &&

#GATK_CMD="echo GATK_CMD"

GATK_Q=`$QUICK_Q -m 7800mb -d $NODE -t 3 -n gatk_${SAMPLE}_${NODE} -c " $GATK_CMD " -q $QUEUE -W depend=afterok:$SORT_Q` &&



# -----------------------
# STEP 6: Samtools calmd

CALMD_CMD="cd $WORKDIR &&
for READGROUP in \`cat rglist\`
do
    time $SAMTOOLS calmd -Erb $SAMPLE.\$READGROUP.bwa.recal.bam $REF > $SAMPLE.\$READGROUP.bwa.recal.bq.bam &&
    time $SAMTOOLS index $SAMPLE.\$READGROUP.bwa.recal.bq.bam
done && \

echo 'cleaning up...' &&
for READGROUP in \`cat rglist\`
do
    rm $SAMPLE.\$READGROUP.bwa.recal.bam
done" &&

#CALMD_CMD="echo calmd_cmd"

CALMD_Q=`$QUICK_Q -m 1gb -d $NODE -t 1 -n calmd_${SAMPLE}_${NODE} -c " $CALMD_CMD " -q $QUEUE -W depend=afterok:$GATK_Q` &&



# -----------------------
# STEP 7: Merging files
# Using Picard instead of samtools because it does a better job of preserving header information

# only merge if there are multiple readgroups
MERGE_CMD="
cd $WORKDIR &&
if [ \`cat rglist | wc -l\` -gt 1 ] ;
then
    INPUT_STRING='' &&
    for READGROUP in \`cat rglist\`
    do
        INPUT_STRING+=\" I=$SAMPLE.\$READGROUP.bwa.recal.bq.bam\"
    done &&

    time java -Xmx5900m -Djava.io.tmpdir=$WORKDIR/tmp/ -jar $PICARD/MergeSamFiles.jar \$INPUT_STRING O=$SAMPLE.bwa.merged.bam SO=coordinate ASSUME_SORTED=true CREATE_INDEX=true VALIDATION_STRINGENCY=SILENT &&

    for READGROUP in \`cat rglist\`
    do
        rm $SAMPLE.\$READGROUP.bwa.recal.bq.bam $SAMPLE.\$READGROUP.bwa.recal.bq.bam.bai
    done
else
    for READGROUP in \`head -n 1 rglist\`
    do
        mv $SAMPLE.\$READGROUP.bwa.recal.bq.bam $SAMPLE.bwa.bam &&
        mv $SAMPLE.\$READGROUP.bwa.recal.bq.bam.bai $SAMPLE.bwa.bai
    done
fi
" &&

#MERGE_CMD="echo merge_cmd command"

MERGE_Q=`$QUICK_Q -m 5900mb -d $NODE -t 3 -n merge_${SAMPLE}_${NODE} -c " $MERGE_CMD " -q $QUEUE -W depend=afterok:$CALMD_Q` &&


# -----------------------
# STEP 8: Mark duplicates again following the merge.

MKDUP2_CMD="
cd $WORKDIR &&
if [ \`cat rglist | wc -l\` -gt 1 ] ;
then
    time java -Xmx7900m -Djava.io.tmpdir=$WORKDIR/tmp/ -jar $PICARD/MarkDuplicates.jar INPUT=$SAMPLE.bwa.merged.bam OUTPUT=$SAMPLE.bwa.bam ASSUME_SORTED=TRUE METRICS_FILE=/dev/null VALIDATION_STRINGENCY=SILENT MAX_FILE_HANDLES=1000 CREATE_INDEX=true &&

    echo 'clean up files...' &&
    rm $SAMPLE.bwa.merged.bam $SAMPLE.bwa.merged.bai
fi
" &&

#MKDUP2_CMD="echo mkdup2 command"

MKDUP2_Q=`$QUICK_Q -m 7900mb -d $NODE -t 3 -n mkdup2_${SAMPLE}_${NODE} -c " $MKDUP2_CMD " -q $QUEUE -W depend=afterok:$MERGE_Q` &&


# -----------------------
# STEP 9: Reduce reads and move back to source

REDUCE_CMD="cd $WORKDIR &&
time java -Xmx9900m -Djava.io.tmpdir=$WORK_DIR/tmp/ -jar $GATK \
    -T ReduceReads \
    -R $REF \
    -I $SAMPLE.bwa.bam \
    -o $SAMPLE.bwa.reduced.bam &&

rsync -avPtL $SAMPLE.bwa.bam $SAMPLE.bwa.bai \
    $SAMPLE.bwa.reduced.bam $SAMPLE.bwa.reduced.bai \
    *.recal_data.grp \
    *.intervals \
    $OUTPUTROOT/$SAMPLE &&

echo 'removing scratch directory...' &&
rm -r $WORKDIR &&

echo $SAMPLE >> $OUTPUTROOT/$SAMPLE/../completed.txt" &&

#REDUCE_CMD="echo reduce command"

REDUCE_Q=`$QUICK_Q -m 9900mb -d $NODE -t 1 -n reduce_${SAMPLE}_${NODE} -c " $REDUCE_CMD " -q $QUEUE -M -u colby.chiang@gmail.com -W depend=afterok:$MKDUP2_Q`

done






