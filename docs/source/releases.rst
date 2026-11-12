.. _releases:

Releases
========

Release notes are generated from Conventional Commit messages each time a release is tagged, and
the release sets ``PIPELINE_VERSION`` in ``pipeline/nextflow.config``. Each step's ``dev`` image,
built from the ``dev`` branch, is then promoted to that version and to ``latest``. The same notes
are kept in ``CHANGELOG.md`` and on the
`GitHub releases page <https://github.com/AllenNeuralDynamics/aind-pophys-pipeline/releases>`_.

.. include:: ../../CHANGELOG.md
   :parser: myst_parser.sphinx_
