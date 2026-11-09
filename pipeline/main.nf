#!/usr/bin/env nextflow

nextflow.enable.dsl = 2

import groovy.json.JsonSlurper

// saveAs runs once per published file; keep its path relative to capsule/results.
CAPSULE_RESULTS = 'capsule/results/'
RUN_LEVEL_DOCS = ['processing.json', 'quality_control.json']

publishRelative = { String filename ->
    filename.startsWith(CAPSULE_RESULTS)
        ? filename.substring(CAPSULE_RESULTS.length())
        : filename
}

// Skips a step's own root-level processing.json / quality_control.json; the run-level pair is published there.
publishRelativeSkipRunLevel = { String filename ->
    def rel = publishRelative(filename)
    rel in RUN_LEVEL_DOCS ? null : rel
}

workflow {
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
    if (!params.ophys_mount_url) {
        error "No input session: attach the session's data asset at mount 'ophys_mount', or pass --ophys_mount_url."
    }
    ophys_data = Channel.fromPath(params.ophys_mount_url, type: 'any')
    ophys_mount_jsons = Channel.fromPath("${params.ophys_mount_url}/*.json", type: 'any')
    ophys_mount_pophys_directory = Channel.fromPath("${params.ophys_mount_url}/pophys", type: 'dir')
    
    def nwb_schemas = Channel.fromPath("${base_path}schemas/*", type: 'any', checkIfExists: true)
    def classifier_data = Channel.fromPath("${base_path}2p_roi_classifier/*", type: 'any', checkIfExists: true)
    // Model assets: no checkIfExists, so the capsule reports a missing file by name.
    def cellpose_data = Channel.fromPath("${base_path}cellpose_models/*", type: 'any', checkIfExists: false)
    def roinet_data = Channel.fromPath("${base_path}roinet/*", type: 'any', checkIfExists: false)
    
    def ophys_mount_sync_file = Channel.fromPath("${params.ophys_mount_url}/behavior/*.h5", type: 'any', checkIfExists: false)
    def all_behavior_files = Channel.fromPath("${params.ophys_mount_url}/behavior/*", type: 'any', checkIfExists: false)

    // Initialize channels for multiplane-specific processes
    def decrosstalk_processing_json = Channel.empty()
    def decrosstalk_qc_json = Channel.empty()
    def decrosstalk_results_all = Channel.empty()

    converter_capsule(ophys_data)

    def converter_processing_json = converter_capsule.out.converter_processing_json
    def converter_qc_json = converter_capsule.out.converter_qc_json

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
    def motion_correction_input = converter_split.other
    vasculature_dir = converter_split.vasculature
    matched_tiff_vals_dir = converter_split.matched_tiff_vals

    if (params.acquisition_data_type == "multiplane"){
        // Run motion correction for multiplane
        motion_correction(
            motion_correction_input.flatten(),
            ophys_mount_jsons.collect(),
            ophys_mount_pophys_directory.collect(),
            converter_processing_json.flatten().collect().ifEmpty([]),
        )
        z_stacks = converter_capsule.out.local_stacks

        // Run movie qc
        movie_qc(
            motion_correction.out.motion_results_all.flatten(),
            ophys_mount_jsons.collect(),
            z_stacks.collect().ifEmpty([])
        )

        // Run decrosstalk split to prep for decrosstalk_roi_images
        decrosstalk_split_json(
            motion_correction.out.motion_results_all.collect(),
            ophys_mount_jsons.collect()
        )

        // Run decrosstalk using ROI images
        decrosstalk_roi_images(
            decrosstalk_split_json.out.capsule_results.flatten(),
            ophys_mount_jsons.collect(),
            ophys_mount_pophys_directory.collect(),
            motion_correction.out.motion_results_all.collect(),
            converter_capsule.out.converter_results_all.collect(),
            cellpose_data.collect().ifEmpty([])
        )

        decrosstalk_processing_json = decrosstalk_roi_images.out.decrosstalk_processing_json
        decrosstalk_qc_json = decrosstalk_roi_images.out.decrosstalk_qc_json
        decrosstalk_results_all = decrosstalk_roi_images.out.decrosstalk_results_all

        // Run extraction Suite2P
        extraction(
            decrosstalk_roi_images.out.capsule_results.flatten(),
            ophys_mount_jsons.collect(),
            cellpose_data.collect().ifEmpty([])
        )

    } else {
        // Run motion correction for single plane (adjusted input order)
        motion_correction(
            motion_correction_input.collect(),
            ophys_mount_jsons.collect(),
            ophys_mount_pophys_directory.collect(),
            converter_processing_json.flatten().collect().ifEmpty([]),
        )

        // Run movie qc
        movie_qc(
            motion_correction.out.motion_results_all.flatten(),
            ophys_mount_jsons.collect(),
            z_stacks.collect().ifEmpty([])
        )

        extraction(
            motion_correction.out.motion_results_all.collect(),
            ophys_mount_jsons.collect(),
            cellpose_data.collect().ifEmpty([])
        )
    }

    // Run DF / F
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
        roinet_data.collect().ifEmpty([]),
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
    // NWB reads no step's processing.json / quality_control.json; drop them to avoid an input name collision.
    // flatten() before filter: each task emits a List, and filtering a List passes everything.
    def metadata_json = ['processing.json', 'quality_control.json']

    // Upstream processing.json for NWB's dependency_graph; decrosstalk emits a List per pair, so flatten().
    def nwb_upstream_processing_json = motion_correction.out.motion_processing_json
        .mix(decrosstalk_processing_json)
        .mix(extraction.out.extraction_processing_json)
        .mix(dff_capsule.out.dff_processing_json)
        .mix(classifier.out.classifier_processing_json)
        .mix(oasis_event_detection.out.oasis_processing_json)
        .flatten()
        .collect()
        .ifEmpty([])

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
        oasis_event_detection.out.events_h5.collect(),
        nwb_upstream_processing_json
    )

    // Every step's processing.json / quality_control.json, flattened for the same reason.
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

    // Run Pipeline Processing Metadata Aggregator
    // ifEmpty([]) keeps it running, and failing loudly, when no step emitted metadata.
    pipeline_processing_metadata_aggregator(
        ophys_mount_jsons.collect(),
        all_processing_json.collect().ifEmpty([]),
        all_quality_control_json.collect().ifEmpty([])
    )
}


