.. _releases:

Releases
========

Release notes are generated from Conventional Commit messages each time a release is tagged, and
the release sets ``PIPELINE_VERSION`` in ``pipeline/nextflow.config``. Each step's ``dev`` image,
built from the ``dev`` branch, is then promoted to that version and to ``latest``. The same notes
are kept in ``CHANGELOG.md`` and on the
`GitHub releases page <https://github.com/AllenNeuralDynamics/aind-pophys-pipeline/releases>`_.

A release is cut when a pull request from ``dev`` is squash-merged into ``main``. Give the squash
commit a Conventional Commit subject (``fix:`` for a patch release, ``feat:`` for a minor release)
and a short body of its own rather than the default list of ``dev`` commits. That list includes
earlier version-bump commits marked ``[skip ci]``, and the marker anywhere in the message stops
the release from running.

.. include:: ../../CHANGELOG.md
   :parser: myst_parser.sphinx_
