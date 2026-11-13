#!/usr/bin/env nextflow

nextflow.enable.dsl = 2

params.params_file = params.params_file ?: System.getenv('PARAMS_FILE') ?: null

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

def load_pipeline_parameters() {
    def candidates = []
    if (params.params_file) {
        candidates << params.params_file.toString()
    }
    candidates << "${baseDir}/../data/pipeline_parameters.json"
    candidates << "/data/pipeline_parameters.json"

    def selected = candidates.find { candidate -> file(candidate).exists() }
    if (!selected) {
        if (params.params_file) {
            throw new IllegalArgumentException(
                "Parameter file not found: ${params.params_file}"
            )
        }
        return
    }

    def parsed = new groovy.json.JsonSlurper().parse(file(selected).toFile())
    if (!(parsed instanceof Map)) {
        throw new IllegalArgumentException(
            "Parameter file must contain a JSON object: ${selected}"
        )
    }
    parsed.each { key, value -> params[key] = value }
    params.params_file = selected
    println "Using pipeline parameter file: ${selected}"
}

// Applied after the parameter file, so the command line and the file can both set them.
def apply_runtime_path_defaults() {
    [input_dir: '/data', output_dir: '/results', temp_dir: '/scratch'].each { name, value ->
        if (!params.containsKey(name)) {
            params[name] = value
        }
    }
}

// Quote a value as one bash word.
def shell_quote(value) {
    "'" + value.toString().replace("'", "'\"'\"'") + "'"
}

// The Code Ocean panel can wrap a free-text value in double quotes.
def strip_double_quotes(value) {
    def text = value.toString()
    text.size() >= 2 && text.startsWith('"') && text.endsWith('"') ? text[1..-2] : text
}

def validate_runtime_paths() {
    [
        input_dir: params.input_dir,
        output_dir: params.output_dir,
        temp_dir: params.temp_dir,
    ].each { name, value ->
        def path = value?.toString()?.trim()
        if (!path || !path.startsWith('/') || path.contains('\u0000') ||
                path ==~ /.*[\r\n\t ].*/) {
            throw new IllegalArgumentException(
                "params.${name} must be an absolute container path without whitespace"
            )
        }
    }
}

load_pipeline_parameters()
apply_runtime_path_defaults()
validate_runtime_paths()

def task_runtime_path(configured_path, task_relative_path) {
    // The default /data, /results and /scratch become task-relative paths, which
    // resolve once the task changes into capsule/code; other paths pass through.
    configured_path.toString() in ['/data', '/results', '/scratch']
        ? task_relative_path
        : configured_path.toString()
}

def task_input_dir = task_runtime_path(params.input_dir, '../data')
def task_output_dir = task_runtime_path(params.output_dir, '../results')
def task_temp_dir = task_runtime_path(params.temp_dir, '../scratch')

def validate_process_versions(versions) {
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
        required << "${stage}_LIBRARY_REPO"
        required << "${stage}_LIBRARY_COMMIT"
    }
    def missing = required.findAll { key -> !versions[key] }
    if (missing) {
        throw new IllegalArgumentException("Missing process manifest keys: ${missing.join(', ')}")
    }
    stages.each { stage ->
        def key = "${stage}_LIBRARY_COMMIT"
        if (!(versions[key] ==~ sha_pattern)) {
            throw new IllegalArgumentException("${key} must be a 40-character lowercase SHA")
        }
    }
    versions
}

def parse_process_versions() {
    def custom = file("${baseDir}/process_versions_custom.env")
    def defaults = file("${baseDir}/process_versions.env")
    def manifest = custom.exists() ? custom : defaults
    if (!manifest.exists()) {
        throw new IllegalArgumentException("Process manifest not found: ${manifest}")
    }
    println "Using process manifest: ${manifest}"
    validate_process_versions(parse_key_value_file(manifest))
}

params.versions = parse_process_versions()

def backend = params.backend ?: 'codeocean'
if (!(backend in ['codeocean', 'local', 'slurm'])) {
    throw new IllegalArgumentException(
        "Unsupported backend: ${backend}; expected codeocean, local, or slurm"
    )
}
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
// Every step runs ghcr.io/allenneuraldynamics/<image_name>:<container_tag>,
// with image names from environment/images.json. The tag comes from
// --container_tag (CLI or config), then the CONTAINER_TAG environment variable,
// then PIPELINE_VERSION in nextflow.config, which each release sets, so a
// released pipeline runs its released images. Development runs use the `dev`
// tag. images_custom.env, which git ignores, overrides individual steps with
// any image reference, such as a locally built image.
def resolve_container_tag() {
    if (params.containsKey('container_tag') && params.container_tag) {
        println "CONTAINER TAG (from CLI/config): ${params.container_tag}"
        return params.container_tag.toString()
    }
    def env_tag = System.getenv('CONTAINER_TAG')
    if (env_tag) {
        println "CONTAINER TAG (from ENV): ${env_tag}"
        return env_tag
    }
    def config_file = file("${baseDir}/nextflow.config")
    def matcher = config_file.exists() ? (config_file.text =~ /PIPELINE_VERSION = "([^"]+)"/) : null
    if (!matcher || !matcher.find()) {
        throw new IllegalArgumentException(
            'Cannot determine container tag: set --container_tag, CONTAINER_TAG or PIPELINE_VERSION in nextflow.config'
        )
    }
    def version = matcher.group(1)
    println "CONTAINER TAG (from nextflow.config PIPELINE_VERSION): ${version}"
    version
}