// Process: aind-pophys-converter-capsule
process converter_capsule {
    tag 'capsule-2840051'
	container "$REGISTRY_HOST/published/d05f6de4-c0fb-46af-8c9f-a4acb4081497:v12"
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

    export CO_CAPSULE_ID=d05f6de4-c0fb-46af-8c9f-a4acb4081497
    export CO_CPUS=16
    export CO_MEMORY=137438953472

    mkdir -p capsule
    mkdir -p capsule/data && ln -s \$PWD/capsule/data /data
    mkdir -p capsule/results && ln -s \$PWD/capsule/results /results
    mkdir -p capsule/scratch && ln -s \$PWD/capsule/scratch /scratch

    echo "[${task.tag}] cloning git repo..."
    git clone --branch v12.0 "https://\$GIT_ACCESS_TOKEN@\$GIT_HOST/capsule-2840051.git" capsule-repo
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
    tag 'capsule-7474660'
	container "$REGISTRY_HOST/published/91a8ed4d-3b9a-49c6-9283-3f16ea5482bf:v20"
    publishDir "$RESULTS_PATH", saveAs: publishRelative

    cpus 16
    memory '128 GB'

    input:
    path ophys_mount
    path ophys_jsons
    path pophys_dir
    // Upstream processing.json files share one name, so stageAs gives each its own directory.
    path(upstream_processing_json, stageAs: 'processing_??/*')

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

    export CO_CAPSULE_ID=91a8ed4d-3b9a-49c6-9283-3f16ea5482bf
    export CO_CPUS=16
    export CO_MEMORY=137438953472
    
    mkdir -p capsule
    mkdir -p capsule/data && ln -s \$PWD/capsule/data /data
    mkdir -p capsule/results && ln -s \$PWD/capsule/results /results
    mkdir -p capsule/scratch && ln -s \$PWD/capsule/scratch /scratch

    # Preserve the numbered directory stageAs gave each file; a flat cp would
    # collapse every processing.json onto one name. The collector rglobs.
    stage_nested() {
        for f in "\$@"; do
            [ -e "\$f" ] || continue
            d="capsule/data/\$(dirname "\$f")"
            mkdir -p "\$d"
            cp -r "\$f" "\$d/"
        done
    }

    echo "[${task.tag}] copying data to capsule..."
    cp -r ${ophys_mount} capsule/data
    cp -r ${ophys_jsons} capsule/data
    cp -r ${pophys_dir} capsule/data
    stage_nested ${upstream_processing_json}

    echo "[${task.tag}] cloning git repo..."
    git clone --branch v20.0 "https://\$GIT_ACCESS_TOKEN@\$GIT_HOST/capsule-7474660.git" capsule-repo
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
	tag 'capsule-0300037'
	container "$REGISTRY_HOST/published/f52d9390-8569-49bb-9562-2d624b18ee56:v12"
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
	git clone --branch v12.0 "https://\$GIT_ACCESS_TOKEN@\$GIT_HOST/capsule-0300037.git" capsule-repo
	mv capsule-repo/code capsule/code
	rm -rf capsule-repo

    echo "[${task.tag}] running capsule..."
    cd capsule/code
    chmod +x run
    ./run

    echo "[${task.tag}] completed!"
    """
}

// capsule - aind-ophys-decrosstalk-split-session-json
process decrosstalk_split_json {
    tag 'capsule-2670251'
    container "$REGISTRY_HOST/published/cd0f7d02-d3e1-4a3d-943f-84de5c8f4ddc:v1"

    cpus 2
    memory '16 GB'

    input:
    path motion_results
    path ophys_jsons

    output:
    path 'capsule/results/*', emit: 'capsule_results'
    
    script:
    """
    #!/usr/bin/env bash
    set -e

    export CO_CAPSULE_ID=cd0f7d02-d3e1-4a3d-943f-84de5c8f4ddc
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
    git clone --branch v1.0 "https://\$GIT_ACCESS_TOKEN@\$GIT_HOST/capsule-2670251.git" capsule-repo
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
    tag 'capsule-1533578'
	container "$REGISTRY_HOST/published/1383b25a-ecd2-4c56-8b7f-cde811c0b053:v16"

    cpus 8
    memory '64 GB'

    publishDir "$RESULTS_PATH", saveAs: publishRelative

    input:
    path decrosstalk_split
    path ophys_jsons
    path pophys_dir
    path motion_results
    path converter_files
    path cellpose_data

    output:
    path 'capsule/results/*', emit: 'capsule_results'
    path 'capsule/results/*/*/processing.json', emit: 'decrosstalk_processing_json', optional: true
    path 'capsule/results/*/*/quality_control.json', emit: 'decrosstalk_qc_json', optional: true
    path 'capsule/results/*/decrosstalk/*', emit: 'decrosstalk_results_all'
    
    script:
    """
    #!/usr/bin/env bash
    set -e

    export CO_CAPSULE_ID=1383b25a-ecd2-4c56-8b7f-cde811c0b053
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

    # Read-only asset: linked at its stable /data path, never copied.
    # The capsule wrapper verifies each file and its SHA-256 before
    # constructing Cellpose.
    ln -s "/tmp/data/cellpose_models" "capsule/data/cellpose_models" # id: df0e5676-1354-4353-8b2c-f8062aa485db

    echo "[${task.tag}] cloning git repo..."
    git clone --branch v16.0 "https://\$GIT_ACCESS_TOKEN@\$GIT_HOST/capsule-1533578.git" capsule-repo
    mv capsule-repo/code capsule/code
    rm -rf capsule-repo

    echo "[${task.tag}] running capsule..."
    cd capsule/code
    chmod +x run
    ./run --debug ${params.debug}

    echo "[${task.tag}] completed!"
    """
}


