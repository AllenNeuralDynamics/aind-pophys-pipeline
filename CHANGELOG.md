# [4.0.0](https://github.com/AllenNeuralDynamics/aind-pophys-pipeline/compare/v3.0.0...v4.0.0) (2026-11-20)


* feat(pipeline)!: one main.nf for Code Ocean, SLURM and local runs (#68) ([686bd50](https://github.com/AllenNeuralDynamics/aind-pophys-pipeline/commit/686bd50162a49633ea04b3b3712132dd6e046f44)), closes [#68](https://github.com/AllenNeuralDynamics/aind-pophys-pipeline/issues/68)


### BREAKING CHANGES

* the session is passed as --ophys_mount_url and has no default; process_versions_custom.env keys are <STEP>_LIBRARY_REPO and <STEP>_LIBRARY_COMMIT; upgrade_legacy_metadata is no longer a parameter; step capsules are no longer used.



# [3.0.0](https://github.com/AllenNeuralDynamics/aind-pophys-pipeline/compare/v2.1.0...v3.0.0) (2026-11-05)


### Features

* aind-data-schema v2 pophys pipeline ([#62](https://github.com/AllenNeuralDynamics/aind-pophys-pipeline/issues/62)) ([5f17f0b](https://github.com/AllenNeuralDynamics/aind-pophys-pipeline/commit/5f17f0bdd52b495701adcb478bf39dc5540d261d))


### BREAKING CHANGES

* input assets must carry aind-data-schema v2 metadata, and every step writes v2 processing.json and quality_control.json; the QC aggregator step is removed.



# [2.1.0](https://github.com/AllenNeuralDynamics/aind-pophys-pipeline/compare/v2.0.0...v2.1.0) (2026-07-28)


### Features

* v1 qc patch ([#56](https://github.com/AllenNeuralDynamics/aind-pophys-pipeline/issues/56)) ([#57](https://github.com/AllenNeuralDynamics/aind-pophys-pipeline/issues/57)) ([e735c3e](https://github.com/AllenNeuralDynamics/aind-pophys-pipeline/commit/e735c3e14e9f391d513ac0903fd8fbe7d721db2b))



# [2.0.0](https://github.com/AllenNeuralDynamics/aind-pophys-pipeline/compare/v1.0.1...v2.0.0) (2026-07-15)


### Features

* last v1 update ([#54](https://github.com/AllenNeuralDynamics/aind-pophys-pipeline/issues/54)) ([fbc76b2](https://github.com/AllenNeuralDynamics/aind-pophys-pipeline/commit/fbc76b2a7c2cba702dff7359d49e355dcc5675a2))


### BREAKING CHANGES

* extraction init default changed from 'sparsery' to 'mean'



## [1.0.1](https://github.com/AllenNeuralDynamics/aind-pophys-pipeline/compare/v1.0.0...v1.0.1) (2026-03-20)


### Bug Fixes

* **converter-capsule:** bump to COv10, to fix platform.json check now only applies to multiplane sessions. ([6d3f9de](https://github.com/AllenNeuralDynamics/aind-pophys-pipeline/commit/6d3f9de5e858d34cbfdfe9612ea1d603d9433f6a))



