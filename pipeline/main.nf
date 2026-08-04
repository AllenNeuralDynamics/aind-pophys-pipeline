#!/usr/bin/env nextflow

nextflow.enable.dsl = 2

import groovy.json.JsonSlurper

params.ophys_mount_url = 's3://aind-open-data/multiplane-ophys_839909_2026-02-26_15-11-01'

// saveAs is invoked once per MATCH of each output glob, so a process declaring
// 'capsule/results/*' gets one call per plane directory AND one per file sitting
// at that level. Keeping the relative path means an artifact published from a
// nested glob lands at <plane>/<step>/..., and a directory match publishes its
// subtree there.
CAPSULE_RESULTS = 'capsule/results/'
RUN_LEVEL_DOCS = ['processing.json', 'quality_control.json']

publishRelative = { String filename ->
    filename.startsWith(CAPSULE_RESULTS)
        ? filename.substring(CAPSULE_RESULTS.length())
        : filename
}

// For a capsule that writes its own processing.json / quality_control.json at
// the TOP of capsule/results/ rather than under <plane>/<step>/. Those would
// publish to the results ROOT, which is where the aggregator writes the
// run-level pair -- two tasks, one target, last writer wins. Skipping the
// publish costs nothing: the documents still travel on their emit channels into
// the aggregator, which is what actually produces the run-level pair. Only the
// converter needs this today (verified 2026-08-04 from runs b462ae9b and
// 2368efda, whose root processing.json held the converter's single
// "Raw movie conversion to HDF5" process while the aggregator had not run).
publishRelativeSkipRunLevel = { String filename ->
    def rel = publishRelative(filename)
    rel in RUN_LEVEL_DOCS ? null : rel
}