// capsule - aind-ophys-extraction
process extraction {
    tag 'capsule-9911715'
	container "$REGISTRY_HOST/published/5e1d659c-e149-4a57-be83-12f5a448a0c9:v15"

    cpus 8
    memory '64 GB'

    publishDir "$RESULTS_PATH", saveAs: publishRelative

    input:
    path extraction_input
    path ophys_jsons
    path cellpose_data

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

    export CO_CAPSULE_ID=5e1d659c-e149-4a57-be83-12f5a448a0c9
    export CO_CPUS=8
    export CO_MEMORY=68719476736

    mkdir -p capsule
    mkdir -p capsule/data && ln -s \$PWD/capsule/data /data
    mkdir -p capsule/results && ln -s \$PWD/capsule/results /results
    mkdir -p capsule/scratch && ln -s \$PWD/capsule/scratch /scratch

    echo "[${task.tag}] copying data to capsule..."
    cp -r ${extraction_input} capsule/data
    cp -r ${ophys_jsons} capsule/data

    # Read-only asset: linked at its stable /data path, never copied.
    # The capsule wrapper verifies each file and its SHA-256 before
    # constructing Cellpose.
    ln -s "/tmp/data/cellpose_models" "capsule/data/cellpose_models" # id: df0e5676-1354-4353-8b2c-f8062aa485db

    echo "[${task.tag}] cloning git repo..."
    git clone --branch v15.0 "https://\$GIT_ACCESS_TOKEN@\$GIT_HOST/capsule-9911715.git" capsule-repo
    mv capsule-repo/code capsule/code
    rm -rf capsule-repo

    echo "[${task.tag}] running capsule..."
    cd capsule/code
    chmod +x run
    echo "extraction parameters: --diameter ${params.diameter} --cellprob_threshold ${params.cellprob_threshold} --init ${params.init} --functional_chan ${params.functional_chan} --threshold_scaling ${params.threshold_scaling} --max_overlap ${params.max_overlap} --soma_crop ${params.soma_crop} --allow_overlap ${params.allow_overlap}"
    ./run --diameter ${params.diameter} --cellprob_threshold ${params.cellprob_threshold} --init ${params.init} --functional_chan ${params.functional_chan} --threshold_scaling ${params.threshold_scaling} --max_overlap ${params.max_overlap} --soma_crop ${params.soma_crop} --allow_overlap ${params.allow_overlap} ${suite2p_params_arg} ${suite2p_ops_arg}

    echo "[${task.tag}] completed!"
    """
}

// capsule - aind-ophys-dff
process dff_capsule {
    tag 'capsule-6574773'
	container "$REGISTRY_HOST/published/85987e27-601c-4863-811b-71e5b4bdea37:v7"

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

    export CO_CAPSULE_ID=85987e27-601c-4863-811b-71e5b4bdea37
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
    git clone --branch v7.0 "https://\$GIT_ACCESS_TOKEN@\$GIT_HOST/capsule-6574773.git" capsule-repo
    mv capsule-repo/code capsule/code
    rm -rf capsule-repo

    echo "[${task.tag}] running capsule..."
    cd capsule/code
    chmod +x run
    echo "dff_capsule parameters: --method ${params.method} --long_window ${params.long_window} --short_window ${params.short_window} --inactive_percentile ${params.inactive_percentile} --noise_method ${params.noise_method} --sigma_anneal_steps ${params.sigma_anneal_steps} --triexp_config_overrides '${params.triexp_config_overrides}'"
    ./run --method ${params.method} --long_window ${params.long_window} --short_window ${params.short_window} --inactive_percentile ${params.inactive_percentile} --noise_method ${params.noise_method} --sigma_anneal_steps ${params.sigma_anneal_steps} --triexp_config_overrides '${params.triexp_config_overrides}'

    echo "[${task.tag}] completed!"
    """
}

