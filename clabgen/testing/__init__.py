"""Test-only helpers for the CLAB renderer.

Nothing in this package is imported by production renderer code. It exists so
focused renderer tests can build a *released* canonical fixture through
network-realization-model instead of handing the renderer a raw CPM payload
(FS-310-HDS-040-SDS-010-SMS-100 permits a schema-valid canonical fixture, never a
direct-CPM entry).
"""