workflow {
    // Parameterized data source selection
    def use_s3_source = params.containsKey('ophys_mount_url')
    
    // Declare all variables outside conditional blocks
    def ophys_data = Channel.empty()
    def ophys_mount_jsons = Channel.empty()
    def ophys_mount_pophys_directory = Channel.empty()
    def z_stacks = Channel.empty()
    def vasculature_dir = Channel.empty()
    def matched_tiff_vals_dir = Channel.empty()
    
    // Print all parameters at startup
    println "\n--- Pipeline Parameters ---"
    params.keySet().sort().each { key ->
        println "PARAM: ${key} = ${params[key]}"
    }
    println "--- End Parameters ---\n"
    
    def base_path = "${projectDir}/../data/"
    def parameter_json = file("${base_path}pipeline_parameters.json")

    if (parameter_json.exists()) {
        def jsonSlurper = new JsonSlurper()
        def configData = jsonSlurper.parse(parameter_json)
        
        // Add each key-value pair from JSON to params
        configData.each { key, value ->
            params[key] = value
            println "Added params.${key} = ${value}"
        }
    }
    // Data source setup
    if (use_s3_source) {
        ophys_data = Channel.fromPath(params.ophys_mount_url, type: 'any')
        ophys_mount_jsons = Channel.fromPath("${params.ophys_mount_url}/*.json", type: 'any')
        ophys_mount_pophys_directory = Channel.fromPath("${params.ophys_mount_url}/pophys", type: 'dir')
    } else {
        
        ophys_data = Channel.fromPath("${base_path}harvard-single", type: 'dir')
        ophys_mount_jsons = Channel.fromPath("${base_path}harvard-single/*.json", type: 'any')
        ophys_mount_pophys_directory = Channel.fromPath("${base_path}harvard-single/pophys", type: 'dir')
    }
    
    def nwb_schemas = Channel.fromPath("${base_path}schemas/*", type: 'any', checkIfExists: true)
    def classifier_data = Channel.fromPath("${base_path}2p_roi_classifier/*", type: 'any', checkIfExists: true)
    
    // Set ophys_mount_sync_file - look for .h5 files in behavior subdirectory when using ophys_mount_url
    def ophys_mount_sync_file = params.ophys_mount_url ? 
        Channel.fromPath("${params.ophys_mount_url}/behavior/*.h5", type: 'any', checkIfExists: false) :
        Channel.empty()
    
    // Debug: Check for all files in the behavior directory (only when using ophys_mount_url)
    def all_behavior_files = params.ophys_mount_url ? 
        Channel.fromPath("${params.ophys_mount_url}/behavior/*", type: 'any', checkIfExists: false) :
        Channel.empty()

    // Initialize channels for multiplane-specific processes
    def decrosstalk_processing_json = Channel.empty()
    def decrosstalk_qc_json = Channel.empty()
    def decrosstalk_results_all = Channel.empty()

    // Only produced when the converter runs (S3 sources only).
    def converter_processing_json = Channel.empty()
    def converter_qc_json = Channel.empty()
    
    // Conditional converter execution - only run for S3 sources
    def motion_correction_input
    if (use_s3_source) {
        converter_capsule(ophys_data)

        converter_processing_json = converter_capsule.out.converter_processing_json
        converter_qc_json = converter_capsule.out.converter_qc_json
        
        // Separate the directories we want to filter out
        converter_capsule.out.converter_results
            .flatten()
            .filter { it.isDirectory() }
            .branch {
                vasculature: it.name == 'vasculature'
                matched_tiff_vals: it.name == 'matched_tiff_vals'
                other: true
            }
            .set { converter_split }
        
        // Use the 'other' branch which already excludes vasculature and matched_tiff_vals
        motion_correction_input = converter_split.other
        vasculature_dir = converter_split.vasculature
        matched_tiff_vals_dir = converter_split.matched_tiff_vals   
    } else {
        motion_correction_input = ophys_data
    }

    if (params.acquisition_data_type == "multiplane"){
        // Run motion correction for multiplane
        motion_correction(
            motion_correction_input.flatten(),
            ophys_mount_jsons.collect(),
            ophys_mount_pophys_directory.collect(),
        )
        z_stacks = converter_capsule.out.local_stacks

        movie_qc(
            motion_correction.out.motion_results_all.flatten(),
            ophys_mount_jsons.collect(),
            z_stacks.collect().ifEmpty([])
        )

        // Split the motion-corrected planes into pairs for decrosstalk
        decrosstalk_split_json(
            motion_correction.out.motion_results_all.collect(),
            ophys_mount_jsons.collect()
        )

        // Remove paired-plane crosstalk. Restored now that the capsule is
        // v2-upgraded: extraction prefers *decrosstalk.h5 over *registered.h5,
        // so while this was bypassed multiplane extraction ran on the wrong
        // input and everything downstream of it inherited that.
        decrosstalk_roi_images(
            decrosstalk_split_json.out.capsule_results.flatten(),
            ophys_mount_jsons.collect(),
            ophys_mount_pophys_directory.collect(),
            motion_correction.out.motion_results_all.collect(),
            use_s3_source ? converter_capsule.out.converter_results_all.collect() : Channel.empty().collect()
        )

        decrosstalk_processing_json = decrosstalk_roi_images.out.decrosstalk_processing_json
        decrosstalk_qc_json = decrosstalk_roi_images.out.decrosstalk_qc_json
        decrosstalk_results_all = decrosstalk_roi_images.out.decrosstalk_results_all

        extraction(
            decrosstalk_roi_images.out.capsule_results.flatten(),
            ophys_mount_jsons.collect()
        )

    } else {
        // Run motion correction for single plane
        motion_correction(
            motion_correction_input.collect(),
            ophys_mount_jsons.collect(),
            ophys_mount_pophys_directory.collect()
        )

        movie_qc(
            motion_correction.out.motion_results_all.flatten(),
            ophys_mount_jsons.collect(),
            z_stacks.collect().ifEmpty([])
        )

        extraction(
            motion_correction.out.motion_results_all.collect(),
            ophys_mount_jsons.collect()
        )
    }

    // Run DF / F. Independent of the classifier, so it runs while the
    // classifier is still on v1.
    if (params.acquisition_data_type == "multiplane"){
        dff_capsule(
            extraction.out.capsule_results.flatten(),
            ophys_mount_jsons.collect(),
            // motion_correction.out.motion_results_csv.collect()
        )
    } else {
        dff_capsule(
            extraction.out.capsule_results.collect(),
            ophys_mount_jsons.collect(),
            // motion_correction.out.motion_results_csv.collect()
        )
    }

    // Run classification
    classifier(
        ophys_mount_jsons.collect(),
        classifier_data.collect(),
        extraction.out.capsule_results.flatten(),
    )

    if (params.acquisition_data_type == "multiplane"){
        // Run Oasis Event detection
        oasis_event_detection(
            dff_capsule.out.capsule_results.flatten(),
            ophys_mount_jsons.collect()
        )
    } else {
        // Run Oasis Event detection
        oasis_event_detection(
            dff_capsule.out.capsule_results.collect(),
            ophys_mount_jsons.collect()
        )
    }

    // Run Ophys NWB Packaging for Multiplane
    //
    // The three per-step channels below glob <plane>/<step>/*, which under v2
    // sweeps up the bare processing.json / quality_control.json those steps now
    // write. Collected across 8 planes that is 8 files per name into one path
    // input, which Nextflow rejects outright:
    //   "input file name collision -- There are multiple input files for each
    //    of the following file names: processing.json, quality_control.json"
    // Under v1 the same globs were safe because every file was <plane>_-prefixed.
    // nwb never reads them -- it rglobs for <plane>_*<part>, epoch_locations.json
    // and the sync h5 -- so they are dropped rather than staged into numbered
    // directories the way the aggregator needs.
    //
    // .flatten() is load-bearing. A `path` output whose glob matches several
    // files emits ONE List per task, not one item per file, so a bare
    // .filter { it.name in ... } tests a List: Groovy's GPath turns List.name
    // into a list OF names, which is never `in` a list of strings, so the
    // predicate is always true and the filter silently passes everything.
    // That cost a full run. flatten() first, then filter, then re-collect.
    def metadata_json = ['processing.json', 'quality_control.json']
    ophys_nwb(
        nwb_schemas.collect(),
        ophys_mount_jsons.collect(),
        ophys_mount_sync_file.collect().ifEmpty([]),
        ophys_mount_pophys_directory.collect(),
        motion_correction.out.motion_results.flatten().filter { !(it.name in metadata_json) }.collect(),
        decrosstalk_results_all.flatten().filter { !(it.name in metadata_json) }.collect().ifEmpty([]),
        extraction.out.extraction_results_all.flatten().filter { !(it.name in metadata_json) }.collect(),
        classifier.out.classifer_h5.collect(),
        dff_capsule.out.dff_results_all.collect(),
        oasis_event_detection.out.events_h5.collect()
    )   

    // Aggregate every capsule's v2 metadata into the run-level
    // processing.json / quality_control.json.
    //
    // quality_control_aggregator is gone: v2 deletes QCEvaluation, so that
    // capsule is unbuildable, and aind-metadata-manager >=0.3.1 does the same
    // job behind --aggregate_quality_control.
    //
    // Every capsule writes bare processing.json / quality_control.json --
    // write_standard_file() hardcodes those names -- so on a multiplane run
    // each per-plane channel carries N identically-named files. Mixing them
    // into two channels keeps this call short; the stageAs on the aggregator's
    // inputs is what actually prevents Nextflow rejecting the task for
    // duplicate input file names.
    //
    // The trailing .flatten() normalises the mix. Most of these emit one bare
    // path per task, but decrosstalk handles a PAIR per task, so its depth-2
    // globs match twice and it emits a List -- mixing the two shapes would
    // hand stageAs a nested collection to number.
    def all_processing_json = converter_processing_json
        .mix(motion_correction.out.motion_processing_json)
        .mix(movie_qc.out.movie_qc_processing_json)
        .mix(decrosstalk_processing_json)
        .mix(extraction.out.extraction_processing_json)
        .mix(dff_capsule.out.dff_processing_json)
        .mix(classifier.out.classifier_processing_json)
        .mix(oasis_event_detection.out.oasis_processing_json)
        .mix(ophys_nwb.out.nwb_processing_json)
        .flatten()

    def all_quality_control_json = converter_qc_json
        .mix(motion_correction.out.motion_qc_json)
        .mix(movie_qc.out.movie_qc_qc_json)
        .mix(decrosstalk_qc_json)
        .mix(extraction.out.extraction_qc_json)
        .mix(dff_capsule.out.dff_qc_json)
        .mix(classifier.out.classifier_qc_json)
        .mix(oasis_event_detection.out.oasis_qc_json)
        .mix(ophys_nwb.out.nwb_qc_json)
        .flatten()

    // ifEmpty([]) so an all-empty channel still runs the aggregator. Without
    // it collect() emits nothing, the process is silently skipped, and the run
    // "succeeds" with no run-level processing.json at all. With it, the
    // aggregator runs and raises on zero metrics -- a loud failure beats a
    // missing document.
    pipeline_processing_metadata_aggregator(
        ophys_mount_jsons.collect(),
        all_processing_json.collect().ifEmpty([]),
        all_quality_control_json.collect().ifEmpty([])
    )
}