// capsule - aind-ophys-oasis-event-detection
process oasis_event_detection {
    tag 'capsule-8957649'
	container "$REGISTRY_HOST/published/c6394aab-0db7-47b2-90ba-864866d6755e:v11"

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

    export CO_CAPSULE_ID=c6394aab-0db7-47b2-90ba-864866d6755e
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
	git clone --branch v11.0 "https://\$GIT_ACCESS_TOKEN@\$GIT_HOST/capsule-8957649.git" capsule-repo
	mv capsule-repo/code capsule/code
    rm -rf capsule-repo

    echo "[${task.tag}] running capsule..."
    cd capsule/code
    chmod +x run
    ./run

    echo "[${task.tag}] completed!"
    """
}

// capsule - aind-ophys-classifier
process classifier {
	tag 'capsule-0630574'
	container "$REGISTRY_HOST/published/3819d125-9f03-48f3-ba09-b44c84a7a2c7:v6"

	cpus 16
	memory '60 GB'
	accelerator 1
	label 'gpu'

	publishDir "$RESULTS_PATH", saveAs: publishRelative

	input:
    path ophys_mount_jsons
	path classifier_data
	path extraction_results
	path roinet_data
    
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

	export CO_CAPSULE_ID=3819d125-9f03-48f3-ba09-b44c84a7a2c7
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
	ln -s "/tmp/data/roinet" "capsule/data/roinet" # id: 7e4bd8f4-8881-4541-94b4-d1ac714d4a07

	echo "[${task.tag}] cloning git repo..."
	git clone --branch v6.0 "https://\$GIT_ACCESS_TOKEN@\$GIT_HOST/capsule-0630574.git" capsule-repo
	mv capsule-repo/code capsule/code
	rm -rf capsule-repo

	echo "[${task.tag}] running capsule..."
	cd capsule/code
	chmod +x run
	./run --input_dir ${params.input_dir} --output_dir ${params.output_dir} --tmp_dir ${params.temp_dir} --soma_classifier_path ${params['soma-classifier-path']} --dendrite_classifier_path ${params['dendrite-classifier-path']} --border_size ${params['border-size']} ${model_name_arg}

	echo "[${task.tag}] completed!"
	"""
}


