# CHANGELOG

## [10.0] - 2026-01-29
### Fixed
* Species field is no longer missing from result NWB files

## [9.0] - 2025-11-21

### Fixed

* Decrosstalk optimization implemented [#40](https://github.com/AllenNeuralDynamics/aind-ophys-decrosstalk-roi-images/pull/40)

## [8.0] - 2025-11-11

### Fixed

* Increased resources for decrosstalk to 32CPUs and 250GB so two plane acquisitions don't run out of memory 
* changed decrosstalk version which pulls the cytotorch model from local reference [#38](https://github.com/AllenNeuralDynamics/aind-ophys-decrosstalk-roi-images/issues/38)