// Process: aind-pophys-converter-capsule
process converter_capsule {
    tag 'capsule-9191145'
	container "$REGISTRY_HOST/capsule/ba2e9806-5561-4853-90ba-1bc269b42ff6:c69311411b5aa698661bdf928802df54"
    publishDir "$RESULTS_PATH", saveAs: publishRelativeSkipRunLevel

    cpus 16
    memory '128 GB'

    input:
    path ophys_mount, name: 'capsule/data'

    output:
    path 'capsule/results/*', optional: true
    path 'capsule/results/*', emit: 'converter_results', optional: true
    path 'capsule/results/*/*', emit: 'converter_results_all', optional: true
    path 'capsule/results/*/*local*', emit: 'local_stacks', optional: true
    path 'capsule/results/processing.json', emit: 'converter_processing_json', optional: true
    path 'capsule/results/quality_control.json', emit: 'converter_qc_json', optional: true

    script:
    """
    #!/usr/bin/env bash
    set -e

    export CO_CAPSULE_ID=ba2e9806-5561-4853-90ba-1bc269b42ff6
    export CO_CPUS=16
    export CO_MEMORY=137438953472

    mkdir -p capsule
    mkdir -p capsule/data && ln -s \$PWD/capsule/data /data
    mkdir -p capsule/results && ln -s \$PWD/capsule/results /results
    mkdir -p capsule/scratch && ln -s \$PWD/capsule/scratch /scratch

    echo "[${task.tag}] cloning git repo..."
    git clone "https://\$GIT_ACCESS_TOKEN@\$GIT_HOST/capsule-9191145.git" capsule-repo
    git -C capsule-repo checkout 9689ac9 --quiet
    mv capsule-repo/code capsule/code
	rm -rf capsule-repo

    echo "[${task.tag}] running capsule..."
    echo "Processing: \$(basename $ophys_mount)"
    cd capsule/code
    chmod +x run
    echo "converter_capsule parameters: --debug ${params.debug} --input_dir ${params.input_dir} --output_dir ${params.output_dir} --temp_dir ${params.temp_dir}"
    ./run --debug ${params.debug} --input_dir ${params.input_dir} --output_dir ${params.output_dir} --temp_dir ${params.temp_dir}
    echo "[${task.tag}] completed!"
    ls -a /results
    """
}

