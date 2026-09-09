#!/usr/bin/env nextflow

nextflow.enable.dsl = 2

params.ghcr_smoke_only = false
params.ophys_mount_url = 's3://aind-open-data/multiplane-ophys_839909_2026-02-26_15-11-01'

def parse_key_value_file(path) {
    def values = [:]
    file(path).eachLine { raw_line ->
        def line = raw_line.trim()
        if (!line || line.startsWith('#')) {
            return
        }
        def separator = line.indexOf('=')
        if (separator <= 0) {
            throw new IllegalArgumentException("Invalid manifest line: ${raw_line}")
        }
        def key = line.substring(0, separator).trim()
        def value = line.substring(separator + 1).trim()
        if (value.size() >= 2 && ((value.startsWith('"') && value.endsWith('"')) ||
                (value.startsWith("'") && value.endsWith("'")))) {
            value = value.substring(1, value.size() - 1)
        }
        if (values.containsKey(key)) {
            throw new IllegalArgumentException("Duplicate manifest key: ${key}")
        }
        values[key] = value
    }
    values
}

def validate_capsule_versions(versions) {
    def stages = [
        'CONVERTER',
        'MOTION_CORRECTION',
        'MOVIE_QC',
        'DECROSSTALK_SPLIT',
        'DECROSSTALK_ROI_IMAGES',
        'EXTRACTION',
        'DFF',
        'OASIS',
        'CLASSIFIER',
        'NWB',
        'AGGREGATOR'
    ]
    def sha_pattern = ~/^[0-9a-f]{40}$/
    def required = []
    stages.each { stage ->
        required << "${stage}_CAPSULE_SOURCE_MODE"
        required << "${stage}_IMAGE_CO"
        def mode = versions["${stage}_CAPSULE_SOURCE_MODE"]
        if (mode == 'git') {
            required << "${stage}_CAPSULE_REPO"
            required << "${stage}_CAPSULE_COMMIT"
            required << "${stage}_LIBRARY_COMMIT"
        } else if (mode == 'published') {
            required << "${stage}_CAPSULE_ID"
            required << "${stage}_REF"
        } else if (mode == 'co_git') {
            required << "${stage}_CAPSULE_ID"
            required << "${stage}_CAPSULE_COMMIT"
        } else {
            throw new IllegalArgumentException(
                "Unsupported ${stage}_CAPSULE_SOURCE_MODE: ${mode}; expected git, co_git, or published"
            )
        }
    }
    def missing = required.findAll { key -> !versions[key] }
    if (missing) {
        throw new IllegalArgumentException("Missing capsule manifest keys: ${missing.join(', ')}")
    }
    stages.each { stage ->
        if (versions["${stage}_CAPSULE_SOURCE_MODE"] == 'git') {
            ['CAPSULE_COMMIT', 'LIBRARY_COMMIT'].each { suffix ->
                def key = "${stage}_${suffix}"
                if (!(versions[key] ==~ sha_pattern)) {
                    throw new IllegalArgumentException("${key} must be a 40-character lowercase SHA")
                }
            }
        } else if (versions["${stage}_CAPSULE_SOURCE_MODE"] == 'co_git' &&
                !(versions["${stage}_CAPSULE_COMMIT"] ==~ /^[0-9a-f]{7,40}$/)) {
            throw new IllegalArgumentException(
                "${stage}_CAPSULE_COMMIT must be a 7-40 character lowercase SHA"
            )
        }
        def capsule_id = versions["${stage}_CO_CAPSULE_ID"]
        if (capsule_id && !versions["${stage}_IMAGE_CO"].contains(capsule_id)) {
            throw new IllegalArgumentException(
                "${stage}_IMAGE_CO does not contain ${stage}_CO_CAPSULE_ID"
            )
        }
    }
    versions
}

def parse_capsule_versions() {
    def custom = file("${baseDir}/capsule_versions_custom.env")
    def defaults = file("${baseDir}/capsule_versions.env")
    def manifest = custom.exists() ? custom : defaults
    if (!manifest.exists()) {
        throw new IllegalArgumentException("Capsule manifest not found: ${manifest}")
    }
    println "Using capsule manifest: ${manifest}"
    validate_capsule_versions(parse_key_value_file(manifest))
}

params.versions = parse_capsule_versions()

def backend = params.backend ?: 'codeocean'
if (!(backend in ['codeocean', 'local', 'slurm'])) {
    throw new IllegalArgumentException(
        "Unsupported backend: ${backend}; expected codeocean, local, or slurm"
    )
}
def image_suffix = backend == 'codeocean' ? '_IMAGE_CO' : '_IMAGE_OFFCO'
def registry_host = System.getenv('REGISTRY_HOST') ?: ''
def image_stages = [
    'CONVERTER',
    'MOTION_CORRECTION',
    'MOVIE_QC',
    'DECROSSTALK_SPLIT',
    'DECROSSTALK_ROI_IMAGES',
    'EXTRACTION',
    'DFF',
    'OASIS',
    'CLASSIFIER',
    'NWB',
    'AGGREGATOR'
]
params.stage_images = [:]
image_stages.each { stage ->
    def image_ref = params.versions["${stage}${image_suffix}"]
    if (!image_ref) {
        throw new IllegalArgumentException(
            "No ${backend} image configured for ${stage}; add ${stage}${image_suffix}"
        )
    }
    params.stage_images[stage] = backend == 'codeocean' && registry_host
        ? "${registry_host}/${image_ref}"
        : image_ref
}