def parse_stage_images(image_stages, container_tag) {
    def catalog = new groovy.json.JsonSlurper().parse(file("${baseDir}/../environment/images.json").toFile())
    if (catalog.keySet() != image_stages.toSet()) {
        throw new IllegalArgumentException('environment/images.json must list exactly all 11 stages')
    }
    if (!(container_tag ==~ /^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$/)) {
        throw new IllegalArgumentException("Invalid container tag: ${container_tag}")
    }
    def images = [:]
    catalog.each { stage, entry ->
        images[stage] = "ghcr.io/allenneuraldynamics/${entry.image_name}:${container_tag}"
    }
    def custom = file("${baseDir}/images_custom.env")
    if (custom.exists()) {
        def overrides = parse_key_value_file(custom)
        def unknown = overrides.keySet() - image_stages.toSet()
        if (unknown) {
            throw new IllegalArgumentException("Unknown stages in images_custom.env: ${unknown.join(', ')}")
        }
        overrides.each { stage, image ->
            if (!(image ==~ /^[^\s]+$/)) {
                throw new IllegalArgumentException("Image for ${stage} in images_custom.env must be one reference")
            }
            println "Using custom image for ${stage}: ${image}"
            images[stage] = image
        }
    }
    images
}

params.container_tag = resolve_container_tag()
params.stage_images = parse_stage_images(image_stages, params.container_tag)

// Each task clones its processing library at the pinned commit, installs it
// with --no-deps over the dependencies already in the step's image, and runs
// <module>.run() from capsule/code so the ../data, ../results and ../scratch
// task paths resolve.
def libraryFunctions = '''
install_library() {
    local repo_url="$1"
    local commit_hash="$2"

    echo "installing processing library: ${repo_url} (commit: ${commit_hash})..."
    git clone --quiet "${repo_url}" capsule/library-source
    git -C capsule/library-source -c advice.detachedHead=false checkout --quiet "${commit_hash}"
    PYTHONPATH="/opt/build-tools${PYTHONPATH:+:${PYTHONPATH}}" \
        python -m pip install --quiet --no-deps --no-build-isolation --no-cache-dir \
        --target capsule/library capsule/library-source
    export PYTHONPATH="${PWD}/capsule/library${PYTHONPATH:+:${PYTHONPATH}}"
    python -m pip check
    mkdir -p capsule/code
}

run_library() {
    local module="$1"
    shift
    echo "running ${module}.run $*"
    python -u -c 'import importlib, sys; importlib.import_module(sys.argv.pop(1)).run()' "${module}" "$@"
}
'''

// Decrosstalk: turn the staged pair<k>.txt into a pair<k>/ directory of plane
// links, which the library's pair discovery reads. Runs in capsule/code.
def decrosstalkPairFunction = '''
stage_pair() {
    shopt -s nullglob
    local pair_files=(../data/pair*.txt)
    shopt -u nullglob
    if [ "${#pair_files[@]}" -eq 0 ]; then
        echo "no ../data/pair*.txt; expecting a pre-staged pair*/ directory"
        return
    fi
    if [ "${#pair_files[@]}" -ne 1 ]; then
        echo "ERROR: expected one ../data/pair*.txt, found ${#pair_files[@]}: ${pair_files[*]}" >&2
        exit 1
    fi
    local pair_file="${pair_files[0]}"
    local pair_dir="${pair_file%.txt}"
    mkdir -p "${pair_dir}"
    local plane name
    while read -r plane || [ -n "${plane}" ]; do
        [ -n "${plane}" ] || continue
        case "${plane}" in
            /*)
                if [ "$(dirname "${plane}")" != "$(cd ../data && pwd -P)" ]; then
                    echo "ERROR: plane path is not directly under the input directory: ${plane}" >&2
                    exit 1
                fi
                name="$(basename "${plane}")" ;;
            *) name="${plane}" ;;
        esac
        if [ ! -d "../data/${name}" ]; then
            echo "ERROR: plane directory not found: ../data/${name}" >&2
            exit 1
        fi
        ln -sfn "../${name}" "${pair_dir}/${name}"
    done < "${pair_file}"
    echo "pair planes: $(ls "${pair_dir}" | tr '\\n' ' ')"
}
'''