// capsule - aind-ophys-motion-correction multiplane
process motion_correction {
    tag 'capsule-2071646'
	container "$REGISTRY_HOST/capsule/86b66e08-c26e-4d08-a904-80406e041479:6c6d71cbe34c717f70ad0ce55cccdc27"
    publishDir "$RESULTS_PATH", saveAs: publishRelative

    cpus 16
    memory '128 GB'

    input:
    path ophys_mount
    path ophys_jsons
    path pophys_dir

    output:
    path 'capsule/results/*', emit: 'motion_results_all', type: 'dir'
    path 'capsule/results/*/motion_correction/*transform.csv', emit: 'motion_results_csv'
    path 'capsule/results/*/*/processing.json', emit: 'motion_processing_json'
    path 'capsule/results/*/*/quality_control.json', emit: 'motion_qc_json', optional: true
    path 'capsule/results/*/motion_correction/*', emit: 'motion_results'

    script:
    """
    #!/usr/bin/env bash
    set -e

    export CO_CAPSULE_ID=86b66e08-c26e-4d08-a904-80406e041479
    export CO_CPUS=16
    export CO_MEMORY=137438953472
    
    mkdir -p capsule
    mkdir -p capsule/data && ln -s \$PWD/capsule/data /data
    mkdir -p capsule/results && ln -s \$PWD/capsule/results /results
    mkdir -p capsule/scratch && ln -s \$PWD/capsule/scratch /scratch

    echo "[${task.tag}] copying data to capsule..."
    cp -r ${ophys_mount} capsule/data
    cp -r ${ophys_jsons} capsule/data
    cp -r ${pophys_dir} capsule/data

    echo "[${task.tag}] cloning git repo..."
    git clone "https://\$GIT_ACCESS_TOKEN@\$GIT_HOST/capsule-2071646.git" capsule-repo
    git -C capsule-repo checkout 3b43db3 --quiet
    mv capsule-repo/code capsule/code
    rm -rf capsule-repo
    
    echo "[${task.tag}] running capsule..."
    cd capsule/code
    chmod +x run
    echo "motion_correction parameters: --do_registration ${params.do_registration} --data_type ${params.data_type} --batch_size ${params.batch_size} --maxregshift ${params.maxregshift} --maxregshiftNR ${params.maxregshiftNR} --align_by_chan ${params.align_by_chan} --smooth_sigma_time ${params.smooth_sigma_time} --smooth_sigma ${params.smooth_sigma} --nonrigid ${params.nonrigid} --snr_thresh ${params.snr_thresh} --debug ${params.debug}"
    ./run --do_registration ${params.do_registration} --data_type ${params.data_type} --batch_size ${params.batch_size} --maxregshift ${params.maxregshift} --maxregshiftNR ${params.maxregshiftNR} --align_by_chan ${params.align_by_chan} --smooth_sigma_time ${params.smooth_sigma_time} --smooth_sigma ${params.smooth_sigma} --nonrigid ${params.nonrigid} --snr_thresh ${params.snr_thresh} --debug ${params.debug}
    
    echo "[${task.tag}] completed!"
    """
}

// capsule - aind-ophys-movie-qc
process movie_qc {
	tag 'capsule-5974042'
	container "$REGISTRY_HOST/capsule/1e1ee66e-db39-4cc8-b760-08ed26f0c9e8:38b6fda9b131bbdf516706319abda1c5"
    publishDir "$RESULTS_PATH", saveAs: publishRelative

	cpus 16
	memory '128 GB'


	input:
	path motion_results
    path ophys_jsons
    path zstacks

	output:
	path 'capsule/results/*'
	path 'capsule/results/*/*/processing.json', emit: 'movie_qc_processing_json', optional: true
	path 'capsule/results/*/*/quality_control.json', emit: 'movie_qc_qc_json', optional: true
	path 'capsule/results/*/*/*.png', emit: 'movie_qc_png'

	script:
	"""
	#!/usr/bin/env bash
	set -e

	export CO_CPUS=16
	export CO_MEMORY=137438953472

	mkdir -p capsule
    mkdir -p capsule/data && ln -s \$PWD/capsule/data /data
	mkdir -p capsule/data/raw && ln -s \$PWD/capsule/data/raw /raw
    mkdir -p capsule/data/zstacks && ln -s \$PWD/capsule/data/zstacks /zstacks
	mkdir -p capsule/results && ln -s \$PWD/capsule/results /results
	mkdir -p capsule/scratch && ln -s \$PWD/capsule/scratch /scratch

    echo "[${task.tag}] copying data to capsule..."
    cp -r ${motion_results} capsule/data
    cp -r ${ophys_jsons} capsule/data/raw
    if [ -n "${zstacks}" ] && [ "${zstacks}" != "[]" ]; then
        cp -r ${zstacks} capsule/data/zstacks
    fi

	echo "[${task.tag}] cloning git repo..."
	git clone "https://\$GIT_ACCESS_TOKEN@\$GIT_HOST/capsule-5974042.git" capsule-repo
	git -C capsule-repo checkout 87e2229 --quiet
	mv capsule-repo/code capsule/code
	rm -rf capsule-repo

    echo "[${task.tag}] running capsule..."
    cd capsule/code
    chmod +x run
    ./run --verify 1

    echo "[${task.tag}] completed!"
    """
}

