#!/usr/bin/env nextflow

nextflow.enable.dsl = 2

import groovy.json.JsonSlurper

params.ophys_mount_url = 's3://aind-open-data/multiplane-ophys_784498_2025-04-26_11-23-47'

workflow {
    // Parameterized data source selection
    def use_s3_source = params.containsKey('ophys_mount_url')
    
    // Declare all variables outside conditional blocks
    def ophys_data = Channel.empty()
    def ophys_mount_jsons = Channel.empty()
    def ophys_mount_pophys_directory = Channel.empty()
    def base_path = Channel.empty()
    def z_stacks = Channel.empty()
    // Print all parameters at startup
    println "\n--- Pipeline Parameters ---"
    params.keySet().sort().each { key ->
        println "PARAM: ${key} = ${params[key]}"
    }
    println "--- End Parameters ---\n"
    
    base_path = "$projectDir/../data/"
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
    def decrosstalk_qc_json = Channel.empty()
    def decrosstalk_data_process_json = Channel.empty()
    def decrosstalk_results_all = Channel.empty()
    
    // Conditional converter execution - only run for S3 sources
    def motion_correction_input
    if (use_s3_source) {
    converter_capsule(ophys_data)
    
    // Just use assignment with view operators inline
    motion_correction_input = converter_capsule.out.converter_results
        .flatten()
        .filter { it.isDirectory() }
        .filter { !it.name.matches('vasculature|matched_tiff_vals') }
    } else {
        motion_correction_input = ophys_data
    }

    // Run Subject NWB Packaging Process
    nwb_packaging_subject(
        ophys_mount_jsons.collect()
    )

    if (params.acquisition_data_type == "multiplane"){
        // Run motion correction for multiplane
        motion_correction(
            motion_correction_input.flatten(),
            ophys_mount_jsons.collect(),
            ophys_mount_pophys_directory.collect(),
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
            use_s3_source ? converter_capsule.out.converter_results_all.collect() : Channel.empty().collect()
        )
        
        decrosstalk_qc_json = decrosstalk_roi_images.out.decrosstalk_qc_json
        decrosstalk_data_process_json = decrosstalk_roi_images.out.decrosstalk_data_process_json
        decrosstalk_results_all = decrosstalk_roi_images.out.decrosstalk_results_all

        // Run extraction Suite2P
        extraction(
            decrosstalk_roi_images.out.capsule_results.flatten(),
            ophys_mount_jsons.collect()
        )
        
    } else {
        // Run motion correction for single plane (adjusted input order)
        motion_correction(
            motion_correction_input.collect(),
            ophys_mount_jsons.collect(),
            ophys_mount_pophys_directory.collect()
        )

        // Run movie qc
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

    // Run classification
    classifier(
        ophys_mount_jsons.collect(),
        classifier_data.collect(),
        extraction.out.capsule_results.flatten(),
    )

    if (params.acquisition_data_type == "multiplane"){
        // Run DF / F
        dff_capsule(
            extraction.out.capsule_results.flatten(),
            ophys_mount_jsons.collect(),
            // motion_correction.out.motion_results_csv.collect()
        )

        // Run Oasis Event detection
        oasis_event_detection(
            dff_capsule.out.capsule_results.flatten(),
            ophys_mount_jsons.collect()
        )
    } else {
        // Run DF / F
        dff_capsule(
            extraction.out.capsule_results.collect(),
            ophys_mount_jsons.collect(),
            // motion_correction.out.motion_results_csv.collect()
        )

        // Run Oasis Event detection
        oasis_event_detection(
            dff_capsule.out.capsule_results.collect(),
            ophys_mount_jsons.collect()
        )
    }
    
    // Run Ophys NWB Packaging for Multiplane
    ophys_nwb(
        nwb_schemas.collect(),
        ophys_mount_jsons.collect(),
        ophys_mount_sync_file.collect().ifEmpty([]),
        ophys_mount_pophys_directory.collect(),
        nwb_packaging_subject.out.subject_nwb_results.collect(),
        motion_correction.out.motion_results.collect(),
        decrosstalk_results_all.collect().ifEmpty([]), // Handle empty channel
        extraction.out.extraction_results_all.collect(),
        classifier.out.classifer_h5.collect(),
        dff_capsule.out.dff_results_all.collect(),
        oasis_event_detection.out.events_h5.collect()
    )   

    // Run Quality Control Aggregator
    quality_control_aggregator(
        motion_correction.out.motion_results.collect(),
        movie_qc.out.movie_qc_json.collect(),
        movie_qc.out.movie_qc_png.collect(),
        decrosstalk_qc_json.collect().ifEmpty([]),
        extraction.out.extraction_qc_json.collect(),
        dff_capsule.out.dff_qc_json.collect(),
        oasis_event_detection.out.event_qc_png.collect(),
        oasis_event_detection.out.events_json.collect(),
        classifier.out.classifier_jsons.collect(),
        classifier.out.classifier_png.collect(),
        ophys_mount_jsons.collect()
    )
    
    // Run Pipeline Processing Metadata Aggregator
    pipeline_processing_metadata_aggregator(
        ophys_mount_jsons.collect(),
        motion_correction.out.motion_data_process_json.collect(),
        decrosstalk_data_process_json.collect().ifEmpty([]),
        extraction.out.extraction_data_process_json.collect(),
        classifier.out.classifier_jsons.collect(),
        dff_capsule.out.dff_data_process_json.collect(),
        oasis_event_detection.out.events_json.collect(),
    )  
}


// Process: aind-pophys-converter-capsule
process converter_capsule {
    tag 'capsule-2840051'
	container "$REGISTRY_HOST/published/d05f6de4-c0fb-46af-8c9f-a4acb4081497:v7"
    publishDir "$RESULTS_PATH", saveAs: { filename -> new File(filename).getName() }

    cpus 16
    memory '128 GB'

    input:
    path ophys_mount, name: 'capsule/data'

    output:
    path 'capsule/results/*', optional: true
    path 'capsule/results/*', emit: 'converter_results', optional: true
    path 'capsule/results/*/*', emit: 'converter_results_all', optional: true
    path 'capsule/results/*/*local*', emit: 'local_stacks', optional: true

    script:
    """
    #!/usr/bin/env bash
    set -e

    export CO_CAPSULE_ID=56956b65-72a4-4248-9718-468df22b23ff
    export CO_CPUS=16
    export CO_MEMORY=137438953472

    mkdir -p capsule
    mkdir -p capsule/data && ln -s \$PWD/capsule/data /data
    mkdir -p capsule/results && ln -s \$PWD/capsule/results /results
    mkdir -p capsule/scratch && ln -s \$PWD/capsule/scratch /scratch

    echo "[${task.tag}] cloning git repo..."
    git clone --branch v7.0 "https://\$GIT_ACCESS_TOKEN@\$GIT_HOST/capsule-2840051.git" capsule-repo
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
	container "$REGISTRY_HOST/published/91a8ed4d-3b9a-49c6-9283-3f16ea5482bf:v19"
    publishDir "$RESULTS_PATH", saveAs: { filename -> new File(filename).getName() }

    cpus 16
    memory '128 GB'

    input:
    path ophys_mount
    path ophys_jsons
    path pophys_dir

    output:
    path 'capsule/results/*', emit: 'motion_results_all', type: 'dir'
    path 'capsule/results/*/motion_correction/*transform.csv', emit: 'motion_results_csv'
    path 'capsule/results/*/*/*data_process.json', emit: 'motion_data_process_json'
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

    echo "[${task.tag}] copying data to capsule..."
    cp -r ${ophys_mount} capsule/data
    cp -r ${ophys_jsons} capsule/data
    cp -r ${pophys_dir} capsule/data

    echo "[${task.tag}] cloning git repo..."
    git clone --branch v19.0 "https://\$GIT_ACCESS_TOKEN@\$GIT_HOST/capsule-7474660.git" capsule-repo
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
	container "$REGISTRY_HOST/published/f52d9390-8569-49bb-9562-2d624b18ee56:v9"
    publishDir "$RESULTS_PATH", saveAs: { filename -> new File(filename).getName() }

	cpus 16
	memory '128 GB'


	input:
	path motion_results
    path ophys_jsons
    path zstacks

	output:
	path 'capsule/results/*'
	path 'capsule/results/*/*/*.json', emit:'movie_qc_json'
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
	git clone --branch v9.0 "https://\$GIT_ACCESS_TOKEN@\$GIT_HOST/capsule-0300037.git" capsule-repo
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
    tag 'capsule-4425001'
    container "$REGISTRY_HOST/published/fc1b1e9a-fb4b-47e8-a223-b06d8eeb1462:v1"

    cpus 2
    memory '16 GB'

    publishDir "$RESULTS_PATH", saveAs: { filename -> new File(filename).getName() }

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
    tag 'capsule-1533578'
	container "$REGISTRY_HOST/published/1383b25a-ecd2-4c56-8b7f-cde811c0b053:v12"

    cpus 16
    memory '128 GB'

    publishDir "$RESULTS_PATH", saveAs: { filename -> new File(filename).getName() }

    input:
    path decrosstalk_split
    path ophys_jsons
    path pophys_dir
    path motion_results
    path converter_files

    output:
    path 'capsule/results/*', emit: 'capsule_results'
    path 'capsule/results/*/*/*data_process.json', emit: 'decrosstalk_data_process_json', optional: true
    path 'capsule/results/*/*/*.json', emit: 'decrosstalk_qc_json', optional: true
    path 'capsule/results/*/decrosstalk/*', emit: 'decrosstalk_results_all'
    
    script:
    """
    #!/usr/bin/env bash
    set -e

    export CO_CAPSULE_ID=1383b25a-ecd2-4c56-8b7f-cde811c0b053
    export CO_CPUS=16
    export CO_MEMORY=137438953472

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
    git clone --branch v12.0 "https://\$GIT_ACCESS_TOKEN@\$GIT_HOST/capsule-1533578.git" capsule-repo
    mv capsule-repo/code capsule/code
    rm -rf capsule-repo

    echo "[${task.tag}] running capsule..."
    cd capsule/code
    chmod +x run
    ./run --debug ${params.debug}

    echo "[${task.tag}] completed!"
    """
}


// capsule - aind-ophys-extraction-suite2p
process extraction {
    tag 'capsule-9911715'
	container "$REGISTRY_HOST/published/5e1d659c-e149-4a57-be83-12f5a448a0c9:v13"

    cpus 4
    memory '128 GB'

    publishDir "$RESULTS_PATH", saveAs: { filename -> new File(filename).getName() }

    input:
    path extraction_input
    path ophys_jsons

    output:
    path 'capsule/results/*', emit: 'capsule_results'
    path 'capsule/results/*/*/*data_process.json', emit: 'extraction_data_process_json', optional: true
    path 'capsule/results/*/*/*.json', emit: 'extraction_qc_json', optional: true
    path 'capsule/results/*/extraction/*', emit: 'extraction_results_all'


    script:
    """
    #!/usr/bin/env bash
    set -e

    export CO_CAPSULE_ID=5e1d659c-e149-4a57-be83-12f5a448a0c9
    export CO_CPUS=4
    export CO_MEMORY=137438953472

    mkdir -p capsule
    mkdir -p capsule/data && ln -s \$PWD/capsule/data /data
    mkdir -p capsule/results && ln -s \$PWD/capsule/results /results
    mkdir -p capsule/scratch && ln -s \$PWD/capsule/scratch /scratch

    echo "[${task.tag}] copying data to capsule..."
    cp -r ${extraction_input} capsule/data
    cp -r ${ophys_jsons} capsule/data

    echo "[${task.tag}] cloning git repo..."
    git clone --branch v13.0 "https://\$GIT_ACCESS_TOKEN@\$GIT_HOST/capsule-9911715.git" capsule-repo
	mv capsule-repo/code capsule/code
	rm -rf capsule-repo

    echo "[${task.tag}] running capsule..."
    cd capsule/code
    chmod +x run
    echo "extraction parameters: --diameter ${params.diameter} --cellprob_threshold ${params.cellprob_threshold} --init ${params.init} --functional_chan ${params.functional_chan} --threshold_scaling ${params.threshold_scaling} --max_overlap ${params.max_overlap} --soma_crop ${params.soma_crop} --allow_overlap ${params.allow_overlap}"
    ./run --diameter ${params.diameter} --cellprob_threshold ${params.cellprob_threshold} --init ${params.init} --functional_chan ${params.functional_chan} --threshold_scaling ${params.threshold_scaling} --max_overlap ${params.max_overlap} --soma_crop ${params.soma_crop} --allow_overlap ${params.allow_overlap}n --diameter ${params.diameter} --cellprob_threshold ${params.cellprob_threshold} --init ${params.init} --functional_chan ${params.functional_chan} --threshold_scaling ${params.threshold_scaling} --max_overlap ${params.max_overlap} --soma_crop ${params.soma_crop} --allow_overlap ${params.allow_overlap}

    echo "[${task.tag}] completed!"
    """
}

// capsule - aind-ophys-dff
process dff_capsule {
    tag 'capsule-6574773'
	container "$REGISTRY_HOST/published/85987e27-601c-4863-811b-71e5b4bdea37:v5"

    cpus 4
    memory '32 GB'

    publishDir "$RESULTS_PATH", saveAs: { filename -> new File(filename).getName() }

    input:
    path extraction_results
    path ophys_mount_json
    // path motion_correction_results

    output:
    path 'capsule/results/*', emit: 'capsule_results'
    path 'capsule/results/*/*/*data_process.json', emit: 'dff_data_process_json', optional: true
    path 'capsule/results/*/*/*.json', emit: 'dff_qc_json', optional: true
    path 'capsule/results/*/dff/*', emit: 'dff_results_all'

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
    git clone --branch v5.0 "https://\$GIT_ACCESS_TOKEN@\$GIT_HOST/capsule-6574773.git" capsule-repo
    mv capsule-repo/code capsule/code
    rm -rf capsule-repo

    echo "[${task.tag}] running capsule..."
    cd capsule/code
    chmod +x run
    echo "dff_capsule parameters: --long_window ${params.long_window} --short_window ${params.short_window} --inactive_percentile ${params.inactive_percentile} --noise_method ${params.noise_method}"
    ./run --long_window ${params.long_window} --short_window ${params.short_window} --inactive_percentile ${params.inactive_percentile} --noise_method ${params.noise_method}
    
    echo "[${task.tag}] completed!"
    """
}

// capsule - aind-ophys-oasis-event-detection
process oasis_event_detection {
    tag 'capsule-8957649'
	container "$REGISTRY_HOST/published/c6394aab-0db7-47b2-90ba-864866d6755e:v10"

    cpus 4
    memory '32 GB'

    publishDir "$RESULTS_PATH", saveAs: { filename -> new File(filename).getName() }

    input:
    path dff_results
    path ophys_jsons

    output:
    path 'capsule/results/*'
    path 'capsule/results/*/*/plots/*', emit: 'event_qc_png', optional: true
    path 'capsule/results/*/*/*json', emit: 'events_json', optional: true
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
    git clone --branch v10.0 "https://\$GIT_ACCESS_TOKEN@\$GIT_HOST/capsule-8957649.git" capsule-repo
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
	container "$REGISTRY_HOST/published/3819d125-9f03-48f3-ba09-b44c84a7a2c7:v4"

	cpus 4
	memory '64 GB'
	accelerator 1
	label 'gpu'

	publishDir "$RESULTS_PATH", saveAs: { filename -> new File(filename).getName() }

	input:
    path ophys_mount_jsons
	path classifier_data
	path extraction_results
    
	output:
	path 'capsule/results/*/*/*.json', emit: 'classifier_jsons'
    path 'capsule/results/*/classification/*classification.h5', emit: 'classifer_h5'
	path 'capsule/results/*/*/*.png', emit: 'classifier_png'
	path 'capsule/results/*'

	script:
	"""
	#!/usr/bin/env bash
	set -e

	export CO_CAPSULE_ID=3819d125-9f03-48f3-ba09-b44c84a7a2c7
	export CO_CPUS=4
	export CO_MEMORY=214748364800

	mkdir -p capsule
	mkdir -p capsule/data && ln -s \$PWD/capsule/data /data
	mkdir -p capsule/results && ln -s \$PWD/capsule/results /results
	mkdir -p capsule/scratch && ln -s \$PWD/capsule/scratch /scratch

    echo "[${task.tag}] copying data to capsule..."
    cp -r ${ophys_mount_jsons} capsule/data
    cp -r ${classifier_data} capsule/data
    cp -r ${extraction_results} capsule/data

	ln -s "/tmp/data/2p_roi_classifier" "capsule/data/2p_roi_classifier" # id: 35d1284e-4dfa-4ac3-9ba8-5ea1ae2fdaeb

	echo "[${task.tag}] cloning git repo..."
	git clone --branch v4.0 "https://\$GIT_ACCESS_TOKEN@\$GIT_HOST/capsule-0630574.git" capsule-repo
	mv capsule-repo/code capsule/code
	rm -rf capsule-repo

	echo "[${task.tag}] running capsule..."
	cd capsule/code
	chmod +x run
	./run

	echo "[${task.tag}] completed!"
	"""
}

process nwb_packaging_subject {
	tag 'capsule-8198603'
	container "$REGISTRY_HOST/published/bdc9f09f-0005-4d09-aaf9-7e82abd93f19:v2"

	cpus 1
	memory '8 GB'

	input:
	path ophys_mount_jsons

	output:
	path 'capsule/results/*', emit: 'subject_nwb_results'

	script:
	"""
	#!/usr/bin/env bash
	set -e

	export CO_CAPSULE_ID=bdc9f09f-0005-4d09-aaf9-7e82abd93f19
	export CO_CPUS=1
	export CO_MEMORY=8589934592

	mkdir -p capsule
	mkdir -p capsule/data && ln -s \$PWD/capsule/data /data
	mkdir -p capsule/results && ln -s \$PWD/capsule/results /results
	mkdir -p capsule/scratch && ln -s \$PWD/capsule/scratch /scratch
    mkdir -p capsule/data/ophys_session && ln -s \$PWD/capsule/data/ophys_session /ophys_session

	echo "[${task.tag}] cloning git repo..."
	git clone --branch v2.0 "https://\$GIT_ACCESS_TOKEN@\$GIT_HOST/capsule-8198603.git" capsule-repo
	mv capsule-repo/code capsule/code
	rm -rf capsule-repo

    echo "[${task.tag}] copying data to capsule..."
    cp -r ${ophys_mount_jsons} capsule/data

	echo "[${task.tag}] running capsule..."
	cd capsule/code
	chmod +x run
	./run 

	echo "[${task.tag}] completed!"
	"""
}

// capsule - aind-ophys-nwb
process ophys_nwb {
	tag 'capsule-9383700'
	container "$REGISTRY_HOST/published/8c436e95-8607-4752-8e9f-2b62024f9326:v14"

	cpus 1
	memory '8 GB'

	publishDir "$RESULTS_PATH", saveAs: { filename -> new File(filename).getName() }

	input:
    path schemas
    path ophys_mount_jsons
    path ophys_sync_file
    path ophys_mount_pophys_directory
    path subject_nwb_results
    path motion_correction_results
    path decrosstalk_results
    path extraction_results
	path classifer_h5
	path dff_results
	path event_detection_results

	output:
	path 'capsule/results/*'

	script:
	"""
	#!/usr/bin/env bash
	set -e

	export CO_CAPSULE_ID=8c436e95-8607-4752-8e9f-2b62024f9326
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
    cp -r ${subject_nwb_results} capsule/data/nwb
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
	git clone --branch v14.0 "https://\$GIT_ACCESS_TOKEN@\$GIT_HOST/capsule-9383700.git" capsule-repo
    mv capsule-repo/code capsule/code
    rm -rf capsule-repo

	echo "[${task.tag}] running capsule..."
	cd capsule/code
	chmod +x run
	ls -R /data
    ./run

	echo "[${task.tag}] completed!"
	"""
}

// capsule - aind-pipeline-processing-metadata-aggregator
process pipeline_processing_metadata_aggregator {
    tag 'capsule-8324994'
	container "$REGISTRY_HOST/published/22261566-0b4f-42aa-bcaa-58efa55bf653:v2"

    cpus 2
    memory '16 GB'

    publishDir "$RESULTS_PATH", saveAs: { filename -> new File(filename).getName() }

    input:
    path ophys_mount_jsons
    path motion_correction_results
    path decrosstalk_results
    path extraction_results
    path classifier_jsons
    path dff_results
    path oasis_event_detection_results

    output:
    path 'capsule/results/*'

    script:
    """
    #!/usr/bin/env bash
    set -e

    export CO_CAPSULE_ID=d51df783-d892-4304-a129-238a9baea72a
    export CO_CPUS=2
    export CO_MEMORY=17179869184

    mkdir -p capsule
    mkdir -p capsule/data && ln -s \$PWD/capsule/data /data
    mkdir -p capsule/results && ln -s \$PWD/capsule/results /results
    mkdir -p capsule/scratch && ln -s \$PWD/capsule/scratch /scratch

    echo "[${task.tag}] copying data to capsule..."
    cp -r ${motion_correction_results} capsule/data
    if [ -e "${decrosstalk_results}" ]; then
        cp -r ${decrosstalk_results} capsule/data
    fi
    cp -r ${extraction_results} capsule/data
    cp -r ${dff_results} capsule/data
    cp -r ${oasis_event_detection_results} capsule/data
    cp -r ${ophys_mount_jsons} capsule/data
    cp -r ${classifier_jsons} capsule/data

    echo "[${task.tag}] cloning git repo..."
    git clone --branch v2.0 "https://\$GIT_ACCESS_TOKEN@\$GIT_HOST/capsule-8324994.git" capsule-repo
    mv capsule-repo/code capsule/code
    rm -rf capsule-repo

    echo "[${task.tag}] running capsule..."
    cd capsule/code
    chmod +x run
    ./run ${params.containsKey('processor_full_name') ? '--processor_full_name ' + params.processor_full_name : ''} ${params.containsKey('skip_ancillary_files') ? '--skip_ancillary_files ' + params.skip_ancillary_files : ''} ${params.containsKey('modality') ? '--modality ' + params.modality : ''} ${params.containsKey('pipeline_version') ? '--pipeline_version ' + params.pipeline_version : ''} ${params.containsKey('aggregate_quality_control') ? '--aggregate_quality_control ' + params.aggregate_quality_control : ''} ${params.containsKey('data_summary') ? '--data_summary ' + params.data_summary : ''} ${params.containsKey('verbose') ? '--verbose ' + params.verbose : ''}
    echo "[${task.tag}] completed!"
    """
}

// capsule - aind-quality-control-aggregator
process quality_control_aggregator {
    tag 'capsule-4044810'
	container "$REGISTRY_HOST/published/4a698b5c-f5f6-4671-8234-dc728d049a68:v8"

    cpus 1
    memory '8 GB'

    publishDir "$RESULTS_PATH", saveAs: { filename -> new File(filename).getName() }

    input:
    path motion_correction_results
    path movie_qc_json
    path movie_qc_png
    path decrosstalk_results
    path extraction_results
    path dff_results
    path oasis_event_detection_results
    path oasis_event_json
    path classifier_jsons
    path classifier_pngs
    path ophys_mount_jsons

    output:
    path 'capsule/results/*'

    script:
    def image_type_arg = params.acquisition_data_type == "multiplane" ? "--image_type=multiplane" : ""
    """
    #!/usr/bin/env bash
    set -e

    export CO_CAPSULE_ID=4a698b5c-f5f6-4671-8234-dc728d049a68
    export CO_CPUS=1
    export CO_MEMORY=8589934592

    mkdir -p capsule
    mkdir -p capsule/data && ln -s \$PWD/capsule/data /data
    mkdir -p capsule/results && ln -s \$PWD/capsule/results /results
    mkdir -p capsule/scratch && ln -s \$PWD/capsule/scratch /scratch

    echo "[${task.tag}] copying data to capsule..."
    cp -r ${ophys_mount_jsons} capsule/data
    cp -r ${motion_correction_results} capsule/data
    cp -r ${movie_qc_json} capsule/data
    cp -r ${movie_qc_png} capsule/data
    if [ -n "${decrosstalk_results}" ] && [ "${decrosstalk_results}" != "[]" ]; then
        cp -r ${decrosstalk_results} capsule/data
    fi
    cp -r ${extraction_results} capsule/data
    cp -r ${dff_results} capsule/data
    cp -r ${oasis_event_detection_results} capsule/data
    cp -r ${oasis_event_json} capsule/data
    cp -r ${classifier_jsons} capsule/data
    cp -r ${classifier_pngs} capsule/data

    echo "[${task.tag}] cloning git repo..."
    git clone --branch v8.0 "https://\$GIT_ACCESS_TOKEN@\$GIT_HOST/capsule-4044810.git" capsule-repo
    mv capsule-repo/code capsule/code
    rm -rf capsule-repo

    echo "[${task.tag}] running capsule..."
    cd capsule/code
    chmod +x run
    ./run ${image_type_arg}

    echo "[${task.tag}] completed!"
    """
}