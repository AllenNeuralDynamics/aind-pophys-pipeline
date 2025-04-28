#!/usr/bin/env nextflow

nextflow.enable.dsl = 2

params.ophys_mount_url = 's3://aind-open-data/multiplane-ophys_784498_2025-04-26_11-23-47'

workflow {
    def ophys_mount_single_to_pophys_converter = Channel.fromPath(params.ophys_mount_url, type: 'any')
    def ophys_mount_jsons = Channel.fromPath("${params.ophys_mount_url}/*.json", type: 'any')
    def ophys_mount_pophys_directory = Channel.fromPath("${params.ophys_mount_url}/pophys", type: 'dir')
    def classifier_data = Channel.fromPath("$projectDir/../data/2p_roi_classifier/*", type: 'any', checkIfExists: true)
    // Only for mulitplane sessions
    def ophys_mount_sync_file = Channel.fromPath("${params.ophys_mount_url}/behavior/*.h5", type: 'any')
    
    // Run converter
    converter_capsule(ophys_mount_single_to_pophys_converter)

    if (params.data_type == "multiplane"){
        // Run motion correction
        motion_correction_multiplane(
            converter_capsule.out.converter_results.flatten(),
            ophys_mount_jsons.collect(),
            ophys_mount_pophys_directory.collect(),
            ophys_mount_sync_file.collect()
        )

        // Run movie qc
        movie_qc(
            motion_correction_multiplane.out.motion_results.collect()
        )

        // Run decrosstalk split to prep for decrosstalk_roi_images
        decrosstalk_split_json(
            motion_correction_multiplane.out.motion_results.collect(),
            ophys_mount_jsons.collect()
        )

        // Run decrosstalk using ROI images
        decrosstalk_roi_images(
            decrosstalk_split_json.out.capsule_results.flatten(),
            ophys_mount_jsons.collect(),
            ophys_mount_pophys_directory.collect(),
            motion_correction_multiplane.out.motion_results.collect(),
            converter_capsule.out.converter_results_all.collect()
        )

        // Run extraction Suite2P
        extraction_suite2p(
            decrosstalk_roi_images.out.capsule_results.flatten(),
            ophys_mount_jsons.collect()
        )
        
    } else {
        // Run motion correction
        motion_correction(
            converter_capsule.out.converter_results.collect(),
            ophys_mount_jsons.collect(),
            ophys_mount_pophys_directory.collect()
        )

        // Run movie qc
        movie_qc(
            motion_correction.out.motion_results.collect()
        )

        extraction_suite2p(
            motion_correction.out.motion_results.collect(),
            ophys_mount_jsons.collect()
        )
    }

    // Run classification
    classifier(
        ophys_mount_jsons.collect(),
        classifier_data.collect(),
        extraction_suite2p.out.capsule_results.flatten(),
    )

    if (params.data_type == "multiplane"){
        // Run DF / F
        dff_capsule(
            extraction_suite2p.out.capsule_results.flatten(),
            ophys_mount_jsons.collect(),
            motion_correction_multiplane.out.motion_results_csv.collect()
        )

        // Run Oasis Event detection
        oasis_event_detection(
            dff_capsule.out.capsule_results.flatten(),
            ophys_mount_jsons.collect()
        )
    } else {
        // Run DF / F
        dff_capsule(
            extraction_suite2p.out.capsule_results.collect(),
            ophys_mount_jsons.collect(),
            motion_correction.out.motion_results_csv.collect()
        )

        // Run Oasis Event detection
        oasis_event_detection(
            dff_capsule.out.capsule_results.collect(),
            ophys_mount_jsons.collect()
        )
    }

    

    if (params.data_type == "multiplane"){
    // Run Quality Control Aggregator
        quality_control_aggregator(
            motion_correction_multiplane.out.motion_qc_json.collect(),
            movie_qc.out.movie_qc_json.collect(),
            movie_qc.out.movie_qc_png.collect(),
            decrosstalk_roi_images.out.decrosstalk_qc_json.collect(),
            extraction_suite2p.out.extraction_qc_json.collect(),
            dff_capsule.out.dff_qc_json.collect(),
            oasis_event_detection.out.event_qc_png.collect(),
            oasis_event_detection.out.events_json.collect(),
            classifier.out.classifier_jsons.collect(),
            classifier.out.classifier_png.collect()
        )

        // Run Pipeline Processing Metadata Aggregator
        pipeline_processing_metadata_aggregator_multiplane(
            motion_correction_multiplane.out.motion_data_process_json.collect(),
            decrosstalk_roi_images.out.decrosstalk_data_process_json.collect(),
            extraction_suite2p.out.extraction_data_process_json.collect(),
            dff_capsule.out.dff_data_process_json.collect(),
            oasis_event_detection.out.events_json.collect(),
            ophys_mount_jsons.collect(),
            classifier.out.classifier_jsons.collect()
        )
        
    } else {
        // Run Pipeline Processing Metadata Aggregator
        pipeline_processing_metadata_aggregator(
            motion_correction.out.motion_data_process_json.collect(),
            extraction_suite2p.out.extraction_data_process_json.collect(),
            dff_capsule.out.dff_data_process_json.collect(),
            oasis_event_detection.out.events_json.collect(),
            ophys_mount_jsons.collect(),
            classifier.out.classifier_jsons.collect()
        )
    }
}