// capsule - aind-ophys-decrosstalk-split-session-json
process decrosstalk_split_json {
    tag 'capsule-4425001'
    container "$REGISTRY_HOST/published/fc1b1e9a-fb4b-47e8-a223-b06d8eeb1462:v1"

    cpus 2
    memory '16 GB'

    publishDir "$RESULTS_PATH", saveAs: publishRelative

    input:
    path motion_results
    path ophys_jsons

    output:
    path 'capsule/results/*', emit: 'capsule_results'
    
    script:
    """
    #!/usr/bin/env bash
    set -e

    export CO_CAPSULE_ID=fc1b1e9a-fb4b-47e8-a223-b06d8eeb1462
    export CO_CPUS=2
    export CO_MEMORY=17179869184

    mkdir -p capsule
    mkdir -p capsule/data && ln -s \$PWD/capsule/data /data
    mkdir -p capsule/results && ln -s \$PWD/capsule/results /results
    mkdir -p capsule/scratch && ln -s \$PWD/capsule/scratch /scratch

    echo "[${task.tag}] copying data to capsule..."
    cp -r ${motion_results} capsule/data
    cp -r ${ophys_jsons} capsule/data

    echo "[${task.tag}] cloning git repo..."
    git clone --branch v1.0 "https://\$GIT_ACCESS_TOKEN@\$GIT_HOST/capsule-4425001.git" capsule-repo
    mv capsule-repo/code capsule/code
    rm -rf capsule-repo

    echo "[${task.tag}] running capsule..."
    cd capsule/code
    chmod +x run
    ./run

    echo "[${task.tag}] completed!"
    """
}

// capsule - aind-ophys-decrosstalk-roi-images
process decrosstalk_roi_images {
    tag 'capsule-4886340'
    // DEV pin: the registry hash goes stale on every capsule rebuild.
	container "$REGISTRY_HOST/capsule/38507fd5-eb29-4b40-9474-28448305e619:c41d3d3c2f1a63a82af2df6d0cc850a4"

    cpus 8
    memory '64 GB'

    publishDir "$RESULTS_PATH", saveAs: publishRelative

    input:
    path decrosstalk_split
    path ophys_jsons
    path pophys_dir
    path motion_results
    path converter_files

    output:
    path 'capsule/results/*', emit: 'capsule_results'
    path 'capsule/results/*/*/processing.json', emit: 'decrosstalk_processing_json', optional: true
    path 'capsule/results/*/*/quality_control.json', emit: 'decrosstalk_qc_json', optional: true
    path 'capsule/results/*/decrosstalk/*', emit: 'decrosstalk_results_all'
    
    script:
    """
    #!/usr/bin/env bash
    set -e

    export CO_CAPSULE_ID=38507fd5-eb29-4b40-9474-28448305e619
    export CO_CPUS=8
    export CO_MEMORY=68719476736

    mkdir -p capsule
    mkdir -p capsule/data && ln -s \$PWD/capsule/data /data
    mkdir -p capsule/results && ln -s \$PWD/capsule/results /results
    mkdir -p capsule/scratch && ln -s \$PWD/capsule/scratch /scratch

    echo "[${task.tag}] copying data to capsule..."
    cp -r ${decrosstalk_split} capsule/data
    cp -r ${ophys_jsons} capsule/data
    cp -r ${pophys_dir} capsule/data
    cp -r ${motion_results} capsule/data
    cp -r ${converter_files} capsule/data

    echo "[${task.tag}] cloning git repo..."
    if [[ "\$(printf '%s\n' "2.20.0" "\$(git version | awk '{print \$3}')" | sort -V | head -n1)" = "2.20.0" ]]; then
		git clone "https://\$GIT_ACCESS_TOKEN@\$GIT_HOST/capsule-4886340.git" capsule-repo
        git -C capsule-repo checkout 8f3ac28 --quiet
	else
		git clone "https://\$GIT_ACCESS_TOKEN@\$GIT_HOST/capsule-4886340.git" capsule-repo
        git -C capsule-repo checkout 8f3ac28 --quiet
	fi
    mv capsule-repo/code capsule/code
    rm -rf capsule-repo

    echo "[${task.tag}] running capsule..."
    cd capsule/code
    chmod +x run
    ./run --debug ${params.debug} --verify 1

    echo "[${task.tag}] completed!"
    """
}


