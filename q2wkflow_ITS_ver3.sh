#!/bin/bash
## Swift Biosciences ITS Qiime 2 workflow
## Author Benli Chai & Sukhinder Sandhu 20191009
## Remember to edit/set the parameters in config.txt file
## Run as q2wkflow_ITS.sh config.txt inputDir outputDir
## make sure output dir exists before running the pipeline
## This workflow treats paired-end as single reads or as paired-end reads.


set -e
set -x

if [ $# -ne 3 ]
    then
       echo "q2wkflow_ITS.sh config.txt inputDir workdir"
        exit
fi

script_dir=$(dirname $(readlink -f $0))
source $1  #read in configuration file
current_time=$(date "+%Y.%m.%d-%H.%M.%S")
echo "Starting time: "$current_time
inputDir=$(readlink -f $2)
WD=$(readlink -f $3) #work folder

runlog='log'
log=$runlog.$current_time

[ ! -d "$WD" ] && echo "Directory $WD does not exist, please create one..." && exit
cd ${WD}

mkdir Qobj #folder for all qiime2 data objects
mkdir Fastq #folder for intermediate fastq files
mkdir Export #folder to export qiime2 data object

echo "Primer file used: "$PRIMERS >> $log

## initiate the manifest file for importing to qiime2 upon completion of primer trimming the PE merging.
manifest=manifest.tsv
#printf "sample-id,absolute-filepath,direction\n" > $manifest
printf "sample-id\tabsolute-filepath\n" > $manifest
samplemeta=sampleMetadata.tsv #this is a sample metadata file, now is created to contain only sample IDs.  user should prepare sample metadata file in tsv format
printf "#SampleID\n" > $samplemeta

for R1 in ${inputDir}/*_R1*.fastq.gz; do #the input directory
    R2=${R1/_R1/_R2} #the path to the read 2 file
    echo $R1 >> $log
    echo $R2 >> $log
    echo

    basenameR1=${R1##*/}
    basenameR2=${R2##*/}
    prefixR1=${basenameR1%".fastq.gz"}
    prefixR2=${basenameR2%".fastq.gz"}
    trimmedR1=Fastq/${prefixR1}"_primerTrimmed.fastq"
    trimmedR2=Fastq/${prefixR2}"_primerTrimmed.fastq"
    untrimmedR1=Fastq/${prefixR1}"_primerNotFound.fastq" #won't go to downstream analysis
    untrimmedR2=Fastq/${prefixR2}"_primerNotFound.fastq" #won't go to downstream analysis
    prefix=${prefixR1%_L001_R1_*} #the sample name prefix of R1 and R2
    echo Processing ${prefix} ...

    #Trim primers off the PE reads
    echo
    echo Start primer trimming ...
    $CUTADAPT -e 0.10 -g file:$PRIMERS -G file:$PRIMERS \
              -o $trimmedR1 -p $trimmedR2  \
              --untrimmed-output $untrimmedR1 \
              --untrimmed-paired-output $untrimmedR2 \
              $R1 $R2 \
              --max-n 0 \
              --minimum-length $READLEN \
              >& log.${prefix}.cutadapt.txt

    #Prepare the manifest file for importing to QIIME2#
    trimmed=Qobj/${prefix}_swift_trimmed.fastq
    
    #Combine the trimmed R1 and R2 into a single file to be processed as single reads
    cat ${trimmedR1} ${trimmedR2} > ${trimmed}
    printf "${prefix}\t${trimmed}\n" >> $manifest
    printf "${prefix}\n" >> $samplemeta

done
	
### Import fastq files containing PE merged and not merged read as single read file to QIIME2 ####
     #for importing paired-end merged or combined 
     qiime tools import \
       	     --type 'SampleData[SequencesWithQuality]'  \
	     --input-path manifest.tsv  \
    	     --output-path Qobj/swift_single.qza \
	     --input-format SingleEndFastqManifestPhred33V2

     qiime demux summarize \
	     --i-data Qobj/swift_single.qza \
             --o-visualization Qobj/swift_single_qual.qzv

     ## Use dada2 to denoise, call ASVs, and remove chimeras 
     qiime dada2 denoise-single \
             --i-demultiplexed-seqs Qobj/swift_single.qza \
             --o-table Qobj/swift_single_dada2_ft \
             --o-representative-sequences Qobj/swift_single_dada2_rep \
             --p-trunc-len 0 \
             --o-denoising-stats Qobj/swift_single_dada2_stats

## classify in both forward and reverse-complement orientations since the sklearn classifier does not recognize each sequence based on their strandness 
for strand in same reverse-complement; do
  qiime feature-classifier classify-sklearn \
        --i-classifier $CLASSIFIER \
        --i-reads Qobj/swift_single_dada2_rep.qza \
        --p-confidence 0.7 \
        --o-classification Qobj/swift_single_dada2_rep_taxonomy_${strand} \
	--p-read-orientation $strand 

  qiime tools export \
	     --input-path Qobj/swift_single_dada2_rep_taxonomy_${strand}.qza \
	     --output-path . 
		
  mv taxonomy.tsv taxonomy_${strand}.tsv

done

## Choose the better resolving lineage from two strand classification
${script_dir}/mergeStrand_taxonomy.py \
	taxonomy_same.tsv \
	taxonomy_reverse-complement.tsv > \
	swift_single_dada2_rep_taxonomy.tsv

## import the merged taxonomy back to Qobj
   qiime tools import \
        --type FeatureData[Taxonomy] \
        --input-path swift_single_dada2_rep_taxonomy.tsv \
        --output-path Qobj/swift_single_dada2_rep_taxonomy.qza
 
     ## make barplot
   qiime taxa barplot \
        --i-table Qobj/swift_single_dada2_ft.qza\
        --i-taxonomy Qobj/swift_single_dada2_rep_taxonomy.qza \
        --o-visualization Qobj/swift_single_dada2_barplot \
        --m-metadata-file $samplemeta

     ## Collapse ASV-based feature table by taxonomy
   qiime taxa collapse \
        --i-table Qobj/swift_single_dada2_ft.qza \
        --i-taxonomy Qobj/swift_single_dada2_rep_taxonomy.qza \
        --o-collapsed-table Qobj/swift_single_dada2_ft_collapsed.qza \
        --p-level 7
 
     ## Export the feature table
     qiime tools export \
             --input-path Qobj/swift_single_dada2_ft_collapsed.qza \
             --output-path Export

     ## Enter Export folder
       cd Export

     ## Convert feature table from biom format to tsv format
	biom convert \
             --to-tsv \
             --input-fp feature-table.biom \
             --output-fp feature-table_ITS.tsv