// Process: aind-pophys-converter-capsule
process converter_capsule {
    tag 'capsule-0547799'
    container "$REGISTRY_HOST/capsule/56956b65-72a4-4248-9718-468df22b23ff:640998928072c03bffaf81b93146c9e3"
    publishDir "$RESULTS_PATH", saveAs: { filename -> new File(filename).getName() }

    cpus 16
    memory '128 GB'

    input:
    path ophys_mount, name: 'capsule/data'

    output:
    path 'capsule/results/*'
    path 'capsule/results/*', emit: 'converter_results'
    path 'capsule/results/*/*', emit: 'converter_results_all', optional: true

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
    git clone "https://\$GIT_ACCESS_TOKEN@\$GIT_HOST/capsule-0547799.git" capsule-repo
    git -C capsule-repo checkout 77b8b31 --quiet
    mv capsule-repo/code capsule/code
    rm -rf capsule-repo

    echo "[${task.tag}] running capsule..."
    cd capsule/code
    chmod +x run
    ./run --output_dir="/results" --input_dir="/data" --temp_dir="/scratch" --debug="t

    echo "[${task.tag}] completed!"
    ls -a /results
    """
}

// capsule - aind-ophys-motion-correction multiplane
process motion_correction_multiplane {
    tag 'capsule-7474660'
    container "$REGISTRY_HOST/capsule/63a8ce2e-f232-4590-9098-36b820202911:0da186b632b36a65afc14b406afd4686"
    publishDir "$RESULTS_PATH", saveAs: { filename -> new File(filename).getName() }

    cpus 16
    memory '128 GB'

    input:
    path converter_results
    path ophys_jsons
    path pophys_dir
    path sync_file

    output:
    path 'capsule/results/*'
    path 'capsule/results/*', emit: 'motion_results', type: 'dir'
    path 'capsule/results/*/motion_correction/*transform.csv', emit: 'motion_results_csv'
    path 'capsule/results/*/*/*data_process.json', emit: 'motion_data_process_json', optional: true
    path 'capsule/results/*/motion_correction/*', emit: 'motion_qc_json'

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
    cp -r ${converter_results} capsule/data
    cp -r ${ophys_jsons} capsule/data
    cp -r ${pophys_dir} capsule/data
    cp -r ${sync_file} capsule/data

    echo "[${task.tag}] cloning git repo..."
    git clone "https://\$GIT_ACCESS_TOKEN@\$GIT_HOST/capsule-5379831.git" capsule-repo
    git -C capsule-repo checkout 2bfd99d --quiet
    mv capsule-repo/code capsule/code
    rm -rf capsule-repo
    
    echo "[${task.tag}] running capsule..."
    cd capsule/code
    ls -la /data
    chmod +x run
    ./run --debug
    echo "[${task.tag}] completed!"
    """
}