// capsule - aind-ophys-extraction
process extraction {
    tag 'capsule-8797010'
	container "$REGISTRY_HOST/capsule/1ba6e32d-2a8a-4084-a449-2878724fb15d:f67939617ea77ac06fb014f568178153"

    cpus 8
    memory '64 GB'

    publishDir "$RESULTS_PATH", saveAs: publishRelative

    input:
    path extraction_input
    path ophys_jsons

    output:
    path 'capsule/results/*', emit: 'capsule_results'
    path 'capsule/results/*/*/processing.json', emit: 'extraction_processing_json', optional: true
    path 'capsule/results/*/*/quality_control.json', emit: 'extraction_qc_json', optional: true
    path 'capsule/results/*/extraction/*', emit: 'extraction_results_all'


    script:
    def suite2p_params_arg = params.containsKey('suite2p_params') && params.suite2p_params ? "--suite2p_params '${params.suite2p_params}'" : ""
    def suite2p_ops_arg = params.containsKey('suite2p_ops') && params.suite2p_ops ? "--suite2p_ops ${params.suite2p_ops}" : ""
    """
    #!/usr/bin/env bash
    set -e

    export CO_CAPSULE_ID=1ba6e32d-2a8a-4084-a449-2878724fb15d
    export CO_CPUS=8
    export CO_MEMORY=68719476736

    mkdir -p capsule
    mkdir -p capsule/data && ln -s \$PWD/capsule/data /data
    mkdir -p capsule/results && ln -s \$PWD/capsule/results /results
    mkdir -p capsule/scratch && ln -s \$PWD/capsule/scratch /scratch

    echo "[${task.tag}] copying data to capsule..."
    cp -r ${extraction_input} capsule/data
    cp -r ${ophys_jsons} capsule/data

    echo "[${task.tag}] cloning git repo..."
    git clone "https://\$GIT_ACCESS_TOKEN@\$GIT_HOST/capsule-8797010.git" capsule-repo
    git -C capsule-repo checkout 830ea13 --quiet
    mv capsule-repo/code capsule/code
    rm -rf capsule-repo

    echo "[${task.tag}] running capsule..."
    cd capsule/code
    chmod +x run
    echo "extraction parameters: --diameter ${params.diameter} --cellprob_threshold ${params.cellprob_threshold} --init ${params.init} --functional_chan ${params.functional_chan} --threshold_scaling ${params.threshold_scaling} --max_overlap ${params.max_overlap} --soma_crop ${params.soma_crop} --allow_overlap ${params.allow_overlap}"
    ./run --diameter ${params.diameter} --cellprob_threshold ${params.cellprob_threshold} --init ${params.init} --functional_chan ${params.functional_chan} --threshold_scaling ${params.threshold_scaling} --max_overlap ${params.max_overlap} --soma_crop ${params.soma_crop} --allow_overlap ${params.allow_overlap} ${suite2p_params_arg} ${suite2p_ops_arg} --verify 1

    echo "[${task.tag}] completed!"
    """
}

// capsule - aind-ophys-dff
process dff_capsule {
    tag 'capsule-7970481'
    // DEV pin: the registry hash goes stale on every capsule rebuild.
	container "$REGISTRY_HOST/capsule/909d4275-fc32-4b81-a3f3-f5bf6cedece1:6056c484354ca6d514ceb4383b1d1159"

    cpus 4
    memory '32 GB'

    publishDir "$RESULTS_PATH", saveAs: publishRelative

    input:
    path extraction_results
    path ophys_mount_json
    // path motion_correction_results

    output:
    path 'capsule/results/*', emit: 'capsule_results'
    path 'capsule/results/*/*/processing.json', emit: 'dff_processing_json', optional: true
    path 'capsule/results/*/*/quality_control.json', emit: 'dff_qc_json', optional: true
    path 'capsule/results/*/dff/*.h5', emit: 'dff_results_all'

    script:
    """
    #!/usr/bin/env bash
    set -e

    export CO_CAPSULE_ID=909d4275-fc32-4b81-a3f3-f5bf6cedece1
    export CO_CPUS=4
    export CO_MEMORY=34359738368

    mkdir -p capsule
    mkdir -p capsule/data && ln -s \$PWD/capsule/data /data
    mkdir -p capsule/results && ln -s \$PWD/capsule/results /results
    mkdir -p capsule/scratch && ln -s \$PWD/capsule/scratch /scratch

    echo "[${task.tag}] copying data to capsule..."
    cp -r ${ophys_mount_json} capsule/data
    cp -r ${extraction_results} capsule/data

    echo "[${task.tag}] cloning git repo..."
    git clone "https://\$GIT_ACCESS_TOKEN@\$GIT_HOST/capsule-7970481.git" capsule-repo
    git -C capsule-repo checkout c80519f --quiet
    mv capsule-repo/code capsule/code
    rm -rf capsule-repo

    echo "[${task.tag}] running capsule..."
    cd capsule/code
    chmod +x run
    echo "dff_capsule parameters: --method ${params.method} --long_window ${params.long_window} --short_window ${params.short_window} --inactive_percentile ${params.inactive_percentile} --noise_method ${params.noise_method} --sigma_anneal_steps ${params.sigma_anneal_steps} --triexp_config_overrides '${params.triexp_config_overrides}'"
    ./run --method ${params.method} --long_window ${params.long_window} --short_window ${params.short_window} --inactive_percentile ${params.inactive_percentile} --noise_method ${params.noise_method} --sigma_anneal_steps ${params.sigma_anneal_steps} --triexp_config_overrides '${params.triexp_config_overrides}' --verify 1

    echo "[${task.tag}] completed!"
    """
}

// capsule - aind-ophys-oasis-event-detection
process oasis_event_detection {
    tag 'capsule-3856982'
	container "$REGISTRY_HOST/capsule/7b66080e-50f4-4c27-8345-86248812b00f:d9479e70906b327cd51957ca1e6a6ae5"

    cpus 4
    memory '32 GB'

    publishDir "$RESULTS_PATH", saveAs: publishRelative

    input:
    path dff_results
    path ophys_jsons

    output:
    path 'capsule/results/*'
    path 'capsule/results/*/*/plots/*', emit: 'event_qc_png', optional: true
    path 'capsule/results/*/*/processing.json', emit: 'oasis_processing_json', optional: true
    path 'capsule/results/*/*/quality_control.json', emit: 'oasis_qc_json', optional: true
    path 'capsule/results/*/events/*.h5', emit: 'events_h5'

    script:
    """
    #!/usr/bin/env bash
    set -e

    export CO_CAPSULE_ID=7b66080e-50f4-4c27-8345-86248812b00f
    export CO_CPUS=4
    export CO_MEMORY=34359738368

    mkdir -p capsule
    mkdir -p capsule/data && ln -s \$PWD/capsule/data /data
    mkdir -p capsule/results && ln -s \$PWD/capsule/results /results
    mkdir -p capsule/scratch && ln -s \$PWD/capsule/scratch /scratch

    echo "[${task.tag}] copying data to capsule..."
    cp -r ${ophys_jsons} capsule/data
    cp -r ${dff_results} capsule/data

    echo "[${task.tag}] cloning git repo..."
    git clone "https://\$GIT_ACCESS_TOKEN@\$GIT_HOST/capsule-3856982.git" capsule-repo
    git -C capsule-repo checkout 79d9a25 --quiet
	mv capsule-repo/code capsule/code
    rm -rf capsule-repo

    echo "[${task.tag}] running capsule..."
    cd capsule/code
    chmod +x run
    ./run --verify 1

    echo "[${task.tag}] completed!"
    """
}

