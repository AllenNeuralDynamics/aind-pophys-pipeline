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



# [1.0.0](https://github.com/AllenNeuralDynamics/aind-pophys-pipeline/compare/v0.1.0...v1.0.0) (2026-03-19)


### Documentation

* update reference to aind-metadata-manager-capsule ([04e8cf9](https://github.com/AllenNeuralDynamics/aind-pophys-pipeline/commit/04e8cf9ceafac42e2f8174b27de9253109eaa65b))


### BREAKING CHANGES

* Breaking is in reference to the previous commit 8443918. This is required to trigger the versioning workflow for the previous commit due to a bug in the third-party github workflow.



# [0.1.0](https://github.com/AllenNeuralDynamics/aind-pophys-pipeline/compare/8212ffc7e293d484a7a5dfe6a08a49b06b0901f5...v0.1.0) (2026-03-16)


### Bug Fixes

* app panel parameter default ([a040af9](https://github.com/AllenNeuralDynamics/aind-pophys-pipeline/commit/a040af9cd69ad246a2b1c578a4bd33292971ed09))
* bump qc aggregator ([#26](https://github.com/AllenNeuralDynamics/aind-pophys-pipeline/issues/26)) ([95d5704](https://github.com/AllenNeuralDynamics/aind-pophys-pipeline/commit/95d57045daa2a4891ce78a81f3797488273ab708))
* configuration formatting ([fed3327](https://github.com/AllenNeuralDynamics/aind-pophys-pipeline/commit/fed33272c28b8a47be95010fdf1e8d3df9dd186a))
* limit hang time to one day ([#28](https://github.com/AllenNeuralDynamics/aind-pophys-pipeline/issues/28)) ([d85a4d1](https://github.com/AllenNeuralDynamics/aind-pophys-pipeline/commit/d85a4d18dd6c41a3f069d9d1a5eff332be869464))
* mount name ([aba6712](https://github.com/AllenNeuralDynamics/aind-pophys-pipeline/commit/aba67124cc920cd3940c402d775bf413efdb81d4))
* **QC:** corrections and updates to quality control report ([#38](https://github.com/AllenNeuralDynamics/aind-pophys-pipeline/issues/38)) ([3825aed](https://github.com/AllenNeuralDynamics/aind-pophys-pipeline/commit/3825aedfc8c68de1b808b1d1ab5bf5fb4a29fc5a))
* update decrosstalk version to fix decrosstalk optimization issue ([#37](https://github.com/AllenNeuralDynamics/aind-pophys-pipeline/issues/37)) ([2480796](https://github.com/AllenNeuralDynamics/aind-pophys-pipeline/commit/2480796a556d634e56847a392f7af9641f624587))
* update versions for event detection and metadata manager ([#20](https://github.com/AllenNeuralDynamics/aind-pophys-pipeline/issues/20)) ([ae9adb0](https://github.com/AllenNeuralDynamics/aind-pophys-pipeline/commit/ae9adb045d18a445ee31f1463bf6bcbf3bd52f65))


### Features

* 1 add multiplane connections to workflow ([#6](https://github.com/AllenNeuralDynamics/aind-pophys-pipeline/issues/6)) ([8212ffc](https://github.com/AllenNeuralDynamics/aind-pophys-pipeline/commit/8212ffc7e293d484a7a5dfe6a08a49b06b0901f5))
* 2 add aggregators to the pipeline ([#7](https://github.com/AllenNeuralDynamics/aind-pophys-pipeline/issues/7)) ([899335d](https://github.com/AllenNeuralDynamics/aind-pophys-pipeline/commit/899335dc766166d1d51efafaaf309c1a9d55b323))
* 3 add nwb capsule ([#13](https://github.com/AllenNeuralDynamics/aind-pophys-pipeline/issues/13)) ([da70c63](https://github.com/AllenNeuralDynamics/aind-pophys-pipeline/commit/da70c63eef65a8a7d2bb2f2a4781c0ce7a9a7708))
* 4 add single plane logic to the workflow ([#8](https://github.com/AllenNeuralDynamics/aind-pophys-pipeline/issues/8)) ([f0d2966](https://github.com/AllenNeuralDynamics/aind-pophys-pipeline/commit/f0d29663b122613c397d9f39ce668c364d687fbf))
* add release workflow ([#44](https://github.com/AllenNeuralDynamics/aind-pophys-pipeline/issues/44)) ([7a636cb](https://github.com/AllenNeuralDynamics/aind-pophys-pipeline/commit/7a636cba3c5e2a3473273dc3ffc83eec652b0f50))
* fix release yml workflow ([#46](https://github.com/AllenNeuralDynamics/aind-pophys-pipeline/issues/46)) ([784b5de](https://github.com/AllenNeuralDynamics/aind-pophys-pipeline/commit/784b5de6c688b89aac71c9d7732da22364ab5bed))