// capsule - aind-ophys-motion-correction multiplane
process motion_correction {
    tag 'capsule-7474660'
    container "$REGISTRY_HOST/capsule/63a8ce2e-f232-4590-9098-36b820202911:0da186b632b36a65afc14b406afd4686"
    publishDir "$RESULTS_PATH", saveAs: { filename -> new File(filename).getName() }

    cpus 16
    memory '128 GB'

    input:
    path converter_results
    path ophys_jsons
    path pophys_dir

    output:
    path 'capsule/results/*'
    path 'capsule/results/*', emit: 'motion_results', type: 'dir'
    path 'capsule/results/*/motion_correction/*transform.csv', emit: 'motion_results_csv'
    path 'capsule/results/*/*/*data_process.json', emit: 'motion_data_process_json', optional: true
    path 'capsule/results/*/motion_correction/*', emit: 'motion_qc_json'

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
    cp -r ${converter_results} capsule/data
    cp -r ${ophys_jsons} capsule/data
    cp -r ${pophys_dir} capsule/data

    echo "[${task.tag}] cloning git repo..."
    git clone "https://\$GIT_ACCESS_TOKEN@\$GIT_HOST/capsule-5379831.git" capsule-repo
    git -C capsule-repo checkout 48136aa --quiet
    mv capsule-repo/code capsule/code
    rm -rf capsule-repo
    
    echo "[${task.tag}] running capsule..."
    cd capsule/code
    ls -la /data
    chmod +x run
    ./run
    echo "[${task.tag}] completed!"
    """
}

// capsule - aind-ophys-movie-qc
process movie_qc {
	tag 'capsule-0300037'
	container "$REGISTRY_HOST/published/f52d9390-8569-49bb-9562-2d624b18ee56:v6"

	cpus 16
	memory '128 GB'

	publishDir "$RESULTS_PATH", saveAs: { filename -> new File(filename).getName() }

	input:
	path motion_results

	output:
	path 'capsule/results/*'
	path 'capsule/results/*/*/*.json', emit:'movie_qc_json'
	path 'capsule/results/*/*/*.png', emit: 'movie_qc_png'

	script:
	"""
	#!/usr/bin/env bash
	set -e

	export CO_CAPSULE_ID=f52d9390-8569-49bb-9562-2d624b18ee56
	export CO_CPUS=16
	export CO_MEMORY=137438953472

	mkdir -p capsule
	mkdir -p capsule/data && ln -s \$PWD/capsule/data /data
	mkdir -p capsule/results && ln -s \$PWD/capsule/results /results
	mkdir -p capsule/scratch && ln -s \$PWD/capsule/scratch /scratch

    echo "[${task.tag}] copying data to capsule..."
    cp -r ${motion_results} capsule/data

	echo "[${task.tag}] cloning git repo..."
	git clone --branch v6.0 "https://\$GIT_ACCESS_TOKEN@\$GIT_HOST/capsule-0300037.git" capsule-repo
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
    container "$REGISTRY_HOST/published/1383b25a-ecd2-4c56-8b7f-cde811c0b053:v10"

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
    git clone --branch v10.0 "https://\$GIT_ACCESS_TOKEN@\$GIT_HOST/capsule-1533578.git" capsule-repo
    mv capsule-repo/code capsule/code
    rm -rf capsule-repo

    echo "[${task.tag}] running capsule..."
    cd capsule/code
    chmod +x run
    ./run --debug

    echo "[${task.tag}] completed!"
    """
}

// capsule - aind-ophys-extraction-suite2p
process extraction_suite2p {
    tag 'capsule-3592435'
    container "$REGISTRY_HOST/capsule/c9f136a2-67d7-4adf-b15a-e02af4237fa4"

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
    git clone "https://\$GIT_ACCESS_TOKEN@\$GIT_HOST/capsule-3592435.git" capsule-repo
    git -C capsule-repo checkout 8131e2f --quiet
    mv capsule-repo/code capsule/code
    rm -rf capsule-repo

    echo "[${task.tag}] running capsule..."
    cd capsule/code
    chmod +x run
    ./run 

    echo "[${task.tag}] completed!"
    """
}