// capsule - aind-ophys-nwb
process ophys_nwb {
	tag 'capsule-8338960'
	container "$REGISTRY_HOST/capsule/f804beaa-2ac3-46c7-82b7-f46b19531aa9:d71e931392295b3e1fb99a02028fb694"

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
    // Upstream processing.json files share one name, so stageAs gives each its own directory.
    path(upstream_processing_json, stageAs: 'processing_??/*')

	output:
	path 'capsule/results/*'
	path 'capsule/results/*/processing.json', emit: 'nwb_processing_json', optional: true
	path 'capsule/results/*/quality_control.json', emit: 'nwb_qc_json', optional: true

	script:
	"""
	#!/usr/bin/env bash
	set -e

	export CO_CAPSULE_ID=f804beaa-2ac3-46c7-82b7-f46b19531aa9
	export CO_CPUS=4
	export CO_MEMORY=34359738368
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

    # Preserve the numbered directory stageAs gave each file; a flat cp would
    # collapse every processing.json onto one name. The collector rglobs.
    #
    # These must land under data/processed/, not data/: this capsule resolves
    # processed_dir = input_dir / "processed" and searches THAT, so documents
    # staged one level up are invisible to it (verified from run bb739583,
    # where NWB's dependency_graph came back empty for exactly this reason).
    stage_nested() {
        for f in "\$@"; do
            [ -e "\$f" ] || continue
            d="capsule/data/processed/\$(dirname "\$f")"
            mkdir -p "\$d"
            cp -r "\$f" "\$d/"
        done
    }
    stage_nested ${upstream_processing_json}
    echo "[${task.tag}] staged \$(find capsule/data/processed -name processing.json | wc -l) upstream processing.json"

	ln -s "/tmp/data/schemas" "capsule/data/schemas" # id: fb4b5cef-4505-4145-b8bd-e41d6863d7a9

	echo "[${task.tag}] cloning git repo..."
    git clone "https://\$GIT_ACCESS_TOKEN@\$GIT_HOST/capsule-8338960.git" capsule-repo
    git -C capsule-repo checkout 8ea017877e137a154cbda4b641742dae0e4df208 --quiet
    mv capsule-repo/code capsule/code
    rm -rf capsule-repo

	echo "[${task.tag}] running capsule..."
	cd capsule/code
	chmod +x run
	ls -R /data
    ./run --input_dir ${params.input_dir} --output_dir ${params.output_dir}

	echo "[${task.tag}] completed!"
	"""
}

// capsule - aind-metadata-manager-capsule
process pipeline_processing_metadata_aggregator {
    tag 'capsule-8324994'
	container "$REGISTRY_HOST/published/22261566-0b4f-42aa-bcaa-58efa55bf653:v6"

    // data_description.json name embeds datetime.now() -> must regenerate every run (never cache)
    cache false

    cpus 2
    memory '16 GB'

    // The run-level processing.json / quality_control.json publish at the results root.
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
    git clone --branch v6.0 "https://\$GIT_ACCESS_TOKEN@\$GIT_HOST/capsule-8324994.git" capsule-repo
    mv capsule-repo/code capsule/code
    rm -rf capsule-repo

    echo "[${task.tag}] running capsule..."
    cd capsule/code
    chmod +x run
    ./run ${params.containsKey('processor_full_name') ? '--processor_full_name ' + (params.processor_full_name.toString().startsWith('"') ? params.processor_full_name : '"' + params.processor_full_name + '"') : ''} ${params.containsKey('skip_ancillary_files') ? '--skip_ancillary_files ' + params.skip_ancillary_files : ''} ${params.containsKey('modality') ? '--modality ' + params.modality : ''} ${params.containsKey('aggregate_quality_control') ? '--aggregate_quality_control ' + params.aggregate_quality_control : ''} ${params.containsKey('data_summary') && params.data_summary ? '--data_summary "' + params.data_summary + '"' : ''} ${params.containsKey('verbose') ? '--verbose ' + params.verbose : ''} --pipeline_url "\$PIPELINE_URL" --pipeline_version "\$PIPELINE_VERSION"
    echo "[${task.tag}] completed!"
    """
}