def gitCloneFunction = '''
clone_repo() {
    local repo_url="$1"
    local commit_hash="$2"

    echo "cloning git repo: ${repo_url} (commit: ${commit_hash})..."
    git clone "${repo_url}" capsule-repo
    git -C capsule-repo -c core.fileMode=false checkout "${commit_hash}" --quiet
    test -d capsule-repo/code || {
        echo "capsule repository has no code/ directory: ${repo_url}" >&2
        exit 1
    }
    mv capsule-repo/code capsule/code
    rm -rf capsule-repo
}
'''

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
    def smoke_mode = params.ghcr_smoke_only.toString().toLowerCase()
    if (!(smoke_mode in ['true', 'false', '1', '0'])) {
        throw new IllegalArgumentException('ghcr_smoke_only must be true, false, 1, or 0')
    }
    if (smoke_mode in ['true', '1']) {
        ghcr_pull_smoke()
        return
    }

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
        def jsonSlurper = new groovy.json.JsonSlurper()
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
    def cellpose_data = Channel.fromPath("${base_path}cellpose_models/*", type: 'any', checkIfExists: false)
    def roinet_data = Channel.fromPath("${base_path}roinet/*", type: 'any', checkIfExists: false)
    
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
            converter_processing_json.flatten().collect().ifEmpty([]),
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
            use_s3_source ? converter_capsule.out.converter_results_all.collect() : Channel.empty().collect(),
            cellpose_data.collect().ifEmpty([])
        )

        decrosstalk_processing_json = decrosstalk_roi_images.out.decrosstalk_processing_json
        decrosstalk_qc_json = decrosstalk_roi_images.out.decrosstalk_qc_json
        decrosstalk_results_all = decrosstalk_roi_images.out.decrosstalk_results_all

        extraction(
            decrosstalk_roi_images.out.capsule_results.flatten(),
            ophys_mount_jsons.collect(),
            cellpose_data.collect().ifEmpty([])
        )

    } else {
        // Run motion correction for single plane
        motion_correction(
            motion_correction_input.collect(),
            ophys_mount_jsons.collect(),
            ophys_mount_pophys_directory.collect(),
            converter_processing_json.flatten().collect().ifEmpty([]),
        )

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
    // Provenance travels separately from the flat scientific inputs to avoid
    // collisions between identically named per-plane documents.
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


process ghcr_pull_smoke {
    container 'ghcr.io/allenneuraldynamics/pophys-decrosstalk-split@sha256:c6ab7e57139ad47074aa15599f3a6d1aee41db05e1c2bdf8da21aebaf3e111b6'
    cache false
    publishDir "$RESULTS_PATH", mode: 'copy'

    output:
    path 'ghcr-smoke.json'

    script:
    '''
    python - <<'PY'
    import json
    import platform
    from pathlib import Path

    result = {
        "probe": "pophys-ghcr-pull-v1",
        "image_digest": "sha256:c6ab7e57139ad47074aa15599f3a6d1aee41db05e1c2bdf8da21aebaf3e111b6",
        "python": platform.python_version(),
        "machine": platform.machine(),
        "scientific_processing": False,
    }
    Path("ghcr-smoke.json").write_text(json.dumps(result, indent=2) + "\\n")
    print(json.dumps(result))
    PY
    '''
}

// Process: aind-pophys-converter-capsule
process converter_capsule {
    tag 'capsule-9191145'
    def container_name = params.stage_images['CONVERTER']
    container container_name
    publishDir "$RESULTS_PATH", saveAs: publishRelativeSkipRunLevel

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
    ${gitCloneFunction}
    clone_repo "${params.versions['CONVERTER_CAPSULE_REPO']}" "${params.versions['CONVERTER_CAPSULE_COMMIT']}"

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
    def container_name = params.stage_images['MOTION_CORRECTION']
    container container_name
    publishDir "$RESULTS_PATH", saveAs: publishRelative

    input:
    path ophys_mount
    path ophys_jsons
    path pophys_dir

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

    stage_nested() {
        for f in "\$@"; do
            [ -e "\$f" ] || continue
            d="capsule/data/\$(dirname "\$f")"
            mkdir -p "\$d"
            cp -r "\$f" "\$d/"
        done
    }
    stage_nested ${upstream_processing_json}

    echo "[${task.tag}] cloning git repo..."
    ${gitCloneFunction}
    clone_repo "${params.versions['MOTION_CORRECTION_CAPSULE_REPO']}" "${params.versions['MOTION_CORRECTION_CAPSULE_COMMIT']}"
    
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
    def container_name = params.stage_images['MOVIE_QC']
    container container_name
    publishDir "$RESULTS_PATH", saveAs: publishRelative


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

	export CO_CAPSULE_ID=1e1ee66e-db39-4cc8-b760-08ed26f0c9e8
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
    ${gitCloneFunction}
    clone_repo "${params.versions['MOVIE_QC_CAPSULE_REPO']}" "${params.versions['MOVIE_QC_CAPSULE_COMMIT']}"

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
    def container_name = params.stage_images['DECROSSTALK_SPLIT']
    container container_name

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

    export CO_CAPSULE_ID=${params.versions['DECROSSTALK_SPLIT_CO_CAPSULE_ID']}
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
    git clone --branch ${params.versions['DECROSSTALK_SPLIT_REF']} "https://\$GIT_ACCESS_TOKEN@\$GIT_HOST/capsule-${params.versions['DECROSSTALK_SPLIT_CAPSULE_ID']}.git" capsule-repo
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
    def container_name = params.stage_images['DECROSSTALK_ROI_IMAGES']
    container container_name

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

    ln -s "/tmp/data/cellpose_models" "capsule/data/cellpose_models"

    echo "[${task.tag}] cloning git repo..."
    ${gitCloneFunction}
    clone_repo "${params.versions['DECROSSTALK_ROI_IMAGES_CAPSULE_REPO']}" "${params.versions['DECROSSTALK_ROI_IMAGES_CAPSULE_COMMIT']}"

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
    def container_name = params.stage_images['EXTRACTION']
    container container_name

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

    ln -s "/tmp/data/cellpose_models" "capsule/data/cellpose_models"

    echo "[${task.tag}] cloning git repo..."
    ${gitCloneFunction}
    clone_repo "${params.versions['EXTRACTION_CAPSULE_REPO']}" "${params.versions['EXTRACTION_CAPSULE_COMMIT']}"

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
    def container_name = params.stage_images['DFF']
    container container_name

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
    ${gitCloneFunction}
    clone_repo "${params.versions['DFF_CAPSULE_REPO']}" "${params.versions['DFF_CAPSULE_COMMIT']}"

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
    def container_name = params.stage_images['OASIS']
    container container_name

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
    ${gitCloneFunction}
    clone_repo "${params.versions['OASIS_CAPSULE_REPO']}" "${params.versions['OASIS_CAPSULE_COMMIT']}"

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
    def container_name = params.stage_images['CLASSIFIER']
    container container_name

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
	ln -s "/tmp/data/roinet" "capsule/data/roinet"

	echo "[${task.tag}] cloning git repo..."
    ${gitCloneFunction}
    clone_repo "${params.versions['CLASSIFIER_CAPSULE_REPO']}" "${params.versions['CLASSIFIER_CAPSULE_COMMIT']}"

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
    def container_name = params.stage_images['NWB']
    container container_name

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

    # NWB searches data/processed, not data, for upstream provenance.
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
    ${gitCloneFunction}
    clone_repo "${params.versions['NWB_CAPSULE_REPO']}" "${params.versions['NWB_CAPSULE_COMMIT']}"

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
    tag 'capsule-7054171'
    def container_name = params.stage_images['AGGREGATOR']
    container container_name

    // data_description.json name embeds datetime.now() -> must regenerate every run (never cache)
    cache false

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

    export CO_CAPSULE_ID=${params.versions['AGGREGATOR_CO_CAPSULE_ID']}
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
    git clone "https://\$GIT_ACCESS_TOKEN@\$GIT_HOST/capsule-${params.versions['AGGREGATOR_CAPSULE_ID']}.git" capsule-repo
    git -C capsule-repo checkout ${params.versions['AGGREGATOR_CAPSULE_COMMIT']} --quiet
    mv capsule-repo/code capsule/code
    rm -rf capsule-repo

    echo "[${task.tag}] running capsule..."
    cd capsule/code
    chmod +x run
    ./run ${params.containsKey('processor_full_name') ? '--processor_full_name ' + (params.processor_full_name.toString().startsWith('"') ? params.processor_full_name : '"' + params.processor_full_name + '"') : ''} ${params.containsKey('skip_ancillary_files') ? '--skip_ancillary_files ' + params.skip_ancillary_files : ''} ${params.containsKey('modality') ? '--modality ' + params.modality : ''} ${params.containsKey('aggregate_quality_control') ? '--aggregate_quality_control ' + params.aggregate_quality_control : ''} ${params.containsKey('data_summary') && params.data_summary ? '--data_summary "' + params.data_summary + '"' : ''} ${params.containsKey('verbose') ? '--verbose ' + params.verbose : ''} ${params.containsKey('upgrade_legacy_metadata') ? '--upgrade_legacy_metadata ' + params.upgrade_legacy_metadata : ''} --pipeline_url "\$PIPELINE_URL" --pipeline_version "\$PIPELINE_VERSION"
    echo "[${task.tag}] completed!"
    """
}
