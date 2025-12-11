# CHANGELOG

## [10.0] - 2025-12-11

### Added

* Added new "Coupled FOV" QCEvaluation to properly evaluate crosstalk.
* Dropdown selections for metric failure modes across all "Op. QC" QCEvaluations.

### Changed

* Changed names of QCEvaluations for clarity and brevity
  * Window Health and Brain Clarity -> Window Clarity
  * Merged Raw vs Averaged Depth PNGs -> Field-of-View Matching
  * Motion Correction Summary -> Motion Correction
  * Epilepsy Probability -> Epilepsy
  * Intensity Stability -> Intensity Drift
  * Pixel Value Distribution -> Pixel Saturation
  * Z-Drift Analysis -> Z-Drift
* Added "Op. QC" to the names of QCEvaluations to distinguish evaluations that should be viewed for daily operational QC.
 
### Removed

* Decrosstalk QCEvaluation with episodic snapshot movie of single plane.

### Fixed

* Fixed QC report only displaying one FOV
* Pixel saturation threshold updated to correct value of 18423


## [9.0] - 2025-11-21

### Fixed

* Decrosstalk optimization implemented [#40](https://github.com/AllenNeuralDynamics/aind-ophys-decrosstalk-roi-images/pull/40)

## [8.0] - 2025-11-11

### Fixed

* Increased resources for decrosstalk to 32CPUs and 250GB so two plane acquisitions don't run out of memory 
* changed decrosstalk version which pulls the cytotorch model from local reference [#38](https://github.com/AllenNeuralDynamics/aind-ophys-decrosstalk-roi-images/issues/38)