// capsule - aind-ophys-dff
process dff_capsule {
    tag 'capsule-6574773'
    container "$REGISTRY_HOST/published/85987e27-601c-4863-811b-71e5b4bdea37:v4"

    cpus 4
    memory '32 GB'

    publishDir "$RESULTS_PATH", saveAs: { filename -> new File(filename).getName() }

    input:
    path extraction_suite2p_results
    path ophys_mount_json
    path motion_correction_results

    output:
    path 'capsule/results/*', emit: 'capsule_results'
    path 'capsule/results/*/*/*data_process.json', emit: 'dff_data_process_json', optional: true
    path 'capsule/results/*/*/*.json', emit: 'dff_qc_json', optional: true

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
    cp -r ${extraction_suite2p_results} capsule/data
    cp -r ${motion_correction_results} capsule/data

    echo "[${task.tag}] cloning git repo..."
    git clone --branch v4.0 "https://\$GIT_ACCESS_TOKEN@\$GIT_HOST/capsule-6574773.git" capsule-repo
    mv capsule-repo/code capsule/code
    rm -rf capsule-repo

    echo "[${task.tag}] running capsule..."
    cd capsule/code
    chmod +x run
    ./run

    echo "[${task.tag}] completed!"
    """
}

// capsule - aind-ophys-oasis-event-detection
process oasis_event_detection {
    tag 'capsule-0298748'
	container "$REGISTRY_HOST/capsule/382062c4-fd31-4812-806b-cc81bad29bf4"

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
    git clone "https://\$GIT_ACCESS_TOKEN@\$GIT_HOST/capsule-0298748.git" capsule-repo
	git -C capsule-repo checkout c62a395143428f5c6041e3bdfa25facf93add3c4 --quiet
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
	// path 'capsule/results/*/classification/*classification.h5' into capsule_aind_ophys_classifier_17_to_capsule_aind_ophys_nwb_12_27
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

// capsule - aind-ophys-quality-control-aggregator
process quality_control_aggregator {
	tag 'capsule-4691390'
	container "$REGISTRY_HOST/published/4a698b5c-f5f6-4671-8234-dc728d049a68:v3"

	cpus 1
	memory '8 GB'

	publishDir "$RESULTS_PATH", saveAs: { filename -> new File(filename).getName() }

	input:
	path motion_correction_results
    path movie_qc_json
    path movie_qc_png
    path decrosstalk_results
    path extraction_suite2p_results
    path dff_results
    path oasis_event_detection_results
    path oasis_event_json
    path classifier_jsons
    path classifier_pngs

	output:
	path 'capsule/results/*'

	script:
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
    cp -r ${motion_correction_results} capsule/data
    cp -r ${movie_qc_json} capsule/data
    cp -r ${movie_qc_png} capsule/data
    cp -r ${decrosstalk_results} capsule/data
    cp -r ${extraction_suite2p_results} capsule/data
    cp -r ${dff_results} capsule/data
    cp -r ${oasis_event_detection_results} capsule/data
    cp -r ${oasis_event_json} capsule/data
    cp -r ${classifier_jsons} capsule/data
    cp -r ${classifier_pngs} capsule/data

	echo "[${task.tag}] cloning git repo..."
	git clone --branch v3.0 "https://\$GIT_ACCESS_TOKEN@\$GIT_HOST/capsule-4044810.git" capsule-repo
	mv capsule-repo/code capsule/code
	rm -rf capsule-repo

	echo "[${task.tag}] running capsule..."
	cd capsule/code
	chmod +x run
	./run

	echo "[${task.tag}] completed!"
	"""
}

// capsule - aind-pipeline-processing-metadata-aggregator
process pipeline_processing_metadata_aggregator_multiplane {
	tag 'capsule-8250608'
	container "$REGISTRY_HOST/published/d51df783-d892-4304-a129-238a9baea72a:v4"

	cpus 2
	memory '16 GB'

	publishDir "$RESULTS_PATH", saveAs: { filename -> new File(filename).getName() }

	input:
    path motion_correction_results
    path decrosstalk_results
    path extraction_suite2p_results
    path dff_results
    path oasis_event_detection_results
    path ophys_mount_jsons
    path classifier_jsons

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
    cp -r ${decrosstalk_results} capsule/data
    cp -r ${extraction_suite2p_results} capsule/data
    cp -r ${dff_results} capsule/data
    cp -r ${oasis_event_detection_results} capsule/data
    cp -r ${ophys_mount_jsons} capsule/data
    cp -r ${classifier_jsons} capsule/data

	echo "[${task.tag}] cloning git repo..."
	git clone --branch v4.0 "https://\$GIT_ACCESS_TOKEN@\$GIT_HOST/capsule-8250608.git" capsule-repo
	mv capsule-repo/code capsule/code
	rm -rf capsule-repo

	echo "[${task.tag}] running capsule..."
	cd capsule/code
	chmod +x run
	./run --processor_full_name "Arielle Leon" --copy-ancillary-files True --derived-data-description True

	echo "[${task.tag}] completed!"
	"""
}

// capsule - aind-pipeline-processing-metadata-aggregator
process pipeline_processing_metadata_aggregator {
	tag 'capsule-8250608'
	container "$REGISTRY_HOST/published/d51df783-d892-4304-a129-238a9baea72a:v4"

	cpus 2
	memory '16 GB'

	publishDir "$RESULTS_PATH", saveAs: { filename -> new File(filename).getName() }

	input:
    path motion_correction_results
    path extraction_suite2p_results
    path dff_results
    path oasis_event_detection_results
    path ophys_mount_jsons
    path classifier_jsons

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
    cp -r ${extraction_suite2p_results} capsule/data
    cp -r ${dff_results} capsule/data
    cp -r ${oasis_event_detection_results} capsule/data
    cp -r ${ophys_mount_jsons} capsule/data
    cp -r ${classifier_jsons} capsule/data

	echo "[${task.tag}] cloning git repo..."
	git clone --branch v4.0 "https://\$GIT_ACCESS_TOKEN@\$GIT_HOST/capsule-8250608.git" capsule-repo
	mv capsule-repo/code capsule/code
	rm -rf capsule-repo

	echo "[${task.tag}] running capsule..."
	cd capsule/code
	chmod +x run
	./run --processor_full_name "Arielle Leon" --copy-ancillary-files True --derived-data-description True

	echo "[${task.tag}] completed!"
	"""
}
