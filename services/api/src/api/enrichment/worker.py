"""Enrichment worker — Phase C5 fills it.

Consumes uploaded captures and drives the derived-artifact pipeline:
transcription (transcripts), parsing (parses), and status transitions on the
captures row. Runs out-of-band from request handling; never on the capture
hot path (capture must succeed offline with the worker deleted entirely).
"""