// Classifier: copy a mounted ROInet.zip to writable scratch and point
// TORCH_HOME at a mounted ConvNeXt checkpoint. Without them, the library
// downloads both. Runs in capsule/code; sets ROINET_ARGS.
def classifierModelFunction = '''
stage_roinet() {
    local work_dir="${PWD}/../scratch/roinet"
    local convnext="torch/hub/checkpoints/convnext_tiny-983f1562.pth"
    local candidate
    ROINET_ARGS=()
    for candidate in ../data/roinet ../data/2p_roi_classifier; do
        if [ -f "${candidate}/ROInet.zip" ]; then
            mkdir -p "${work_dir}"
            cp "${candidate}/ROInet.zip" "${work_dir}/"
            ROINET_ARGS=(--roinet_dir="${work_dir}")
            if [ -f "${candidate}/${convnext}" ]; then
                export TORCH_HOME="$(cd "${candidate}" && pwd)/torch"
            else
                export TORCH_HOME="${work_dir}/torch"
            fi
            echo "ROInet: ${candidate}/ROInet.zip, TORCH_HOME=${TORCH_HOME}"
            return
        fi
    done
    export TORCH_HOME="${work_dir}/torch"
    echo "ROInet: no mounted ROInet.zip; it is downloaded, with ConvNeXt into ${TORCH_HOME}"
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

// For a step that writes its own processing.json / quality_control.json at
// the top of capsule/results/ rather than under <plane>/<step>/ (the converter).
// Those would publish to the results root, where the aggregator writes the
// run-level pair. The documents still reach the aggregator on their emit
// channels, so they are not published.
publishRelativeSkipRunLevel = { String filename ->
    def rel = publishRelative(filename)
    rel in RUN_LEVEL_DOCS ? null : rel
}

workflow {
    if (!params.ophys_mount_url ||
            !(params.ophys_mount_url.toString() ==~ /^(s3:\/\/[^\/\s]+\/\S+|\/\S+)$/)) {
        throw new IllegalArgumentException('Set the session with --ophys_mount_url: an S3 URL or an absolute directory')
    }

    // The session comes from an S3 URL or a local absolute directory; the
    // converter reads either.
    def source = params.ophys_mount_url.toString()
    def use_s3_source = source.startsWith('s3://')
    
    // Declare all variables outside conditional blocks
    def ophys_data = Channel.empty()
    def ophys_mount_jsons = Channel.empty()
    def ophys_mount_pophys_directory = Channel.empty()
    def z_stacks = Channel.empty()
    def vasculature_dir = Channel.empty()
    def matched_tiff_vals_dir = Channel.empty()
    
    // Print the resolved parameter set after parameter-file loading.
    println "\n--- Pipeline Parameters ---"
    params.keySet().sort().each { key ->
        println "PARAM: ${key} = ${params[key]}"
    }
    println "--- End Parameters ---\n"
    
    // Model files: DATA_PATH when set (SLURM and local runs), else data/ at the
    // repository root, which is where Code Ocean attaches the model assets. The
    // backend configs bind the same folder into every task at /tmp/data.
    def data_root = System.getenv('DATA_PATH') ?: "${projectDir}/../data"
    def base_path = "${data_root}/"
    // Data source setup
    if (use_s3_source) {
        ophys_data = Channel.fromPath(source, type: 'any')
        ophys_mount_jsons = Channel.fromPath("${source}/*.json", type: 'any')
        ophys_mount_pophys_directory = Channel.fromPath("${source}/pophys", type: 'dir')
    } else {
        ophys_data = Channel.fromPath(source, type: 'dir', checkIfExists: true)
        ophys_mount_jsons = Channel.fromPath("${source}/*.json", type: 'any', checkIfExists: true)
        ophys_mount_pophys_directory = Channel.fromPath("${source}/pophys", type: 'dir', checkIfExists: true)
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

    def converter_processing_json = Channel.empty()
    def converter_qc_json = Channel.empty()
    
    // The converter writes one HDF5 movie per plane from the raw session, S3 or local.
    def motion_correction_input
    converter(ophys_data)

    converter_processing_json = converter.out.converter_processing_json
    converter_qc_json = converter.out.converter_qc_json
    
    // Separate the directories we want to filter out
    converter.out.converter_results
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

    if (params.acquisition_data_type == "multiplane"){
        // Run motion correction for multiplane
        motion_correction(
            motion_correction_input.flatten(),
            ophys_mount_jsons.collect(),
            ophys_mount_pophys_directory.collect(),
            converter_processing_json.flatten().collect().ifEmpty([]),
        )
        z_stacks = converter.out.local_stacks

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

        // Remove paired-plane crosstalk; extraction reads *decrosstalk.h5 when
        // present. Each pair task stages only the motion-correction directories and
        // converter outputs of the two planes its pair file names; both are
        // matched by plane directory name.
        def decrosstalk_inputs = decrosstalk_split_json.out.capsule_results
            .flatten()
            .filter { it.name ==~ /pair.*\.txt/ }
            .combine(motion_correction.out.motion_results_all.flatten().collect().map { [it] })
            .combine(converter.out.converter_results_all.flatten().collect().ifEmpty([]).map { [it] })
            .map { pair_file, motion_dirs, converter_results ->
                def planes = pair_file.readLines()*.trim().findAll { it }.collect { new File(it).name }
                [
                    pair_file,
                    motion_dirs.findAll { it.name in planes },
                    converter_results.findAll { it.parent.name in planes },
                ]
            }
        decrosstalk_roi_images(
            decrosstalk_inputs,
            ophys_mount_jsons.collect(),
            ophys_mount_pophys_directory.collect(),
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

    // Run DF / F. Independent of the classifier.
    if (params.acquisition_data_type == "multiplane"){
        dff(
            extraction.out.capsule_results.flatten(),
            ophys_mount_jsons.collect(),
        )
    } else {
        dff(
            extraction.out.capsule_results.collect(),
            ophys_mount_jsons.collect(),
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
            dff.out.capsule_results.flatten(),
            ophys_mount_jsons.collect()
        )
    } else {
        // Run Oasis Event detection
        oasis_event_detection(
            dff.out.capsule_results.collect(),
            ophys_mount_jsons.collect()
        )
    }

    // Run Ophys NWB Packaging for Multiplane
    //
    // The three per-step channels below glob <plane>/<step>/*, which includes
    // each plane's processing.json / quality_control.json. Collected across
    // planes, those names collide in one path input, and nwb does not read
    // them (it globs for <plane>_*<part>, epoch_locations.json and the sync
    // h5), so they are filtered out.
    //
    // A `path` output whose glob matches several files emits one List per
    // task, and .filter { it.name in ... } on a List always passes, so each
    // channel is flattened before filtering and collected after.
    def metadata_json = ['processing.json', 'quality_control.json']
    // Provenance travels separately from the flat scientific inputs to avoid
    // collisions between identically named per-plane documents.
    def nwb_upstream_processing_json = motion_correction.out.motion_processing_json
        .mix(decrosstalk_processing_json)
        .mix(extraction.out.extraction_processing_json)
        .mix(dff.out.dff_processing_json)
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
        dff.out.dff_results_all.collect(),
        oasis_event_detection.out.events_h5.collect(),
        nwb_upstream_processing_json
    )   

    // Aggregate every step's metadata into the run-level
    // processing.json / quality_control.json.
    //
    // Every step writes bare processing.json / quality_control.json --
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
        .mix(dff.out.dff_processing_json)
        .mix(classifier.out.classifier_processing_json)
        .mix(oasis_event_detection.out.oasis_processing_json)
        .mix(ophys_nwb.out.nwb_processing_json)
        .flatten()

    def all_quality_control_json = converter_qc_json
        .mix(motion_correction.out.motion_qc_json)
        .mix(movie_qc.out.movie_qc_qc_json)
        .mix(decrosstalk_qc_json)
        .mix(extraction.out.extraction_qc_json)
        .mix(dff.out.dff_qc_json)
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


// converter: aind-pophys-converter
process converter {
    tag 'converter'
    def container_name = params.stage_images['CONVERTER']
    container container_name
    publishDir "$RESULTS_PATH", mode: 'copy', saveAs: publishRelativeSkipRunLevel

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

    export CO_CPUS=${task.cpus}
    export CO_MEMORY=${task.memory ? task.memory.toBytes() : ''}

    mkdir -p capsule
    mkdir -p capsule/data
    mkdir -p capsule/results
    mkdir -p capsule/scratch

    ${libraryFunctions}
    install_library "${params.versions['CONVERTER_LIBRARY_REPO']}" "${params.versions['CONVERTER_LIBRARY_COMMIT']}"

    echo "[${task.tag}] running converter..."
    echo "Processing: \$(basename $ophys_mount)"
    cd capsule/code
    echo "converter parameters: --debug ${params.debug} --input_dir ${task_input_dir} --output_dir ${task_output_dir} --temp_dir ${task_temp_dir}"
    run_library aind_pophys_converter.job --debug ${params.debug} --input_dir ${task_input_dir} --output_dir ${task_output_dir} --temp_dir ${task_temp_dir}
    echo "[${task.tag}] completed!"
    ls -a ${task_output_dir}
    """
}

// motion_correction: aind-ophys-motion-correction-library
process motion_correction {
    tag 'motion_correction'
    def container_name = params.stage_images['MOTION_CORRECTION']
    container container_name
    publishDir "$RESULTS_PATH", mode: 'copy', saveAs: publishRelative

    input:
    path ophys_mount, stageAs: 'capsule/data/*'
    path ophys_jsons, stageAs: 'capsule/data/*'
    path pophys_dir, stageAs: 'capsule/data/*'

    path(upstream_processing_json, stageAs: 'capsule/data/processing_??/*')

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

    export CO_CPUS=${task.cpus}
    export CO_MEMORY=${task.memory ? task.memory.toBytes() : ''}
    
    mkdir -p capsule
    mkdir -p capsule/data
    mkdir -p capsule/results
    mkdir -p capsule/scratch

    ${libraryFunctions}
    install_library "${params.versions['MOTION_CORRECTION_LIBRARY_REPO']}" "${params.versions['MOTION_CORRECTION_LIBRARY_COMMIT']}"
    
    echo "[${task.tag}] running motion_correction..."
    cd capsule/code
    echo "motion_correction parameters: --do_registration ${params.do_registration} --data_type ${params.data_type} --batch_size ${params.batch_size} --maxregshift ${params.maxregshift} --maxregshiftNR ${params.maxregshiftNR} --align_by_chan ${params.align_by_chan} --smooth_sigma_time ${params.smooth_sigma_time} --smooth_sigma ${params.smooth_sigma} --nonrigid ${params.nonrigid} --snr_thresh ${params.snr_thresh} --debug ${params.debug}"
    run_library aind_ophys_motion_correction_library.job --input_dir ${task_input_dir} --output_dir ${task_output_dir} --tmp_dir ${task_temp_dir} --do_registration ${params.do_registration} --data_type ${params.data_type} --batch_size ${params.batch_size} --maxregshift ${params.maxregshift} --maxregshiftNR ${params.maxregshiftNR} --align_by_chan ${params.align_by_chan} --smooth_sigma_time ${params.smooth_sigma_time} --smooth_sigma ${params.smooth_sigma} --nonrigid ${params.nonrigid} --snr_thresh ${params.snr_thresh} --debug ${params.debug}
    
    echo "[${task.tag}] completed!"
    """
}

// movie_qc: aind-ophys-movie-qc-library
process movie_qc {
	tag 'movie_qc'
    def container_name = params.stage_images['MOVIE_QC']
    container container_name
    publishDir "$RESULTS_PATH", mode: 'copy', saveAs: publishRelative


	input:
	path motion_results, stageAs: 'capsule/data/*'
    path ophys_jsons, stageAs: 'capsule/data/raw/*'
    path zstacks, stageAs: 'capsule/data/zstacks/*'

	output:
	path 'capsule/results/*'
	path 'capsule/results/*/*/processing.json', emit: 'movie_qc_processing_json', optional: true
	path 'capsule/results/*/*/quality_control.json', emit: 'movie_qc_qc_json', optional: true
	path 'capsule/results/*/*/*.png', emit: 'movie_qc_png'

	script:
	"""
	#!/usr/bin/env bash
	set -e

	export CO_CPUS=${task.cpus}
	export CO_MEMORY=${task.memory ? task.memory.toBytes() : ''}

	mkdir -p capsule
    mkdir -p capsule/data
	mkdir -p capsule/data/raw
    mkdir -p capsule/data/zstacks
	mkdir -p capsule/results
	mkdir -p capsule/scratch

    ${libraryFunctions}
    install_library "${params.versions['MOVIE_QC_LIBRARY_REPO']}" "${params.versions['MOVIE_QC_LIBRARY_COMMIT']}"

    echo "[${task.tag}] running movie_qc..."
    cd capsule/code
    run_library aind_ophys_movie_qc_library.job --input_dir ${task_input_dir} --output_dir ${task_output_dir}

    echo "[${task.tag}] completed!"
    """
}

// decrosstalk_split_json: aind-ophys-decrosstalk-split-session-json-library
process decrosstalk_split_json {
    tag 'decrosstalk_split_json'
    def container_name = params.stage_images['DECROSSTALK_SPLIT']
    container container_name

    publishDir "$RESULTS_PATH", mode: 'copy', saveAs: publishRelative

    input:
    path motion_results, stageAs: 'capsule/data/*'
    path ophys_jsons, stageAs: 'capsule/data/*'

    output:
    path 'capsule/results/*', emit: 'capsule_results'
    
    script:
    """
    #!/usr/bin/env bash
    set -e

    export CO_CPUS=${task.cpus}
    export CO_MEMORY=${task.memory ? task.memory.toBytes() : ''}

    mkdir -p capsule
    mkdir -p capsule/data
    mkdir -p capsule/results
    mkdir -p capsule/scratch

    ${libraryFunctions}
    install_library "${params.versions['DECROSSTALK_SPLIT_LIBRARY_REPO']}" "${params.versions['DECROSSTALK_SPLIT_LIBRARY_COMMIT']}"

    echo "[${task.tag}] running decrosstalk_split..."
    cd capsule/code
    run_library aind_ophys_decrosstalk_split_session_json_library.job --input_dir ${task_input_dir} --output_dir ${task_output_dir}

    echo "[${task.tag}] completed!"
    """
}

// decrosstalk_roi_images: aind-ophys-decrosstalk-roi-images-library
process decrosstalk_roi_images {
    tag 'decrosstalk_roi_images'
    def container_name = params.stage_images['DECROSSTALK_ROI_IMAGES']
    container container_name

    publishDir "$RESULTS_PATH", mode: 'copy', saveAs: publishRelative

    input:
    tuple path(decrosstalk_split, stageAs: 'capsule/data/*'), path(motion_results, stageAs: 'capsule/data/*'), path(converter_files, stageAs: 'capsule/data/*')
    path ophys_jsons, stageAs: 'capsule/data/*'
    path pophys_dir, stageAs: 'capsule/data/*'
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

    export CO_CPUS=${task.cpus}
    export CO_MEMORY=${task.memory ? task.memory.toBytes() : ''}

    mkdir -p capsule
    mkdir -p capsule/data
    mkdir -p capsule/results
    mkdir -p capsule/scratch

    ln -s "/tmp/data/cellpose_models" "capsule/data/cellpose_models"

    ${libraryFunctions}
    install_library "${params.versions['DECROSSTALK_ROI_IMAGES_LIBRARY_REPO']}" "${params.versions['DECROSSTALK_ROI_IMAGES_LIBRARY_COMMIT']}"

    echo "[${task.tag}] running decrosstalk_roi_images..."
    cd capsule/code
    export CELLPOSE_LOCAL_MODELS_PATH="\${CELLPOSE_MODEL_DIR:-../data/cellpose_models}"
    ${decrosstalkPairFunction}
    stage_pair
    run_library aind_ophys_decrosstalk_roi_images_library.job --input_dir ${task_input_dir} --output_dir ${task_output_dir} --tmp_dir ${task_temp_dir} --debug ${params.debug}

    echo "[${task.tag}] completed!"
    """
}


// extraction: aind-ophys-extraction-library
process extraction {
    tag 'extraction'
    def container_name = params.stage_images['EXTRACTION']
    container container_name

    publishDir "$RESULTS_PATH", mode: 'copy', saveAs: publishRelative

    input:
    path extraction_input, stageAs: 'capsule/data/*'
    path ophys_jsons, stageAs: 'capsule/data/*'
    path cellpose_data

    output:
    path 'capsule/results/*', emit: 'capsule_results'
    path 'capsule/results/*/*/processing.json', emit: 'extraction_processing_json', optional: true
    path 'capsule/results/*/*/quality_control.json', emit: 'extraction_qc_json', optional: true
    path 'capsule/results/*/extraction/*', emit: 'extraction_results_all'


    script:
    def suite2p_params_arg = params.containsKey('suite2p_params') && params.suite2p_params ? "--suite2p_params ${shell_quote(params.suite2p_params)}" : ""
    def suite2p_ops_arg = params.containsKey('suite2p_ops') && params.suite2p_ops ? "--suite2p_ops ${shell_quote(params.suite2p_ops)}" : ""
    """
    #!/usr/bin/env bash
    set -e

    export CO_CPUS=${task.cpus}
    export CO_MEMORY=${task.memory ? task.memory.toBytes() : ''}

    mkdir -p capsule
    mkdir -p capsule/data
    mkdir -p capsule/results
    mkdir -p capsule/scratch

    ln -s "/tmp/data/cellpose_models" "capsule/data/cellpose_models"

    ${libraryFunctions}
    install_library "${params.versions['EXTRACTION_LIBRARY_REPO']}" "${params.versions['EXTRACTION_LIBRARY_COMMIT']}"

    echo "[${task.tag}] running extraction..."
    cd capsule/code
    echo "extraction parameters: --diameter ${params.diameter} --cellprob_threshold ${params.cellprob_threshold} --init ${params.init} --functional_chan ${params.functional_chan} --threshold_scaling ${params.threshold_scaling} --max_overlap ${params.max_overlap} --soma_crop ${params.soma_crop} --allow_overlap ${params.allow_overlap}"
    export CELLPOSE_LOCAL_MODELS_PATH="\${CELLPOSE_MODEL_DIR:-../data/cellpose_models}"
    run_library aind_ophys_extraction_library.job --input_dir ${task_input_dir} --output_dir ${task_output_dir} --tmp_dir ${task_temp_dir} --diameter ${params.diameter} --cellprob_threshold ${params.cellprob_threshold} --init ${params.init} --functional_chan ${params.functional_chan} --threshold_scaling ${params.threshold_scaling} --max_overlap ${params.max_overlap} --soma_crop ${params.soma_crop} --allow_overlap ${params.allow_overlap} ${suite2p_params_arg} ${suite2p_ops_arg}

    echo "[${task.tag}] completed!"
    """
}

// dff: aind-ophys-dff-library
process dff {
    tag 'dff'
    def container_name = params.stage_images['DFF']
    container container_name

    publishDir "$RESULTS_PATH", mode: 'copy', saveAs: publishRelative

    input:
    path extraction_results, stageAs: 'capsule/data/*'
    path ophys_mount_json, stageAs: 'capsule/data/*'

    output:
    path 'capsule/results/*', emit: 'capsule_results'
    path 'capsule/results/*/*/processing.json', emit: 'dff_processing_json', optional: true
    path 'capsule/results/*/*/quality_control.json', emit: 'dff_qc_json', optional: true
    path 'capsule/results/*/dff/*.h5', emit: 'dff_results_all'

    script:
    """
    #!/usr/bin/env bash
    set -e

    export CO_CPUS=${task.cpus}
    export CO_MEMORY=${task.memory ? task.memory.toBytes() : ''}

    mkdir -p capsule
    mkdir -p capsule/data
    mkdir -p capsule/results
    mkdir -p capsule/scratch

    ${libraryFunctions}
    install_library "${params.versions['DFF_LIBRARY_REPO']}" "${params.versions['DFF_LIBRARY_COMMIT']}"

    echo "[${task.tag}] running dff..."
    cd capsule/code
    echo "dff parameters: --method ${params.method} --long_window ${params.long_window} --short_window ${params.short_window} --inactive_percentile ${params.inactive_percentile} --noise_method ${params.noise_method} --sigma_anneal_steps ${params.sigma_anneal_steps} --triexp_config_overrides '${params.triexp_config_overrides}'"
    run_library aind_ophys_dff_library.job --input_dir ${task_input_dir} --output_dir ${task_output_dir} --method ${params.method} --long_window ${params.long_window} --short_window ${params.short_window} --inactive_percentile ${params.inactive_percentile} --noise_method ${params.noise_method} --sigma_anneal_steps ${params.sigma_anneal_steps} --triexp_config_overrides '${params.triexp_config_overrides}'

    echo "[${task.tag}] completed!"
    """
}

// oasis_event_detection: aind-ophys-oasis-event-detection-library
process oasis_event_detection {
    tag 'oasis_event_detection'
    def container_name = params.stage_images['OASIS']
    container container_name

    publishDir "$RESULTS_PATH", mode: 'copy', saveAs: publishRelative

    input:
    path dff_results, stageAs: 'capsule/data/*'
    path ophys_jsons, stageAs: 'capsule/data/*'

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

    export CO_CPUS=${task.cpus}
    export CO_MEMORY=${task.memory ? task.memory.toBytes() : ''}

    mkdir -p capsule
    mkdir -p capsule/data
    mkdir -p capsule/results
    mkdir -p capsule/scratch

    ${libraryFunctions}
    install_library "${params.versions['OASIS_LIBRARY_REPO']}" "${params.versions['OASIS_LIBRARY_COMMIT']}"

    echo "[${task.tag}] running oasis..."
    cd capsule/code
    run_library aind_ophys_oasis_event_detection_library.job --input_dir ${task_input_dir} --output_dir ${task_output_dir}

    echo "[${task.tag}] completed!"
    """
}

// classifier: aind-ophys-classifier-library
process classifier {
	tag 'classifier'
    def container_name = params.stage_images['CLASSIFIER']
    container container_name
    cpus 16
    memory '60 GB'
    accelerator 1
    label 'gpu'

	publishDir "$RESULTS_PATH", mode: 'copy', saveAs: publishRelative

	input:
    path ophys_mount_jsons, stageAs: 'capsule/data/*'
    path classifier_data, stageAs: 'capsule/data/*'
    path extraction_results, stageAs: 'capsule/data/*'
	path roinet_data
    
	output:
	path 'capsule/results/*/*/processing.json', emit: 'classifier_processing_json', optional: true
	path 'capsule/results/*/*/quality_control.json', emit: 'classifier_qc_json', optional: true
    path 'capsule/results/*/classification/*classification.h5', emit: 'classifer_h5'
	path 'capsule/results/*/*/*.png', emit: 'classifier_png'
	path 'capsule/results/*'

	script:
	def model_name_arg = params.containsKey('model-name') && params['model-name'] ? "--model_name ${params['model-name']}" : ""
	def soma_classifier_arg = params.containsKey('soma-classifier-path') && params['soma-classifier-path'] ? "--soma_classifier_path ${params['soma-classifier-path']}" : ""
	def dendrite_classifier_arg = params.containsKey('dendrite-classifier-path') && params['dendrite-classifier-path'] ? "--dendrite_classifier_path ${params['dendrite-classifier-path']}" : ""
	"""
	#!/usr/bin/env bash
	set -e

	export CO_CPUS=${task.cpus}
	export CO_MEMORY=${task.memory ? task.memory.toBytes() : ''}

	mkdir -p capsule
	mkdir -p capsule/data
	mkdir -p capsule/results
	mkdir -p capsule/scratch

	ln -s "/tmp/data/2p_roi_classifier" "capsule/data/2p_roi_classifier" # id: 57a10c5f-468f-4bb2-b3c6-7f4a80efa8ae
	ln -s "/tmp/data/roinet" "capsule/data/roinet"

    ${libraryFunctions}
    install_library "${params.versions['CLASSIFIER_LIBRARY_REPO']}" "${params.versions['CLASSIFIER_LIBRARY_COMMIT']}"

	echo "[${task.tag}] running classifier..."
	cd capsule/code
    ${classifierModelFunction}
    stage_roinet
	run_library aind_ophys_classifier_library.job "\${ROINET_ARGS[@]}" --input_dir ${task_input_dir} --output_dir ${task_output_dir} --tmp_dir ${task_temp_dir} ${soma_classifier_arg} ${dendrite_classifier_arg} --border_size ${params['border-size']} ${model_name_arg}

	echo "[${task.tag}] completed!"
	"""
}


// ophys_nwb: aind-ophys-nwb-library
process ophys_nwb {
	tag 'ophys_nwb'
    def container_name = params.stage_images['NWB']
    container container_name

	publishDir "$RESULTS_PATH", mode: 'copy', saveAs: publishRelative

	input:
    path schemas, stageAs: 'capsule/data/schemas/*'
    path ophys_mount_jsons, stageAs: 'capsule/data/raw/*'
    path ophys_sync_file, stageAs: 'capsule/data/raw/behavior/*'
    path ophys_mount_pophys_directory, stageAs: 'capsule/data/raw/*'
    path motion_correction_results, stageAs: 'capsule/data/processed/*'
    path decrosstalk_results, stageAs: 'capsule/data/processed/*'
    path extraction_results, stageAs: 'capsule/data/processed/*'
	path classifer_h5, stageAs: 'capsule/data/processed/*'
	path dff_results, stageAs: 'capsule/data/processed/*'
	path event_detection_results, stageAs: 'capsule/data/processed/*'
    path(upstream_processing_json, stageAs: 'capsule/data/processed/processing_??/*')

	output:
	path 'capsule/results/*'
	path 'capsule/results/*/processing.json', emit: 'nwb_processing_json', optional: true
	path 'capsule/results/*/quality_control.json', emit: 'nwb_qc_json', optional: true

	script:
	"""
	#!/usr/bin/env bash
	set -e

	export CO_CPUS=${task.cpus}
	export CO_MEMORY=${task.memory ? task.memory.toBytes() : ''}
    echo "I AM MAKING AN NWB"
	mkdir -p capsule
	mkdir -p capsule/data
	mkdir -p capsule/results
	mkdir -p capsule/scratch
    mkdir -p capsule/data/schemas
    mkdir -p capsule/data/raw
    mkdir -p capsule/data/raw/behavior
    mkdir -p capsule/data/nwb
    mkdir -p capsule/data/processed

    echo "[${task.tag}] staged \$(find capsule/data/processed -name processing.json | wc -l) upstream processing.json"

    ${libraryFunctions}
    install_library "${params.versions['NWB_LIBRARY_REPO']}" "${params.versions['NWB_LIBRARY_COMMIT']}"

	echo "[${task.tag}] running nwb..."
	cd capsule/code
	ls -R ${task_input_dir}
    for schema in ndx-aibs-behavior-ophys.namespace.yaml ndx-aibs-behavior-ophys.extension.yaml; do
        test -f "../data/schemas/\${schema}" || { echo "missing NWB extension schema: ../data/schemas/\${schema}" >&2; exit 1; }
    done
    run_library aind_ophys_nwb_library.job --input_dir ${task_input_dir} --output_dir ${task_output_dir} --extension_namespace=../data/schemas/ndx-aibs-behavior-ophys.namespace.yaml

	echo "[${task.tag}] completed!"
	"""
}

// pipeline_processing_metadata_aggregator: aind-metadata-manager
process pipeline_processing_metadata_aggregator {
    tag 'pipeline_processing_metadata_aggregator'
    def container_name = params.stage_images['AGGREGATOR']
    container container_name

    // data_description.json name embeds datetime.now() -> must regenerate every run (never cache)
    cache false

    // This task's processing.json / quality_control.json are the run-level
    // documents, and they sit directly under capsule/results/, so the shared
    // saveAs publishes them at the results root -- where they belong.
    publishDir "$RESULTS_PATH", mode: 'copy', saveAs: publishRelative

    input:
    path ophys_mount_jsons, stageAs: 'capsule/data/*'
    path(processing_json, stageAs: 'capsule/data/processing_??/*')
    path(quality_control_json, stageAs: 'capsule/data/quality_control_??/*')

    output:
    path 'capsule/results/*'

    script:
    def processor_arg = params.containsKey('processor_full_name') ? "--processor_full_name ${shell_quote(strip_double_quotes(params.processor_full_name))}" : ''
    def data_summary_arg = params.containsKey('data_summary') && params.data_summary ? "--data_summary ${shell_quote(strip_double_quotes(params.data_summary))}" : ''
    """
    #!/usr/bin/env bash
    set -e

    export CO_CPUS=${task.cpus}
    export CO_MEMORY=${task.memory ? task.memory.toBytes() : ''}

    mkdir -p capsule
    mkdir -p capsule/data
    mkdir -p capsule/results
    mkdir -p capsule/scratch

    echo "[${task.tag}] using task-local staged inputs..."
    echo "[${task.tag}] staged \$(find capsule/data -name processing.json | wc -l) processing.json, \$(find capsule/data -name quality_control.json | wc -l) quality_control.json"

    ${libraryFunctions}
    install_library "${params.versions['AGGREGATOR_LIBRARY_REPO']}" "${params.versions['AGGREGATOR_LIBRARY_COMMIT']}"

    echo "[${task.tag}] running aggregator..."
    cd capsule/code
    run_library aind_metadata_manager.metadata_manager --input_dir ${task_input_dir} --output_dir ${task_output_dir} ${processor_arg} ${params.containsKey('skip_ancillary_files') ? '--skip_ancillary_files ' + params.skip_ancillary_files : ''} ${params.containsKey('modality') ? '--modality ' + params.modality : ''} ${params.containsKey('aggregate_quality_control') ? '--aggregate_quality_control ' + params.aggregate_quality_control : ''} ${data_summary_arg} ${params.containsKey('verbose') ? '--verbose ' + params.verbose : ''} --pipeline_url "\$PIPELINE_URL" --pipeline_version "\$PIPELINE_VERSION"
    echo "[${task.tag}] completed!"
    """
}