// capsule - aind-ophys-classifier
process classifier {
	tag 'capsule-2013356'
	container "$REGISTRY_HOST/capsule/570e9cb2-be0f-4972-ad49-90b3fe8ab690:df9afb564627f3caab82fa3948d8fad4"

	cpus 16
	memory '60 GB'
	accelerator 1
	label 'gpu'

	publishDir "$RESULTS_PATH", saveAs: publishRelative

	input:
    path ophys_mount_jsons
	path classifier_data
	path extraction_results
    
	output:
	path 'capsule/results/*/*/processing.json', emit: 'classifier_processing_json', optional: true
	path 'capsule/results/*/*/quality_control.json', emit: 'classifier_qc_json', optional: true
    path 'capsule/results/*/classification/*classification.h5', emit: 'classifer_h5'
	path 'capsule/results/*/*/*.png', emit: 'classifier_png'
	path 'capsule/results/*'

	script:
	def model_name_arg = params.containsKey('model-name') && params['model-name'] ? "--model_name ${params['model-name']}" : ""
	"""
	#!/usr/bin/env bash
	set -e

	export CO_CAPSULE_ID=570e9cb2-be0f-4972-ad49-90b3fe8ab690
	export CO_CPUS=16
	export CO_MEMORY=64424509440

	mkdir -p capsule
	mkdir -p capsule/data && ln -s \$PWD/capsule/data /data
	mkdir -p capsule/results && ln -s \$PWD/capsule/results /results
	mkdir -p capsule/scratch && ln -s \$PWD/capsule/scratch /scratch

    echo "[${task.tag}] copying data to capsule..."
    cp -r ${ophys_mount_jsons} capsule/data
    cp -r ${classifier_data} capsule/data
    cp -r ${extraction_results} capsule/data

	ln -s "/tmp/data/2p_roi_classifier" "capsule/data/2p_roi_classifier" # id: 57a10c5f-468f-4bb2-b3c6-7f4a80efa8ae

	echo "[${task.tag}] cloning git repo..."
	git clone "https://\$GIT_ACCESS_TOKEN@\$GIT_HOST/capsule-2013356.git" capsule-repo
	git -C capsule-repo checkout bc1ab41 --quiet
	mv capsule-repo/code capsule/code
	rm -rf capsule-repo

	echo "[${task.tag}] running capsule..."
	cd capsule/code
	chmod +x run
	./run --input_dir ${params.input_dir} --output_dir ${params.output_dir} --tmp_dir ${params.temp_dir} --soma_classifier_path ${params['soma-classifier-path']} --dendrite_classifier_path ${params['dendrite-classifier-path']} --border_size ${params['border-size']} ${model_name_arg} --verify 1

	echo "[${task.tag}] completed!"
	"""
}


