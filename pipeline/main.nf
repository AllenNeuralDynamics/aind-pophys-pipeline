#!/usr/bin/env nextflow

nextflow.enable.dsl = 2

params.ophys_mount_url = 's3://aind-private-data-prod-o5171v/multiplane-ophys_767018_2025-02-10_13-04-43'

workflow {
    def data_description_fp = file("${params.ophys_mount_url}/data_description.json")
    def session_fp = file("${params.ophys_mount_url}/session.json")
    def ophys_mount_single_to_pophys_converter = Channel.fromPath(params.ophys_mount_url, type: 'any')
    def ophys_mount_jsons = Channel.fromPath("${params.ophys_mount_url}/*.json", type: 'any')
    def ophys_mount_pophys_directory = Channel.fromPath("${params.ophys_mount_url}/pophys", type: 'dir')

    def data_description = parse_json(data_description_fp)
    def session_description = parse_json(session_fp)

    // Run multiplane pipeline configuration
    if (params.data_type == "multiplane") {
        def ophys_mount_sync_file = Channel.fromPath("${params.ophys_mount_url}/behavior/*.h5", type: 'any')

        // Run converter
        converter_capsule(ophys_mount_single_to_pophys_converter)

        // Run motion correction
        motion_correction(
            converter_capsule.out.converter_results.flatten(),
            ophys_mount_jsons.collect(),
            ophys_mount_pophys_directory.collect(),
            ophys_mount_sync_file.collect()
        )

        // Run decrosstalk split to prep for decrosstalk_roi_images
        decrosstalk_split_json_capsule(
            motion_correction.out.motion_results.collect(),
            ophys_mount_jsons.collect()
        )

        // Run decrosstalk using ROI images
        decrosstalk_roi_images(
            decrosstalk_split_json_capsule.out.capsule_results.flatten(),
            ophys_mount_jsons.collect(),
            ophys_mount_pophys_directory.collect(),
            motion_correction.out.motion_results.collect(),
            converter_capsule.out.converter_results_nested.collect()
        )

        // Run extraction Suite2P
        extraction_suite2p_capsule(
            decrosstalk_roi_images.out.capsule_results.flatten().combine(ophys_mount_jsons.collect())
        )

        // Run DF / F
        dff_capsule(
            extraction_suite2p_capsule.out.capsule_results.flatten(),
            ophys_mount_jsons.collect(),
            motion_correction.out.motion_results_csv.collect()
        )

        // Run Oasis Event detection
        oasis_event_detection_capsule(
            dff_capsule.out.capsule_results.flatten(),
            ophys_mount_jsons.collect()
        )

    } else {
        println "Key does not contain 'multi'"
    }
}

def parse_json(file) {
    return new groovy.json.JsonSlurper().parseText(file.text)
}

// Process: aind-pophys-converter-capsule
process converter_capsule {
    tag 'capsule-0547799'
    container "$REGISTRY_HOST/capsule/56956b65-72a4-4248-9718-468df22b23ff:9c59c115ceb2eb78036bf6f73b8e3b61"
    publishDir "$RESULTS_PATH", saveAs: { filename -> new File(filename).getName() }

    cpus 16
    memory '128 GB'

    input:
    path ophys_mount, name: 'capsule/data'

    output:
    path 'capsule/results/*'
    path 'capsule/results/V*', emit: 'converter_results'
    path 'capsule/results/*/*', emit: 'converter_results_nested'

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
    git -C capsule-repo checkout 26c2b12 --quiet
    mv capsule-repo/code capsule/code
    rm -rf capsule-repo

    echo "[${task.tag}] running capsule..."
    cd capsule/code
    chmod +x run
    ./run --output_dir="/results" --input_dir="/data" --temp_dir="/scratch"

    echo "[${task.tag}] completed!"
    """
}

// capsule - aind-ophys-motion-correction
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
    path sync_file

    output:
    path 'capsule/results/*'
    path 'capsule/results/V*', emit: 'motion_results', optional: true
    path 'capsule/results/*/motion_correction/*transform.csv', emit: 'motion_results_csv'

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
    git -C capsule-repo checkout f44b3cc --quiet
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

// capsule - aind-ophys-decrosstalk-split-session-json
process decrosstalk_split_json_capsule {
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
    ./run

    echo "[${task.tag}] completed!"
    """
}

// capsule - aind-ophys-extraction-suite2p
process extraction_suite2p_capsule {
    tag 'capsule-9911715'
    container "$REGISTRY_HOST/published/5e1d659c-e149-4a57-be83-12f5a448a0c9:v9"

    cpus 4
    memory '128 GB'

    publishDir "$RESULTS_PATH", saveAs: { filename -> new File(filename).getName() }

    input:
    path extraction_input

    output:
    path 'capsule/results/*', emit: 'capsule_results'


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

    echo "[${task.tag}] cloning git repo..."
    git clone --branch v9.0 "https://\$GIT_ACCESS_TOKEN@\$GIT_HOST/capsule-9911715.git" capsule-repo
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
process oasis_event_detection_capsule {
    tag 'capsule-8957649'
    container "$REGISTRY_HOST/published/c6394aab-0db7-47b2-90ba-864866d6755e:v6"

    cpus 4
    memory '32 GB'

    publishDir "$RESULTS_PATH", saveAs: { filename -> new File(filename).getName() }

    input:
    path dff_results
    path ophys_jsons

    output:
    path 'capsule/results/*'

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
    git clone --branch v6.0 "https://\$GIT_ACCESS_TOKEN@\$GIT_HOST/capsule-8957649.git" capsule-repo
    mv capsule-repo/code capsule/code
    rm -rf capsule-repo

    echo "[${task.tag}] running capsule..."
    cd capsule/code
    chmod +x run
    ./run

    echo "[${task.tag}] completed!"
    """
}