// capsule - aind-ophys-nwb
process ophys_nwb {
	tag 'capsule-8338960'
	container "$REGISTRY_HOST/capsule/f804beaa-2ac3-46c7-82b7-f46b19531aa9:ff457277a6bfa62d68328bc7e92b3884"

	cpus 4
	memory '32 GB'

	publishDir "$RESULTS_PATH", saveAs: publishRelative

	input:
    path schemas
    path ophys_mount_jsons
    path ophys_sync_file
    path ophys_mount_pophys_directory
    path motion_correction_results
    path decrosstalk_results
    path extraction_results
	path classifer_h5
	path dff_results
	path event_detection_results

	output:
	path 'capsule/results/*'
	path 'capsule/results/*/processing.json', emit: 'nwb_processing_json', optional: true
	path 'capsule/results/*/quality_control.json', emit: 'nwb_qc_json', optional: true

	script:
	"""
	#!/usr/bin/env bash
	set -e

	export CO_CAPSULE_ID=f804beaa-2ac3-46c7-82b7-f46b19531aa9
	export CO_CPUS=1
	export CO_MEMORY=8589934592
    echo "I AM MAKING AN NWB"
	mkdir -p capsule
	mkdir -p capsule/data && ln -s \$PWD/capsule/data /data
	mkdir -p capsule/results && ln -s \$PWD/capsule/results /results
	mkdir -p capsule/scratch && ln -s \$PWD/capsule/scratch /scratch
    mkdir -p capsule/data/schemas && ln -s \$PWD/capsule/data/schemas /schemas
    mkdir -p capsule/data/raw && ln -s \$PWD/capsule/data/raw /raw
    mkdir -p capsule/data/raw/behavior && ln -s \$PWD/capsule/data/raw/behavior /behavior
    mkdir -p capsule/data/nwb && ln -s \$PWD/capsule/data/nwb /nwb
    mkdir -p capsule/data/processed && ln -s \$PWD/capsule/data/processed /processed

    echo "[${task.tag}] copying data to capsule..."
    cp -r ${schemas} capsule/data/schemas
    cp -r ${ophys_mount_jsons} capsule/data/raw
    if [ -n "${ophys_sync_file}" ] && [ "${ophys_sync_file}" != "[]" ]; then
        cp -r ${ophys_sync_file} capsule/data/raw/behavior
    fi
    cp -r ${ophys_mount_pophys_directory} capsule/data/raw
    cp -r ${motion_correction_results} capsule/data/processed
    if [ -n "${decrosstalk_results}" ] && [ "${decrosstalk_results}" != "[]" ]; then
        cp -r ${decrosstalk_results} capsule/data/processed
    fi
    cp -r ${extraction_results} capsule/data/processed
    cp -r ${classifer_h5} capsule/data/processed
    cp -r ${dff_results} capsule/data/processed
    cp -r ${event_detection_results} capsule/data/processed

	ln -s "/tmp/data/schemas" "capsule/data/schemas" # id: fb4b5cef-4505-4145-b8bd-e41d6863d7a9

	echo "[${task.tag}] cloning git repo..."
	git clone "https://\$GIT_ACCESS_TOKEN@\$GIT_HOST/capsule-8338960.git" capsule-repo
	git -C capsule-repo checkout 350796a --quiet
    mv capsule-repo/code capsule/code
    rm -rf capsule-repo

	echo "[${task.tag}] running capsule..."
	cd capsule/code
	chmod +x run
	ls -R /data
    ./run --input_dir ${params.input_dir} --output_dir ${params.output_dir} --verify 1

	echo "[${task.tag}] completed!"
	"""
}

// capsule - aind-pipeline-processing-metadata-aggregator
process pipeline_processing_metadata_aggregator {
    tag 'capsule-8324994'
	container "$REGISTRY_HOST/published/22261566-0b4f-42aa-bcaa-58efa55bf653:v4"

    // data_description.json name embeds datetime.now() -> must regenerate every run (never cache)
    cache false

    cpus 2
    memory '16 GB'

    // This task's processing.json / quality_control.json are the run-level
    // documents, and they sit directly under capsule/results/, so the shared
    // saveAs publishes them at the results root -- where they belong.
    publishDir "$RESULTS_PATH", saveAs: publishRelative

    input:
    path ophys_mount_jsons
    path(processing_json, stageAs: 'processing_??/*')
    path(quality_control_json, stageAs: 'quality_control_??/*')

    output:
    path 'capsule/results/*'

    script:
    """
    #!/usr/bin/env bash
    set -e

    export CO_CAPSULE_ID=22261566-0b4f-42aa-bcaa-58efa55bf653
    export CO_CPUS=2
    export CO_MEMORY=17179869184

    mkdir -p capsule
    mkdir -p capsule/data && ln -s \$PWD/capsule/data /data
    mkdir -p capsule/results && ln -s \$PWD/capsule/results /results
    mkdir -p capsule/scratch && ln -s \$PWD/capsule/scratch /scratch

    # Preserve the numbered directory stageAs gave each file. A flat cp would
    # collapse every processing.json back onto one name and keep only the last;
    # aind-metadata-manager rglobs for them, so the nesting costs nothing.
    stage_nested() {
        for f in "\$@"; do
            [ -e "\$f" ] || continue
            d="capsule/data/\$(dirname "\$f")"
            mkdir -p "\$d"
            cp -r "\$f" "\$d/"
        done
    }

    echo "[${task.tag}] copying data to capsule..."
    cp -r ${ophys_mount_jsons} capsule/data
    stage_nested ${processing_json}
    stage_nested ${quality_control_json}
    echo "[${task.tag}] staged \$(find capsule/data -name processing.json | wc -l) processing.json, \$(find capsule/data -name quality_control.json | wc -l) quality_control.json"

    echo "[${task.tag}] cloning git repo..."
    git clone --branch v4.0 "https://\$GIT_ACCESS_TOKEN@\$GIT_HOST/capsule-8324994.git" capsule-repo
    mv capsule-repo/code capsule/code
    rm -rf capsule-repo

    echo "[${task.tag}] running capsule..."
    cd capsule/code
    chmod +x run
    ./run ${params.containsKey('processor_full_name') ? '--processor_full_name ' + (params.processor_full_name.toString().startsWith('"') ? params.processor_full_name : '"' + params.processor_full_name + '"') : ''} ${params.containsKey('skip_ancillary_files') ? '--skip_ancillary_files ' + params.skip_ancillary_files : ''} ${params.containsKey('modality') ? '--modality ' + params.modality : ''} ${params.containsKey('aggregate_quality_control') ? '--aggregate_quality_control ' + params.aggregate_quality_control : ''} ${params.containsKey('data_summary') && params.data_summary ? '--data_summary "' + params.data_summary + '"' : ''} ${params.containsKey('verbose') ? '--verbose ' + params.verbose : ''} --pipeline_url "\$PIPELINE_URL" --pipeline_version "\$PIPELINE_VERSION"
    echo "[${task.tag}] completed!"
    """
}
